import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/catch_repository.dart';
import '../game/game_models.dart';
import 'ar_projection.dart';
import 'ar_sensors.dart';
import '../spawns/spawn_providers.dart';
import 'gps_smoother.dart';
import 'pending_catches.dart';

/// Shown right after the shutter.
const photoSavedMessage =
    'Zdjęcie zapisane — analizujemy w tle. Damy znać, gdy stworek się pojawi.';

/// Shown when the photo was taken farther than [arCatchDistanceM] away.
const barrierOnlyMessage =
    'Zdjęcie bariery zapisane — stworek jest za daleko, nie został złapany';

/// Hint in free mode without any spawn nearby.
const noSpawnsHint = 'Brak stworków w pobliżu — postaw stworka na mapie';

/// Creature is caught only within this distance (m).
const arCatchDistanceM = 20.0;

/// Free mode looks for spawns within this radius (m).
const arFreeModeRadiusM = 50.0;

/// shared_preferences key of the tuned horizontal FOV.
const arHFovPrefKey = 'ar_hfov_deg';

/// How the AR camera screen was left (popped as the route result).
enum CatchExit {
  /// Camera/AI unavailable — caller switches to the survey.
  survey,

  /// Creature caught — caller opens the collection.
  collection,
}

/// What the AR sprite is anchored to.
class _ArTarget {
  const _ArTarget(this.id, this.lat, this.lng, this.emoji);
  final String? id;
  final double lat, lng;
  final String? emoji;
}

/// AR catch screen: live camera preview with the creature sprite projected in
/// full 3D through the OS rotation matrix (see ar_projection.dart). Take a
/// picture → background upload via [pendingCatchesProvider] → back to /map.
class ArCatchScreen extends ConsumerStatefulWidget {
  const ArCatchScreen({
    super.key,
    this.placeId,
    this.spawnId,
    this.speciesEmoji,
    this.speciesName,
    this.spawnLat,
    this.spawnLng,
    @visibleForTesting this.cameraEnabled = true,
    @visibleForTesting this.takePictureOverride,
  });

  final String? placeId;

  /// Map spawn being caught (the sprite shows its creature).
  final String? spawnId;
  final String? speciesEmoji;
  final String? speciesName;

  /// Geographic anchor of the creature; both set = geo-anchored AR mode.
  /// Otherwise free mode: the nearest spawn within 50 m is shown.
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
  final _screen = ScreenSmoother();
  List<double>? _m;
  double? _lat, _lng;
  double? _rawAccuracy;
  bool _gpsFailed = false;
  ({double e, double n, double u})? _goodEnu;
  String? _goodEnuFor; // target key the cached ENU belongs to
  ArProjection? _proj;
  ({double x, double y})? _pos;

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

  _ArTarget? get _target {
    if (widget.geoMode) {
      return _ArTarget(
          widget.spawnId, widget.spawnLat!, widget.spawnLng!, widget.speciesEmoji);
    }
    final s = ref.read(nearestSpawnProvider(arFreeModeRadiusM));
    return s == null ? null : _ArTarget(s.id, s.lat, s.lng, s.emoji);
  }

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
        _recompute();
      }, onError: (Object _) {
        if (mounted && _lat == null) setState(() => _gpsFailed = true);
      }));
    } catch (_) {
      _gpsFailed = true;
    }
  }

  /// User→target ENU; when the GPS error exceeds the distance the last good
  /// ENU is kept (the sprite never re-centres on GPS noise).
  ({double e, double n, double u})? _enuFor(_ArTarget t) {
    final lat = _lat, lng = _lng;
    if (lat == null || lng == null) return null;
    final key = '${t.id}|${t.lat}|${t.lng}';
    if (_goodEnuFor != key) {
      _goodEnu = null;
      _goodEnuFor = key;
    }
    final enu = enuOffset(lat, lng, t.lat, t.lng);
    final dist = sqrt(enu.e * enu.e + enu.n * enu.n);
    final err = _gps.position?.errorM ?? 0;
    if (err > dist && _goodEnu != null) return _goodEnu;
    return _goodEnu = enu;
  }

  void _recompute() {
    if (!mounted) return;
    final t = _target;
    final m = _m;
    final enu = t == null ? null : _enuFor(t);
    ArProjection? proj;
    if (m != null && enu != null) {
      final size = MediaQuery.sizeOf(context);
      final fov = croppedFov(
          hFovDeg: _hFov,
          vFovDeg: vFovForHFov(_hFov),
          screenW: size.width,
          screenH: size.height);
      proj = projectTarget(
          m: m,
          enu: enu,
          screenW: size.width,
          screenH: size.height,
          hFovDeg: fov.h,
          vFovDeg: fov.v);
    }
    setState(() {
      _proj = proj;
      _pos = proj == null ? null : _screen.add(proj);
    });
    _updateLiveHint();
  }

  String get _hint {
    if (_lat == null) return 'Czekam na GPS…';
    if (_target == null) return noSpawnsHint;
    final p = _proj;
    if (p == null) return 'Czekam na czujniki orientacji…';
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
    final target = _target;
    final enu = target == null ? null : _enuFor(target);
    final dist = enu == null ? null : sqrt(enu.e * enu.e + enu.n * enu.n);
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
            spawnId: caught ? target.id : null,
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
    _liveHintTimer?.cancel();
    _cam?.dispose();
    _bob.dispose();
    super.dispose();
  }

  List<Widget> _arLayer(Size size, bool reduceMotion) {
    final p = _proj;
    final pos = _pos;
    final out = <Widget>[];
    final t = _target;
    if (p != null && pos != null && p.visible) {
      final px = p.size;
      Widget sprite = Text(t?.emoji ?? _fallbackEmoji,
          key: const ValueKey('ar-sprite'),
          style: TextStyle(fontSize: px * 0.8, height: 1));
      if (!reduceMotion) {
        sprite = AnimatedBuilder(
          animation: _bob,
          builder: (_, child) => Transform.translate(
              offset: Offset(0, -6 + 12 * _bob.value), child: child),
          child: sprite,
        );
      }
      out.add(Positioned(
        left: pos.x - px / 2,
        top: pos.y - px / 2,
        width: px,
        height: px,
        child: ExcludeSemantics(
            child: OverflowBox(
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: Center(child: sprite))),
      ));
    } else if (p != null && !p.visible) {
      final left = p.edge < 0;
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
    }
    if (_showDebug) out.add(_debugPanel());
    return out;
  }

  Widget _debugPanel() {
    String f(double? v, [int d = 0]) =>
        v == null || v.isNaN ? '-' : v.toStringAsFixed(d);
    final m = _m;
    final p = _proj;
    final source = m is ArRotationMatrix
        ? (m.source == ArRotationSource.os ? 'OS rotation vector' : 'kompas + grawitacja')
        : m == null
            ? 'brak'
            : 'zewnętrzne';
    final yaw = m == null ? null : (cameraYawDeg(m) + arDeclinationDeg) % 360;
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
              'yaw (prawdziwa płn.): ${f(yaw)}°\n'
              'dx/dy/dz: ${f(p?.dx, 1)} / ${f(p?.dy, 1)} / ${f(p?.dz, 1)} m\n'
              'głębokość: ${f(p?.depth, 1)} m\n'
              'sx/sy: ${f(_pos?.x ?? p?.sx)} / ${f(_pos?.y ?? p?.sy)} px\n'
              'dystans: ${f(p?.distanceM, 1)} m\n'
              'GPS surowy: ±${f(_rawAccuracy, 1)} m\n'
              'GPS wygładzony: ±${f(_gps.position?.errorM, 1)} m\n'
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
    // Free mode: re-project when the nearest spawn changes.
    if (!widget.geoMode) {
      ref.listen(nearestSpawnProvider(arFreeModeRadiusM), (_, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
      });
    }
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
                child: Text(species.emoji, style: const TextStyle(fontSize: 48)),
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
