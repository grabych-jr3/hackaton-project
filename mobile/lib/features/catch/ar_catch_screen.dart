import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/catch_repository.dart';
import '../game/game_models.dart';
import 'ar_math.dart';
import 'ar_sensors.dart';
import 'pending_catches.dart';

/// Shown right after the shutter.
const photoSavedMessage =
    'Zdjęcie zapisane — analizujemy w tle. Damy znać, gdy stworek się pojawi.';

/// How the AR camera screen was left (popped as the route result).
enum CatchExit {
  /// Camera/AI unavailable — caller switches to the survey.
  survey,

  /// Creature caught — caller opens the collection.
  collection,
}

/// AR catch screen (ported from Bogdan's AR-update): live camera preview with
/// a creature sprite placed by device pitch, take a picture → `POST /catches`
/// → poll the vision result. Falls back to the survey when the camera, the
/// location or the AI is unavailable — the analysis is never faked.
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

  StreamSubscription<AccelerometerEvent>? _accelSub;
  double _pitch = (_minPitch + _maxPitch) / 2; // radians; negative = down
  bool _hasSensor = false;

  double? _lat;
  double? _lng;
  bool _gpsFailed = false;

  bool _capturing = false;

  // --- geo-anchored mode ---
  final _fusion = HeadingFusion();
  final List<StreamSubscription<dynamic>> _geoSubs = [];
  double? _accuracy;
  double? _distance;
  double? _bearing;
  bool _showDebug = false;
  String? _liveHint;
  DateTime _liveHintAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _liveHintTimer;
  static const _fovDeg = defaultHorizontalFovDeg; // camera plugin exposes no FOV

  late final String _spriteEmoji;
  late final AnimationController _bob;

  // Working pitch range: camera pointing ~20°–70° below the horizon.
  static const _minPitch = -1.22;
  static const _maxPitch = -0.35;

  /// Without an accelerometer (web, desktop) the tilt hint is skipped.
  bool get _pitchOk => !_hasSensor || (_pitch >= _minPitch && _pitch <= _maxPitch);
  bool get _cameraOn => widget.cameraEnabled && ref.read(arCameraEnabledProvider);

  bool get _geoReady =>
      _fusion.heading != null && _distance != null && _bearing != null;
  double? get _rel =>
      _geoReady ? relativeBearing(_bearing!, _fusion.heading!) : null;
  bool get _geoCatchOk =>
      _geoReady && canCatchAt(relDeg: _rel!, distanceM: _distance!);
  bool get _canCapture => (widget.geoMode ? _geoCatchOk : _pitchOk) &&
      _lat != null &&
      !_capturing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    const emojis = ['🐉', '🦉', '🦊', '🐺', '🦎', '🐸', '🦋', '🐾'];
    _spriteEmoji = widget.speciesEmoji ?? emojis[Random().nextInt(emojis.length)];
    _bob = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    if (_cameraOn) {
      _initCamera();
    } else {
      _initializing = false;
    }
    if (widget.geoMode) {
      _listenGeo();
    } else {
      _listenSensors();
      _fetchLocation();
    }
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

  void _listenSensors() {
    try {
      _accelSub = accelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 100),
      ).listen(
        (e) {
          if (!mounted) return;
          setState(() {
            _hasSensor = true;
            _pitch = -atan2(e.y, e.z);
          });
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    } catch (_) {
      // No accelerometer (web/desktop): capture is not gated on tilt.
    }
  }

  void _listenGeo() {
    final sensors = ref.read(arSensorStreamsProvider);
    void sub<T>(Stream<T> s, void Function(T) on) {
      try {
        _geoSubs.add(s.listen((e) {
          if (!mounted) return;
          setState(() => on(e));
          _updateLiveHint();
        }, onError: (Object _) {}, cancelOnError: true));
      } catch (_) {
        // Sensor missing on this platform.
      }
    }

    sub<Vec3>(sensors.accel, (e) {
      _hasSensor = true;
      _fusion.onAccel(e);
    });
    sub<Vec3>(sensors.mag, _fusion.onMag);
    sub<Vec3>(sensors.gyro, _fusion.onGyro);
    try {
      _geoSubs.add(ref.read(arPositionStreamProvider)().listen((pos) {
        if (!mounted) return;
        setState(() {
          _lat = pos.latitude;
          _lng = pos.longitude;
          _accuracy = pos.accuracy;
          _gpsFailed = false;
          _distance = Geolocator.distanceBetween(
              pos.latitude, pos.longitude, widget.spawnLat!, widget.spawnLng!);
          _bearing = wrap360(Geolocator.bearingBetween(
              pos.latitude, pos.longitude, widget.spawnLat!, widget.spawnLng!));
        });
        _updateLiveHint();
      }, onError: (Object _) {
        if (mounted && _lat == null) setState(() => _gpsFailed = true);
      }));
    } catch (_) {
      _gpsFailed = true;
    }
  }

  String? get _geoHint {
    if (!_geoReady) return null;
    return arHint(relDeg: _rel!, distanceM: _distance!, fovDeg: _fovDeg);
  }

  /// Screen-reader live region text, throttled to one change per 2 s.
  void _updateLiveHint() {
    final next = _geoHint;
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

  Future<void> _fetchLocation() async {
    try {
      if (!kIsWeb && !await Geolocator.isLocationServiceEnabled()) {
        throw StateError('off');
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw StateError('denied');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
      });
    } catch (_) {
      if (mounted) setState(() => _gpsFailed = true);
    }
  }

  Future<void> _capture() async {
    final cam = _cam;
    final repo = ref.read(catchRepositoryProvider);
    final shoot = widget.takePictureOverride;
    if (!_canCapture) return;
    if (shoot == null && (cam == null || !cam.value.isInitialized)) return;
    if (repo == null) {
      Navigator.of(context).pop(CatchExit.survey);
      return;
    }
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
            spawnId: widget.spawnId,
          );
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(content: Text(photoSavedMessage)));
      SemanticsService.sendAnnouncement(view, photoSavedMessage, dir);
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
    _accelSub?.cancel();
    for (final s in _geoSubs) {
      s.cancel();
    }
    _liveHintTimer?.cancel();
    _cam?.dispose();
    _bob.dispose();
    super.dispose();
  }

  List<Widget> _geoLayer(Size size, bool reduceMotion) {
    final rel = _rel;
    final out = <Widget>[];
    if (rel != null) {
      if (inFov(rel, fovDeg: _fovDeg)) {
        final px = spriteSizeForDistance(_distance!);
        final x = screenX(rel, size.width, fovDeg: _fovDeg);
        final y = screenY(_fusion.elevation ?? targetElevationDeg, size.width,
            size.height, fovDeg: _fovDeg);
        Widget sprite = Text(_spriteEmoji,
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
          left: x - px / 2,
          top: y - px / 2,
          width: px,
          height: px,
          child: ExcludeSemantics(child: Center(child: sprite)),
        ));
      } else {
        final left = rel < 0;
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
    }
    if (_showDebug) {
      String f(double? v, [int d = 0]) => v == null ? '-' : v.toStringAsFixed(d);
      out.add(Positioned(
        top: 100,
        left: 12,
        child: Container(
          key: const ValueKey('ar-debug'),
          padding: const EdgeInsets.all(8),
          color: Colors.black87,
          child: Text(
            'kurs: ${f(_fusion.heading)}°\n'
            'namiar: ${f(_bearing)}°\n'
            'różnica: ${f(rel)}°\n'
            'nachylenie: ${f(_fusion.elevation)}°\n'
            'dystans: ${f(_distance, 1)} m\n'
            'dokładność GPS: ${f(_accuracy, 1)} m\n'
            'kompas: ${_fusion.magValid ? 'OK' : 'kalibracja'}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
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
    final pitchNorm = ((_pitch - _minPitch) / (_maxPitch - _minPitch)).clamp(0.0, 1.0);
    final spriteTop = size.height * 0.25 + pitchNorm * (size.height * 0.35);
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
          if (widget.geoMode) ..._geoLayer(size, reduceMotion),
          if (!widget.geoMode && _pitchOk)
            Positioned(
              top: spriteTop,
              left: 0,
              right: 0,
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: _bob,
                  builder: (_, child) => Transform.translate(
                    offset: Offset(0, -6 + 12 * _bob.value),
                    child: child,
                  ),
                  child: Center(
                    child: Text(_spriteEmoji, style: const TextStyle(fontSize: 56)),
                  ),
                ),
              ),
            ),
          if (!widget.geoMode && !_pitchOk)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Skieruj kamerę w dół\nna barierę lub chodnik',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),
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
                    if (widget.geoMode)
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
                      const _Hint('Analizuję zdjęcie… To może potrwać do 30 s.')
                    else if (_gpsFailed)
                      const _Hint('Brak lokalizacji — zdjęcie wymaga GPS.')
                    else if (widget.geoMode) ...[
                      if (!_fusion.magValid)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6),
                          child: _Hint('Skalibruj kompas: porusz telefonem ósemką'),
                        ),
                      Semantics(
                        liveRegion: true,
                        label: _liveHint ?? '',
                        excludeSemantics: true,
                        child: _Hint(_geoHint ??
                            (_lat == null ? 'Czekam na GPS…' : 'Czekam na kompas…')),
                      ),
                    ] else if (!_canCapture)
                      _Hint(!_pitchOk ? 'Skieruj kamerę na barierę' : 'Czekam na GPS…'),
                    const SizedBox(height: 8),
                    Semantics(
                      button: true,
                      enabled: _canCapture,
                      label: 'Zrób zdjęcie i złap stworka',
                      hint: widget.geoMode && !_canCapture
                          ? 'Niedostępne: wyceluj w stworka z odległości do 80 m'
                          : null,
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
