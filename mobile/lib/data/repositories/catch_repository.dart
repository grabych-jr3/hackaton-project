import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../features/game/game_models.dart';
import '../api/api_client.dart';

/// One row of `GET /catches?since=` (or a single `GET /catches/{id}`).
class CatchListItem {
  const CatchListItem(this.response, {this.thumbnailUrl, this.createdAt});

  final CatchPhotoResponse response;
  final String? thumbnailUrl;
  final DateTime? createdAt;
}

/// Photo catches (AR camera): `POST /catches` (multipart) then
/// `GET /catches/{id}` until the vision service answers.
///
/// The app uses [upload] + [fetch]/[listSince] for background analysis
/// (see `PendingCatchesNotifier`); [submitPhoto] is the blocking variant.
class CatchRepository {
  CatchRepository(
    this._api, {
    this.pollInterval = const Duration(milliseconds: 1500),
    this.maxWait = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
  })  : _sleep = sleep ?? Future<void>.delayed,
        _clock = clock ?? DateTime.now;

  final ApiClient _api;
  final Duration pollInterval;
  final Duration maxWait;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;

  /// Uploads a photo only (no waiting). Returns the server catch id.
  Future<String> upload({
    required List<int> jpegBytes,
    required double lat,
    required double lng,
    DateTime? takenAt,
    String? spawnId,
    String? placeId,
  }) async {
    final json = await _api.postMultipart(
      '/catches',
      fields: {
        'lat': lat.toString(),
        'lng': lng.toString(),
        'takenAt': (takenAt ?? _clock()).toUtc().toIso8601String(),
        'spawnId': ?spawnId,
        'placeId': ?placeId,
      },
      files: [MultipartPart('photo', jpegBytes, filename: 'catch.jpg')],
    ) as Map<String, dynamic>;
    return json['catchId'].toString();
  }

  /// `GET /catches/{id}`, parsed tolerantly.
  Future<CatchPhotoResponse> fetch(String catchId) async => parseCatchResponse(
      await _api.get('/catches/$catchId', auth: true) as Map<String, dynamic>,
      fallbackId: catchId);

  /// `GET /catches?since=` — throws [ApiException] 404 when the server has no
  /// list endpoint. Accepts a bare list or `{items|catches: [...]}`.
  Future<List<CatchListItem>> listSince(DateTime since) async {
    final q = Uri.encodeQueryComponent(since.toUtc().toIso8601String());
    final json = await _api.get('/catches?since=$q&limit=20', auth: true);
    final raw = json is List
        ? json
        : (json is Map ? (json['items'] ?? json['catches'] ?? const []) : const []);
    return [
      for (final e in raw as List)
        if (e is Map<String, dynamic>)
          CatchListItem(
            parseCatchResponse(e),
            thumbnailUrl: e['thumbnailUrl']?.toString(),
            createdAt: DateTime.tryParse(e['createdAt']?.toString() ?? ''),
          ),
    ];
  }

  /// Thumbnail bytes (authenticated).
  Future<List<int>> thumbnail(String url) => _api.getBytes(url);

  /// Uploads the photo and waits for the result. Never returns PENDING
  /// unless [CatchPhotoResponse.timedOut] is set. Network/API errors
  /// while uploading propagate; poll errors are retried until [maxWait].
  Future<CatchPhotoResponse> submitPhoto({
    required List<int> jpegBytes,
    required double lat,
    required double lng,
    String? spawnId,
    String? placeId,
  }) async {
    final catchId = await upload(
        jpegBytes: jpegBytes, lat: lat, lng: lng, spawnId: spawnId, placeId: placeId);
    final polls = maxWait.inMilliseconds ~/ pollInterval.inMilliseconds;
    for (var i = 0; i < polls; i++) {
      await _sleep(pollInterval);
      try {
        final res = await fetch(catchId);
        if (res.status != CatchStatus.pending) return res;
      } on ApiException catch (e) {
        if (e.status != 404 && e.status < 500) rethrow;
      } catch (e) {
        if (!isNetworkError(e)) rethrow;
      }
    }
    return CatchPhotoResponse(
        catchId: catchId, status: CatchStatus.pending, timedOut: true);
  }
}

/// Tolerant parser: malformed species/state/result never turn an OK into an
/// error — those parts are dropped (the game state is then reloaded).
CatchPhotoResponse parseCatchResponse(Map<String, dynamic> j, {String? fallbackId}) {
  T? safe<T>(T Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }

  final species = j['species'];
  final result = j['result'];
  final state = j['state'];
  final points = j['points'];
  return CatchPhotoResponse(
    catchId: (j['catchId'] ?? j['id'] ?? fallbackId ?? '').toString(),
    status: CatchStatus.fromJson(j['status']?.toString().toUpperCase()),
    reason: j['reason']?.toString(),
    result: result is Map<String, dynamic> ? safe(() => CatchAiResult.fromJson(result)) : null,
    species: species is Map<String, dynamic> ? safe(() => Species.fromJson(species)) : null,
    points: points is num ? points.toInt() : 0,
    state: state is Map<String, dynamic> ? safe(() => GameState.fromJson(state)) : null,
  );
}

/// null in demo mode (no backend → no AI analysis, survey only).
final catchRepositoryProvider = Provider<CatchRepository?>(
    (ref) => useApi ? CatchRepository(ref.watch(apiClientProvider)) : null);
