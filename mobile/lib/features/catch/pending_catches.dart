import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/api/api_client.dart';
import '../../data/repositories/catch_repository.dart';
import '../game/game_models.dart';
import '../game/game_providers.dart';
import 'ar_catch_screen.dart' show showCatchOutcomeDialog, rejectReasonText;

/// Lifecycle of a photo catch analysed in the background.
enum PendingStatus {
  uploading('Wysyłanie'),
  pending('Analiza…'),
  ok('Złapano'),
  rejected('Odrzucone'),
  failed('Błąd');

  const PendingStatus(this.label);
  final String label;

  bool get done => this == ok || this == rejected || this == failed;
}

class PendingCatch {
  const PendingCatch({
    required this.localId,
    required this.createdAt,
    required this.status,
    this.catchId,
    this.response,
    this.photo,
    this.thumbnailUrl,
  });

  final String localId;
  final String? catchId;
  final DateTime createdAt;
  final PendingStatus status;
  final CatchPhotoResponse? response;

  /// The jpeg, kept in memory until uploaded (and as a local thumbnail).
  final Uint8List? photo;
  final String? thumbnailUrl;

  PendingCatch copyWith({
    String? catchId,
    PendingStatus? status,
    CatchPhotoResponse? response,
    String? thumbnailUrl,
  }) =>
      PendingCatch(
        localId: localId,
        createdAt: createdAt,
        catchId: catchId ?? this.catchId,
        status: status ?? this.status,
        response: response ?? this.response,
        photo: photo,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      );

  Map<String, dynamic> toJson() => {
        'localId': localId,
        'catchId': catchId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'status': status.name,
        'thumbnailUrl': thumbnailUrl,
        if (response?.reason != null) 'reason': response!.reason,
      };

  static PendingCatch? fromJson(Map<String, dynamic> j) {
    final id = j['catchId']?.toString();
    final status = PendingStatus.values.where((s) => s.name == j['status']).firstOrNull;
    if (id == null || status == null || status == PendingStatus.uploading) return null;
    return PendingCatch(
      localId: j['localId']?.toString() ?? id,
      catchId: id,
      createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
      status: status,
      thumbnailUrl: j['thumbnailUrl']?.toString(),
    );
  }
}

/// Timings, overridable in tests.
class PendingCatchesConfig {
  const PendingCatchesConfig({
    this.pollInterval = const Duration(seconds: 4),
    this.retryBase = const Duration(seconds: 2),
    this.maxUploadAttempts = 3,
    this.maxPollAge = const Duration(minutes: 10),
  });

  final Duration pollInterval;
  final Duration retryBase;
  final int maxUploadAttempts;

  /// PENDING older than this is given up (FAILED).
  final Duration maxPollAge;
}

final pendingCatchesConfigProvider =
    Provider<PendingCatchesConfig>((ref) => const PendingCatchesConfig());

/// Global messenger (set on MaterialApp) for non-blocking catch notifications.
final catchMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Called when a catch finishes; default shows a SnackBar + announcement.
final catchFinishedSinkProvider =
    Provider<void Function(PendingCatch)>((ref) => showCatchFinishedSnackBar);

String catchFinishedMessage(PendingCatch c) {
  final r = c.response;
  switch (c.status) {
    case PendingStatus.ok:
      final s = r?.species;
      if (s == null) return 'Analiza zakończona — stworek dodany do Kolekcji';
      return 'Złapano: ${s.name} (${s.rarity.label})! Wartość ${r!.points} pkt — zobacz w Kolekcji';
    case PendingStatus.rejected:
      return 'Zdjęcie odrzucone: ${rejectReasonText(r?.reason)}';
    default:
      return 'Analiza nie powiodła się — spróbuj ponownie lub użyj ankiety';
  }
}

/// Finds a Navigator below the app-level ScaffoldMessenger (for dialogs).
BuildContext? _navigatorContextBelow(BuildContext root) {
  BuildContext? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is StatefulElement && e.state is NavigatorState) {
      found = e;
      return;
    }
    e.visitChildElements(visit);
  }

  root.visitChildElements(visit);
  return found;
}

void showCatchFinishedSnackBar(PendingCatch c) {
  final messenger = catchMessengerKey.currentState;
  if (messenger == null) return;
  final msg = catchFinishedMessage(c);
  messenger.showSnackBar(SnackBar(
    content: Text(msg),
    duration: const Duration(seconds: 6),
    action: SnackBarAction(
      label: 'Pokaż',
      onPressed: () {
        final ctx = catchMessengerKey.currentContext;
        final nav = ctx == null ? null : _navigatorContextBelow(ctx);
        if (nav != null) showPendingCatchOutcome(nav, c);
      },
    ),
  ));
  final ctx = catchMessengerKey.currentContext;
  if (ctx != null) {
    SemanticsService.sendAnnouncement(
        View.of(ctx), msg, Directionality.maybeOf(ctx) ?? TextDirection.ltr);
  }
}

/// Opens the outcome dialog for a finished catch (OK without species → a
/// neutral "analysis finished" response, never "AI niedostępne").
Future<void> showPendingCatchOutcome(BuildContext context, PendingCatch c) async {
  if (!c.status.done) return;
  final r = c.response ??
      CatchPhotoResponse(
        catchId: c.catchId ?? c.localId,
        status: switch (c.status) {
          PendingStatus.ok => CatchStatus.ok,
          PendingStatus.rejected => CatchStatus.rejected,
          _ => CatchStatus.failed,
        },
      );
  await showCatchOutcomeDialog(context, r);
}

/// Tracks photo catches analysed in the background: upload (with retry) →
/// PENDING (polled every few seconds) → OK / REJECTED / FAILED.
class PendingCatchesNotifier extends Notifier<List<PendingCatch>> {
  static const prefsKey = 'pending_catches_v1';
  static const _maxKept = 20;

  Timer? _timer;
  bool _polling = false;
  bool? _listSupported;
  int _seq = 0;

  CatchRepository? get _repo => ref.read(catchRepositoryProvider);
  PendingCatchesConfig get _cfg => ref.read(pendingCatchesConfigProvider);

  /// Completes when persisted catches have been restored.
  late Future<void> loaded;

  @override
  List<PendingCatch> build() {
    ref.onDispose(() => _timer?.cancel());
    loaded = _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null) return;
    try {
      final list = [
        for (final e in jsonDecode(raw) as List)
          if (e is Map<String, dynamic>) PendingCatch.fromJson(e)
      ].whereType<PendingCatch>().toList();
      final known = {for (final c in state) c.localId};
      state = [...state, ...list.where((c) => !known.contains(c.localId))];
      _ensureTimer();
    } catch (_) {}
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey,
        jsonEncode([for (final c in state) if (c.catchId != null) c.toJson()]));
  }

  void _put(PendingCatch c) {
    state = [
      for (final e in state) e.localId == c.localId ? c : e,
    ];
  }

  int get pendingCount => state.where((c) => !c.status.done).length;

  /// Registers the photo and uploads it in the background. Returns at once.
  String submit({
    required Uint8List jpeg,
    required double lat,
    required double lng,
    String? placeId,
    String? spawnId,
  }) {
    final now = DateTime.now();
    final localId = 'local-${now.microsecondsSinceEpoch}-${_seq++}';
    final entry = PendingCatch(
        localId: localId, createdAt: now, status: PendingStatus.uploading, photo: jpeg);
    state = [entry, ...state].take(_maxKept).toList();
    unawaited(_upload(entry, lat, lng, placeId, spawnId));
    return localId;
  }

  Future<void> _upload(PendingCatch entry, double lat, double lng, String? placeId,
      [String? spawnId]) async {
    final repo = _repo;
    if (repo == null) {
      _finish(entry.copyWith(status: PendingStatus.failed));
      return;
    }
    for (var attempt = 1; attempt <= _cfg.maxUploadAttempts; attempt++) {
      try {
        final id = await repo.upload(
            jpegBytes: entry.photo!,
            lat: lat,
            lng: lng,
            takenAt: entry.createdAt,
            spawnId: spawnId,
            placeId: placeId);
        _put(_current(entry).copyWith(catchId: id, status: PendingStatus.pending));
        await _persist();
        _ensureTimer();
        return;
      } catch (e) {
        final retryable = isNetworkError(e) || (e is ApiException && e.status >= 500);
        if (!retryable || attempt == _cfg.maxUploadAttempts) break;
        await Future<void>.delayed(_cfg.retryBase * (1 << (attempt - 1)));
      }
    }
    _finish(_current(entry).copyWith(status: PendingStatus.failed));
  }

  PendingCatch _current(PendingCatch c) =>
      state.firstWhere((e) => e.localId == c.localId, orElse: () => c);

  void _ensureTimer() {
    final needed = state.any((c) => c.status == PendingStatus.pending);
    if (!needed) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(_cfg.pollInterval, (_) => pollOnce());
    }
  }

  /// One polling round over all PENDING catches.
  Future<void> pollOnce() async {
    final repo = _repo;
    if (repo == null || _polling) return;
    final pending = state.where((c) => c.status == PendingStatus.pending).toList();
    if (pending.isEmpty) return _ensureTimer();
    _polling = true;
    try {
      final results = <String, CatchListItem>{};
      if (_listSupported != false) {
        final since = pending
            .map((c) => c.createdAt)
            .reduce((a, b) => a.isBefore(b) ? a : b)
            .subtract(const Duration(minutes: 1));
        try {
          for (final item in await repo.listSince(since)) {
            results[item.response.catchId] = item;
          }
          _listSupported = true;
        } on ApiException catch (e) {
          if (e.status == 404 || e.status == 405) _listSupported = false;
        } catch (_) {}
      }
      for (final c in pending) {
        var item = results[c.catchId];
        if (item == null) {
          try {
            item = CatchListItem(await repo.fetch(c.catchId!));
          } catch (_) {}
        }
        final r = item?.response;
        if (r != null && r.status != CatchStatus.pending) {
          final status = switch (r.status) {
            CatchStatus.ok => PendingStatus.ok,
            CatchStatus.rejected => PendingStatus.rejected,
            _ => PendingStatus.failed,
          };
          _finish(_current(c).copyWith(
              status: status, response: r, thumbnailUrl: item?.thumbnailUrl));
        } else if (DateTime.now().difference(c.createdAt) > _cfg.maxPollAge) {
          _finish(_current(c).copyWith(status: PendingStatus.failed));
        } else if (item?.thumbnailUrl != null) {
          _put(_current(c).copyWith(thumbnailUrl: item!.thumbnailUrl));
        }
      }
    } finally {
      _polling = false;
      _ensureTimer();
    }
  }

  void _finish(PendingCatch c) {
    _put(c);
    unawaited(_persist());
    if (c.status == PendingStatus.ok) {
      // State from the response, otherwise reload from the server.
      try {
        ref.read(gameProvider.notifier).applyCatch(c.response?.state);
      } catch (_) {}
    }
    ref.read(catchFinishedSinkProvider)(c);
    _ensureTimer();
  }
}

final pendingCatchesProvider =
    NotifierProvider<PendingCatchesNotifier, List<PendingCatch>>(PendingCatchesNotifier.new);

/// "Zgłoszenia" — recent photo catches with status chips.
class PendingCatchesSection extends ConsumerWidget {
  const PendingCatchesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(pendingCatchesProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    final pending = items.where((c) => !c.status.done).length;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                pending > 0 ? 'Zgłoszenia ($pending w toku)' : 'Zgłoszenia',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _CatchTile(items[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatchTile extends ConsumerWidget {
  const _CatchTile(this.c);

  final PendingCatch c;

  Color _color(ColorScheme s) => switch (c.status) {
        PendingStatus.ok => Colors.green.shade600,
        PendingStatus.rejected => Colors.orange.shade700,
        PendingStatus.failed => s.error,
        _ => s.primary,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = c.response?.species?.name;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: c.status.done,
      label: 'Zdjęcie: ${c.status.label}${name == null ? '' : ', $name'}',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: c.status.done ? () => showPendingCatchOutcome(context, c) : null,
        child: Container(
          constraints: const BoxConstraints(minWidth: 48),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _color(scheme)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(width: 48, height: 48, child: _Thumb(c)),
              ),
              const SizedBox(width: 6),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.status.label,
                      style: TextStyle(
                          color: _color(scheme), fontWeight: FontWeight.w700, fontSize: 13)),
                  if (name != null) Text(name, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumb extends ConsumerStatefulWidget {
  const _Thumb(this.c);
  final PendingCatch c;

  @override
  ConsumerState<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends ConsumerState<_Thumb> {
  Future<List<int>>? _remote;
  String? _url;

  @override
  Widget build(BuildContext context) {
    final photo = widget.c.photo;
    if (photo != null) return Image.memory(photo, fit: BoxFit.cover, gaplessPlayback: true);
    final url = widget.c.thumbnailUrl;
    final repo = ref.read(catchRepositoryProvider);
    if (url != null && repo != null) {
      if (_url != url) {
        _url = url;
        _remote = repo.thumbnail(url);
      }
      return FutureBuilder<List<int>>(
        future: _remote,
        builder: (context, snap) => snap.hasData
            ? Image.memory(Uint8List.fromList(snap.data!), fit: BoxFit.cover)
            : const _ThumbPlaceholder(),
      );
    }
    return const _ThumbPlaceholder();
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.photo_camera_outlined, size: 20),
      );
}
