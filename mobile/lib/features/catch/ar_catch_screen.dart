import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/catch_repository.dart';
import '../game/creature_image.dart';
import '../game/game_models.dart';
import '../map/place_filters.dart' show formatDistance;
import '../route/route_start.dart';
import '../spawns/spawn.dart';
import '../spawns/spawn_providers.dart';
import 'ar_projection.dart';
import 'ar_sensors.dart';
import 'gps_smoother.dart';
import 'pending_catches.dart';

/// Shown right after the shutter.
const photoSavedMessage =
    'Zdjęcie zapisane — analizujemy w tle. Damy znać, gdy stworek się pojawi.';

/// Shown when the photo was taken farther than [arCatchDistanceM] away.
const barrierOnlyMessage =
    'Zdjęcie bariery zapisane — stworek jest za daleko, nie został złapany';

/// Hint before the camera has its own GPS fix.
const waitingGpsHint = 'Czekam na GPS…';

/// Prefix of the hint shown when no spawn is within [arShowRadiusM].
const noSpawnsHint = 'Brak stworków w promieniu 60 m';

/// Creature is caught only within this distance (m).
const arCatchDistanceM = 20.0;

/// All spawns within this radius (m) are drawn in the camera.
const arShowRadiusM = 60.0;

/// Spawns are refetched this often while the camera is open.
const arSpawnRefreshInterval = Duration(seconds: 30);

/// shared_preferences key of the tuned horizontal FOV.
const arHFovPrefKey = 'ar_hfov_deg';

/// How the AR camera screen was left (popped as the route result).
enum CatchExit {
  /// Camera/AI unavailable — caller switches to the survey.
  survey,

  /// Creature caught — caller opens the collection.
  collection,
}

/// A creature drawn in AR.
class _ArItem {
  const _ArItem(this.id, this.lat, this.lng, this.emoji, this.name,
      {this.caught = false, this.speciesId});
  final String id;
  final double lat, lng;
  final String emoji;
  final String name;
  final bool caught;
  final String? speciesId;
}

/// One projected creature for the current frame.
class _Shown {
  _Shown(this.item, this.proj, this.pos);
  final _ArItem item;
  final ArProjection proj;
  final ({double x, double y})? pos;
}

/// AR catch screen: live camera preview with every creature within
/// [arShowRadiusM] projected in full 3D through the OS rotation matrix (see
/// ar_projection.dart). Spawns are matched against the camera's OWN smoothed
/// GPS fix. Take a picture → background upload via [pendingCatchesProvider]
/// → back to /map.
class ArCatchScreen extends ConsumerStatefulWidget {
  const ArCatchScreen({
    super.key,
    this.placeId,
    this.spawnId,
    this.speciesEmoji,
    this.speciesId,
    this.speciesName,
    this.spawnLat,
    this.spawnLng,
    @visibleForTesting this.cameraEnabled = true,
    @visibleForTesting this.takePictureOverride,
  });

  final String? placeId;

  /// Map spawn being caught (initial target).
  final String? spawnId;
  final String? speciesEmoji;
  final String? speciesId;
  final String? speciesName;

  /// Geographic anchor of the route-param creature; both set = it is always
  /// shown (even if the spawn list does not contain it).
  final double? spawnLat;
  final double? spawnLng;

  /// Tests disable the camera plugin (overlay rendered on black).
  final bool cameraEnabled;

  /// Tests replace the camera shutter.
  final Future<Uint8List> Function()? takePictureOverride;

  bool get geoMode => spawnLat != null && spawnLng != null;

  @override
  ConsumerState<ArCatchScreen> createState() => _ArCatchScreenState();
}

class _ArCatchScreenState extends ConsumerState<ArCatchScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _cam;
  bool _initializing = true;
  String? _error;

  final List<StreamSubscription<dynamic>> _subs = [];
  final _gps = GpsSmoother();
  final Map<String, ScreenSmoother> _smoothers = {};
  final Map<String, ({double e, double n, double u})> _goodEnu = {};
  final Map<String, String> _goodEnuKey = {};
  List<double>? _m;
  double? _lat, _lng;
  double? _rawAccuracy;
  bool _gpsFailed = false;
  List<_Shown> _shown = const [];
  String? _selectedId;
  Timer? _refreshTimer;
  DateTime? _spawnsFetchedAt;
  String? _spawnsError;
  bool _placing = false;

  double _hFov = arDefaultHFovDeg;
  bool _capturing = false;
  bool _showDebug = false;
  String? _liveHint;
  DateTime _liveHintAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _liveHintTimer;

  late final String _fallbackEmoji;
  late final AnimationController _bob;

  bool get _cameraOn => widget.cameraEnabled && ref.read(arCameraEnabledProvider);
  bool get _cameraReady =>
      widget.takePictureOverride != null ||
      !_cameraOn ||
      (_cam?.value.isInitialized ?? false);
  bool get _canCapture => _cameraReady && _lat != null && !_capturing;

  List<Spawn> get _spawns {
    final now = DateTime.now();
    return [
      for (final s in ref.read(spawnsProvider).value ?? const <Spawn>[])
        if (s.expiresAt.isAfter(now)) s,
    ];
  }

  double _distTo(double lat, double lng) {
    final e = enuOffset(_lat!, _lng!, lat, lng);
    return sqrt(e.e * e.e + e.n * e.n);
  }

  /// Every creature within [arShowRadiusM] of the camera's fix (the
  /// route-param creature is always included).
  List<_ArItem> get _items {
    if (_lat == null || _lng == null) return const [];
    final out = <_ArItem>[];
    if (widget.geoMode) {
      out.add(_ArItem(widget.spawnId ?? 'route', widget.spawnLat!,
          widget.spawnLng!, widget.speciesEmoji ?? _fallbackEmoji,
          widget.speciesName ?? 'Stworek',
          speciesId: widget.speciesId));
    }
    for (final s in _spawns) {
      if (out.any((i) => i.id == s.id)) continue;
      if (_distTo(s.lat, s.lng) > arShowRadiusM) continue;
      out.add(_ArItem(s.id, s.lat, s.lng, s.emoji, s.name,
          caught: s.caughtByMe, speciesId: s.speciesId));
    }
    return out;
  }

  /// Target: tapped sprite > route-param spawn > nearest not-caught spawn.
  _Shown? get _target {
    if (_shown.isEmpty) return null;
    for (final id in [_selectedId, if (widget.geoMode) widget.spawnId ?? 'route']) {
      if (id == null) continue;
      for (final s in _shown) {
        if (s.item.id == id) return s;
      }
    }
    final sorted = [..._shown]..sort((a, b) {
        if (a.item.caught != b.item.caught) return a.item.caught ? 1 : -1;
        return a.proj.distanceM.compareTo(b.proj.distanceM);
      });
    return sorted.first;
  }

  /// Nearest spawn beyond the show radius (for the "none nearby" hint).
  ({Spawn spawn, double dist, double bearing})? get _nearestFar {
    if (_lat == null || _lng == null) return null;
    ({Spawn spawn, double dist, double bearing})? best;
    for (final s in _spawns) {
      final e = enuOffset(_lat!, _lng!, s.lat, s.lng);
      final d = sqrt(e.e * e.e + e.n * e.n);
      if (best == null || d < best.dist) {
        best = (spawn: s, dist: d, bearing: (atan2(e.e, e.n) * 180 / pi + 360) % 360);
      }
    }
    return best;
  }

  double? get _yawTrue =>
      _m == null ? null : ((cameraYawDeg(_m!) + arDeclinationDeg) % 360 + 360) % 360;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    const emojis = ['🐉', '🦉', '🦊', '🐺', '🦎', '🐸', '🦋', '🐾'];
    _fallbackEmoji = widget.speciesEmoji ?? emojis[Random().nextInt(emojis.length)];
    _bob = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    if (_cameraOn) {
      _initCamera();
    } else {
      _initializing = false;
    }
    _loadFov();
    _listen();
    // Fresh spawn list on open and every 30 s while the camera is open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshSpawns());
    _refreshTimer = Timer.periodic(arSpawnRefreshInterval, (_) => _refreshSpawns());
  }

  void _refreshSpawns() {
    if (!mounted) return;
    try {
      ref.invalidate(spawnsProvider);
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _bob.stop();
    } else if (!_bob.isAnimating) {
      _bob.repeat(reverse: true);
    }
  }

  Future<void> _loadFov() async {
    try {
      final v = (await SharedPreferences.getInstance()).getDouble(arHFovPrefKey);
      if (v != null && mounted) {
        setState(() => _hFov = v.clamp(30.0, 90.0));
        _recompute();
      }
    } catch (_) {
      // No prefs (tests without mock values): keep the default.
    }
  }

  Future<void> _saveFov(double v) async {
    try {
      await (await SharedPreferences.getInstance()).setDouble(arHFovPrefKey, v);
    } catch (_) {}
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _fail('Nie znaleziono kamery.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final cam = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _cam = cam;
      await cam.initialize();
      if (!mounted) return;
      setState(() => _initializing = false);
    } on CameraException catch (e) {
      _fail(e.code.contains('Denied') || e.code.contains('denied')
          ? 'Brak zgody na użycie kamery.'
          : 'Kamera jest niedostępna.');
    } catch (_) {
      _fail('Kamera jest niedostępna na tym urządzeniu.');
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _error = msg;
      _initializing = false;
    });
  }

  void _listen() {
    try {
      _subs.add(ref.read(arRotationMatrixProvider).listen((m) {
        if (!mounted || m.length != 9) return;
        _m = m;
        _recompute();
      }, onError: (Object _) {}));
    } catch (_) {
      // No orientation sensors on this platform.
    }
    try {
      _subs.add(ref.read(arPositionStreamProvider)().listen((pos) {
        if (!mounted) return;
        _rawAccuracy = pos.accuracy;
        _gpsFailed = false;
        _gps.add(GpsFix(
            lat: pos.latitude,
            lng: pos.longitude,
            accuracyM: pos.accuracy,
            time: pos.timestamp));
        final p = _gps.position!;
        _lat = p.lat;
        _lng = p.lng;
        _shareFix(p.lat, p.lng, pos.accuracy);
        _recompute();
      }, onError: (Object _) {
        if (mounted && _lat == null) setState(() => _gpsFailed = true);
      }));
    } catch (_) {
      _gpsFailed = true;
    }
  }

  /// The rest of the app (map, nearest spawn, route start) benefits from the
  /// camera's fix; the spawn bbox is widened when the fix is outside it.
  void _shareFix(double lat, double lng, double accuracy) {
    try {
      ref
          .read(userLocationProvider.notifier)
          .set(UserLocation(LatLng(lat, lng), accuracyM: accuracy));
      final bbox = ref.read(spawnBboxProvider);
      if (!bbox.contains(lat, lng)) {
        const d = 0.01; // ~1 km
        ref
            .read(spawnBboxProvider.notifier)
            .set(SpawnBbox(lng - d, lat - d, lng + d, lat + d));
      }
    } catch (_) {}
  }

  /// User→item ENU; when the GPS error exceeds the distance the last good
  /// ENU is kept (the sprite never re-centres on GPS noise).
  ({double e, double n, double u}) _enuFor(_ArItem t) {
    final key = '${t.lat}|${t.lng}';
    if (_goodEnuKey[t.id] != key) {
      _goodEnu.remove(t.id);
      _goodEnuKey[t.id] = key;
    }
    final enu = enuOffset(_lat!, _lng!, t.lat, t.lng);
    final dist = sqrt(enu.e * enu.e + enu.n * enu.n);
    final err = _gps.position?.errorM ?? 0;
    final good = _goodEnu[t.id];
    if (err > dist && good != null) return good;
    return _goodEnu[t.id] = enu;
  }

  void _recompute() {
    if (!mounted) return;
    final m = _m;
    final items = _items;
    final shown = <_Shown>[];
    if (m != null) {
      final size = MediaQuery.sizeOf(context);
      final fov = croppedFov(
          hFovDeg: _hFov,
          vFovDeg: vFovForHFov(_hFov),
          screenW: size.width,
          screenH: size.height);
      for (final it in items) {
        final proj = projectTarget(
            m: m,
            enu: _enuFor(it),
            screenW: size.width,
            screenH: size.height,
            hFovDeg: fov.h,
            vFovDeg: fov.v);
        final pos = _smoothers.putIfAbsent(it.id, ScreenSmoother.new).add(proj);
        shown.add(_Shown(it, proj, pos));
      }
    }
    setState(() => _shown = shown);
    _updateLiveHint();
  }

  /// Turn direction towards a true bearing given the camera yaw.
  String _turnTo(double bearing) {
    final yaw = _yawTrue;
    if (yaw == null) return '';
    final delta = ((bearing - yaw + 540) % 360) - 180;
    if (delta.abs() < 20) return ' (przed Tobą)';
    return delta < 0 ? ' (w lewo)' : ' (w prawo)';
  }

  String get _hint {
    if (_lat == null) return waitingGpsHint;
    final t = _target;
    if (t == null) {
      if (_items.isNotEmpty) return 'Czekam na czujniki orientacji…';
      final far = _nearestFar;
      if (far == null) return '$noSpawnsHint — postaw stworka tutaj';
      return '$noSpawnsHint — najbliższy: ${far.spawn.name}, '
          '${formatDistance(far.dist)}${_turnTo(far.bearing)}';
    }
    final p = t.proj;
    final d = p.distanceM.round();
    if (!p.visible) {
      return 'Obróć się w ${p.edge < 0 ? 'lewo' : 'prawo'} — stworek $d m';
    }
    return p.distanceM <= arCatchDistanceM
        ? 'Stworek przed Tobą — zrób zdjęcie'
        : 'Podejdź bliżej — stworek $d m stąd';
  }

  /// Screen-reader live region text, throttled to one change per 2 s.
  void _updateLiveHint() {
    final next = _hint;
    if (next == _liveHint) return;
    final since = DateTime.now().difference(_liveHintAt);
    const gap = Duration(seconds: 2);
    if (since >= gap) {
      _liveHintTimer?.cancel();
      _liveHintTimer = null;
      _liveHintAt = DateTime.now();
      setState(() => _liveHint = next);
    } else {
      _liveHintTimer ??= Timer(gap - since, () {
        _liveHintTimer = null;
        if (mounted) _updateLiveHint();
      });
    }
  }

  Future<void> _spawnHere() async {
    final lat = _lat, lng = _lng;
    if (lat == null || lng == null || _placing) return;
    setState(() => _placing = true);
    try {
      final s = await ref
          .read(spawnsProvider.notifier)
          .spawnHere(LatLng(lat, lng), headingDeg: _yawTrue);
      if (!mounted) return;
      _selectedId = s.id;
      _recompute();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
            content: Text('Nie udało się postawić stworka — spróbuj ponownie.')));
      }
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  Future<void> _capture() async {
    final cam = _cam;
    final repo = ref.read(catchRepositoryProvider);
    final shoot = widget.takePictureOverride;
    if (!_canCapture) return;
    if (shoot == null && _cameraOn && (cam == null || !cam.value.isInitialized)) {
      return;
    }
    if (repo == null) {
      Navigator.of(context).pop(CatchExit.survey);
      return;
    }
    final target = _target?.item;
    final dist = target == null ? null : _distTo(target.lat, target.lng);
    final caught = target != null && dist != null && dist <= arCatchDistanceM;
    final message =
        target != null && !caught ? barrierOnlyMessage : photoSavedMessage;
    setState(() => _capturing = true);
    // Global messenger: the snackbar survives the jump back to the map.
    final messenger = catchMessengerKey.currentState ?? ScaffoldMessenger.of(context);
    final view = View.of(context);
    final dir = Directionality.of(context);
    try {
      final bytes = shoot != null
          ? await shoot()
          : await (await cam!.takePicture()).readAsBytes();
      // Saved instantly; upload + analysis continue in the background.
      ref.read(pendingCatchesProvider.notifier).submit(
            jpeg: bytes,
            lat: _lat!,
            lng: _lng!,
            placeId: widget.placeId,
            spawnId: caught && target.id != 'route' ? target.id : null,
          );
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(message)));
      SemanticsService.sendAnnouncement(view, message, dir);
      // One photo per visit: back to the map (branch state is kept).
      if (mounted) {
        if (GoRouter.maybeOf(context) != null) {
          context.go('/map');
        } else {
          Navigator.of(context).pop();
        }
      }
      return;
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Nie udało się zrobić zdjęcia — spróbuj ponownie.')));
    }
    if (mounted) setState(() => _capturing = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      cam.dispose();
      _cam = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _refreshTimer?.cancel();
    _liveHintTimer?.cancel();
    _cam?.dispose();
    _bob.dispose();
    super.dispose();
  }

  Widget _sprite(_Shown s, bool isTarget, bool reduceMotion) {
    final px = s.proj.size * (isTarget ? 1 : 0.8);
    final pos = s.pos!;
    Widget emoji = CreatureImage(
        key: isTarget ? const ValueKey('ar-sprite') : null,
        speciesId: s.item.speciesId,
        emoji: s.item.emoji,
        size: px * 0.8);
    if (!reduceMotion) {
      emoji = AnimatedBuilder(
        animation: _bob,
        builder: (_, child) => Transform.translate(
            offset: Offset(0, -6 + 12 * _bob.value), child: child),
        child: emoji,
      );
    }
    final label = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isTarget ? AppColors.primary : Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('${s.item.name} · ${s.proj.distanceM.round()} m',
          maxLines: 1,
          style: TextStyle(
              color: isTarget ? const Color(0xFF090D12) : Colors.white,
              fontSize: 11,
              fontWeight: isTarget ? FontWeight.w800 : FontWeight.w500)),
    );
    return Positioned(
      key: ValueKey('ar-item-${s.item.id}'),
      left: pos.x - px / 2,
      top: pos.y - px / 2,
      width: px,
      height: px,
      child: Semantics(
        button: true,
        selected: isTarget,
        label: '${s.item.name}, ${s.proj.distanceM.round()} m',
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _selectedId = s.item.id;
            _recompute();
          },
          child: OverflowBox(
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [emoji, const SizedBox(height: 2), label],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _arLayer(Size size, bool reduceMotion) {
    final out = <Widget>[];
    final t = _target;
    // Target last = drawn on top.
    for (final s in _shown) {
      if (s != t && s.proj.visible && s.pos != null) {
        out.add(_sprite(s, false, reduceMotion));
      }
    }
    if (t != null && t.proj.visible && t.pos != null) {
      out.add(_sprite(t, true, reduceMotion));
    } else if (t != null && !t.proj.visible) {
      final left = t.proj.edge < 0;
      out.add(Positioned(
        left: left ? 8 : null,
        right: left ? null : 8,
        top: size.height / 2 - 28,
        child: ExcludeSemantics(
          child: Icon(left ? Icons.arrow_back_ios_new : Icons.arrow_forward_ios,
              key: ValueKey(left ? 'ar-arrow-left' : 'ar-arrow-right'),
              color: Colors.white,
              size: 56),
        ),
      ));
    } else if (t == null && _lat != null && _items.isEmpty) {
      final far = _nearestFar;
      final yaw = _yawTrue;
      if (far != null && yaw != null) {
        out.add(Positioned(
          left: size.width / 2 - 28,
          top: size.height / 2 - 28,
          child: ExcludeSemantics(
            child: Transform.rotate(
              angle: (far.bearing - yaw) * pi / 180,
              child: const Icon(Icons.navigation,
                  key: ValueKey('ar-far-arrow'), color: Colors.white, size: 56),
            ),
          ),
        ));
      }
    }
    if (_showDebug) out.add(_debugPanel());
    return out;
  }

  Widget _debugPanel() {
    String f(double? v, [int d = 0]) =>
        v == null || v.isNaN ? '-' : v.toStringAsFixed(d);
    final m = _m;
    final t = _target;
    final p = t?.proj;
    final source = m is ArRotationMatrix
        ? (m.source == ArRotationSource.os ? 'OS rotation vector' : 'kompas + grawitacja')
        : m == null
            ? 'brak'
            : 'zewnętrzne';
    final at = _spawnsFetchedAt;
    final fetched = at == null
        ? '-'
        : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:'
            '${at.second.toString().padLeft(2, '0')}';
    return Positioned(
      top: 100,
      left: 12,
      right: 12,
      child: Container(
        key: const ValueKey('ar-debug'),
        padding: const EdgeInsets.all(8),
        color: Colors.black87,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'źródło obrotu: $source\n'
              'yaw (prawdziwa płn.): ${f(_yawTrue)}°\n'
              'dx/dy/dz: ${f(p?.dx, 1)} / ${f(p?.dy, 1)} / ${f(p?.dz, 1)} m\n'
              'głębokość: ${f(p?.depth, 1)} m\n'
              'sx/sy: ${f(t?.pos?.x ?? p?.sx)} / ${f(t?.pos?.y ?? p?.sy)} px\n'
              'dystans: ${f(p?.distanceM, 1)} m\n'
              'GPS surowy: ±${f(_rawAccuracy, 1)} m\n'
              'GPS wygładzony: ±${f(_gps.position?.errorM, 1)} m\n'
              'stworki wczytane: ${_spawns.length}, w 60 m: ${_items.length}\n'
              'cel: ${t?.item.id ?? '-'}\n'
              'pobrano: $fetched${_spawnsError == null ? '' : ' · błąd: $_spawnsError'}\n'
              'hFov: ${f(_hFov)}°',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            Slider(
              key: const ValueKey('ar-fov-slider'),
              value: _hFov,
              min: 30,
              max: 90,
              divisions: 60,
              label: '${_hFov.round()}°',
              onChanged: (v) {
                setState(() => _hFov = v);
                _recompute();
              },
              onChangeEnd: _saveFov,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Re-project when the spawn list changes; remember fetch time/error.
    ref.listen<AsyncValue<List<Spawn>>>(spawnsProvider, (_, next) {
      if (next.hasError) {
        _spawnsError = '${next.error}';
      } else if (next.hasValue && !next.isLoading) {
        _spawnsFetchedAt = DateTime.now();
        _spawnsError = null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
    });
    final cam = _cam;
    if (_error != null) {
      return _Unavailable(message: _error!);
    }
    if (_cameraOn &&
        (_initializing || cam == null || !cam.value.isInitialized)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Kamera AR')),
        body: const Center(
          child: CircularProgressIndicator(semanticsLabel: 'Uruchamianie kamery'),
        ),
      );
    }

    final size = MediaQuery.sizeOf(context);
    final preview = cam?.value.previewSize;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final noneNearby = _lat != null && _items.isEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (cam != null)
            ExcludeSemantics(
              child: ClipRect(
                child: preview == null
                    ? CameraPreview(cam)
                    : FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: preview.height,
                          height: preview.width,
                          child: CameraPreview(cam),
                        ),
                      ),
              ),
            ),
          ..._arLayer(size, reduceMotion),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: 'Zamknij aparat',
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => setState(() => _showDebug = !_showDebug),
                      icon: const Icon(Icons.info_outline, color: Colors.white),
                      tooltip: 'Dane diagnostyczne',
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _lat != null
                            ? 'GPS OK'
                            : _gpsFailed
                                ? 'Brak GPS'
                                : 'Szukam GPS…',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_capturing)
                      const _Hint('Zapisuję zdjęcie…')
                    else if (_gpsFailed)
                      const _Hint('Brak lokalizacji — zdjęcie wymaga GPS.')
                    else
                      Semantics(
                        liveRegion: true,
                        label: _liveHint ?? '',
                        excludeSemantics: true,
                        child: _Hint(_hint),
                      ),
                    if (noneNearby && !_capturing) ...[
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        key: const ValueKey('ar-spawn-here'),
                        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _placing ? null : _spawnHere,
                        icon: const Icon(Icons.add_location_alt),
                        label: const Text('Postaw stworka tutaj'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Semantics(
                      button: true,
                      enabled: _canCapture,
                      label: 'Zrób zdjęcie i złap stworka',
                      excludeSemantics: true,
                      onTap: _canCapture ? _capture : null,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _canCapture ? _capture : null,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _canCapture ? Colors.white : Colors.white38,
                              width: 4,
                            ),
                          ),
                          child: Container(
                            margin: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _canCapture
                                  ? AppColors.primary
                                  : AppColors.primary.withValues(alpha: 0.3),
                            ),
                            child: _capturing
                                ? const Padding(
                                    padding: EdgeInsets.all(18),
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 3),
                                  )
                                : const Icon(Icons.camera_alt,
                                    color: Color(0xFF090D12), size: 28),
                          ),
                        ),
                      ),
                    ),
                    if (_gpsFailed) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => Navigator.of(context).pop(CatchExit.survey),
                        child: const Text('Użyj ankiety'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.warn, fontSize: 13)),
      );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Kamera AR')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.no_photography_outlined, size: 48, color: AppColors.warn),
                const SizedBox(height: 12),
                Text('$message Zgłoś barierę w ankiecie.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.text)),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
                  onPressed: () => Navigator.of(context).pop(CatchExit.survey),
                  child: const Text('Przejdź do ankiety'),
                ),
              ],
            ),
          ),
        ),
      );
}

/// Polish text for a REJECTED reason code (or the server's own text).
String rejectReasonText(String? reason) {
  const known = {
    'NO_BARRIER': 'Na zdjęciu nie widać bariery ani przejścia.',
    'NOT_RELEVANT': 'Na zdjęciu nie widać bariery ani przejścia.',
    'BLURRY': 'Zdjęcie jest nieostre.',
    'TOO_DARK': 'Zdjęcie jest za ciemne.',
    'LOW_QUALITY': 'Zdjęcie ma za niską jakość.',
    'DUPLICATE': 'To miejsce zostało już niedawno sfotografowane.',
    'TOO_FAR': 'Jesteś za daleko od wskazanego miejsca.',
    'FACES': 'Na zdjęciu są rozpoznawalne osoby.',
    'LOW_CONFIDENCE': 'AI nie jest pewne, co jest na zdjęciu.',
  };
  if (reason == null || reason.isEmpty) return 'Zdjęcie zostało odrzucone.';
  final mapped = known[reason.toUpperCase()];
  if (mapped != null) return mapped;
  // Unknown machine code → generic text; free text from the server is shown.
  return RegExp(r'^[A-Z0-9_]+$').hasMatch(reason) ? 'Zdjęcie zostało odrzucone.' : reason;
}

/// Shows the result of a photo catch. [response] null = upload failed.
/// Returns how to leave the camera (null = stay and retake).
Future<CatchExit?> showCatchOutcomeDialog(
    BuildContext context, CatchPhotoResponse? response) {
  final status = response?.status;
  final ok = status == CatchStatus.ok && response!.species != null;
  final rejected = status == CatchStatus.rejected;

  Widget action(String label, CatchExit? exit, BuildContext ctx) => FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size(160, 48),
          backgroundColor: AppColors.primary,
          foregroundColor: const Color(0xFF090D12),
        ),
        onPressed: () => Navigator.of(ctx).pop(exit),
        child: Text(label),
      );

  return showDialog<CatchExit>(
    context: context,
    builder: (ctx) {
      if (ok) {
        final species = response.species!;
        final lines = response.result?.lines ?? const <String>[];
        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: Column(
            children: [
              ExcludeSemantics(
                child: CreatureImage(speciesId: species.id, emoji: species.emoji, size: 96),
              ),
              const SizedBox(height: 8),
              Text(
                'Złapano: ${species.name} (${species.rarity.label})',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Wartość: ${response.points} pkt — sprzedaj w Kolekcji',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.primary, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.warn),
                  ),
                  child: const Text('AI · niezweryfikowane',
                      style: TextStyle(
                          color: AppColors.warn,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 8),
                if (lines.isEmpty)
                  const Text('AI nie wykryło barier.',
                      style: TextStyle(color: AppColors.textMuted))
                else
                  for (final l in lines)
                    Text('• $l', style: const TextStyle(color: AppColors.text)),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [action('Do kolekcji', CatchExit.collection, ctx)],
        );
      }
      if (status == CatchStatus.ok) {
        // OK without species details: the creature is already in the collection.
        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: const Text('Analiza zakończona'),
          content: const Text('Stworek trafił do Twojej Kolekcji.',
              style: TextStyle(color: AppColors.text)),
          actionsAlignment: MainAxisAlignment.center,
          actions: [action('Do kolekcji', CatchExit.collection, ctx)],
        );
      }
      if (rejected) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: const Text('Zdjęcie odrzucone'),
          content: Text(rejectReasonText(response!.reason),
              style: const TextStyle(color: AppColors.text)),
          actionsAlignment: MainAxisAlignment.center,
          actions: [action('Zrób zdjęcie ponownie', null, ctx)],
        );
      }
      // FAILED, timeout, OK without species, or upload error.
      return AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('AI niedostępne, użyj ankiety'),
        content: const Text(
          'Nie udało się przeanalizować zdjęcia. Zgłoś barierę w ankiecie — też złapiesz stworka.',
          style: TextStyle(color: AppColors.text),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [action('Przejdź do ankiety', CatchExit.survey, ctx)],
      );
    },
  );
}
