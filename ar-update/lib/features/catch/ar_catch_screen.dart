import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/theme/app_colors.dart';
import '../game/game_models.dart';
import '../game/game_providers.dart';

/// AR catch screen: camera preview with creature sprite overlay.
///
/// The sprite is positioned based on device pitch (accelerometer) so it
/// appears to stand on the ground. The capture button is enabled only when:
/// 1. GPS is available (we need lat/lng for the backend).
/// 2. The device is tilted at a "working" angle (camera pointing roughly
///    at ground level, not at the sky).
///
/// After taking a photo, the JPEG is sent to the backend via
/// GameNotifier.submitPhoto() which POSTs to central-api and polls for
/// the vision-service result.
class ArCatchScreen extends ConsumerStatefulWidget {
  const ArCatchScreen({super.key});

  @override
  ConsumerState<ArCatchScreen> createState() => _ArCatchScreenState();
}

class _ArCatchScreenState extends ConsumerState<ArCatchScreen>
    with WidgetsBindingObserver {
  CameraController? _cam;
  bool _initializing = true;
  String? _error;

  // Sensor data
  StreamSubscription? _accelSub;
  double _pitch = 0; // radians; negative = pointing down

  // GPS
  double? _lat;
  double? _lng;

  // UI state
  bool _capturing = false;
  final _random = Random();
  late final String _spriteEmoji;

  // Working pitch range: camera pointing ~20°–70° below horizon.
  // pitch in radians: -1.22 (-70°) to -0.35 (-20°)
  static const _minPitch = -1.22; // -70 degrees
  static const _maxPitch = -0.35; // -20 degrees

  bool get _pitchOk => _pitch >= _minPitch && _pitch <= _maxPitch;
  bool get _canCapture => _pitchOk && _lat != null && !_capturing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _spriteEmoji = _pickRandomEmoji();
    _initCamera();
    _listenSensors();
    _fetchLocation();
  }

  String _pickRandomEmoji() {
    const emojis = ['🐉', '🦉', '🦊', '🐺', '🦎', '🐸', '🦋', '🐾'];
    return emojis[_random.nextInt(emojis.length)];
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _error = 'Nie znaleziono kamery.';
          _initializing = false;
        });
        return;
      }
      // Prefer back camera
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _cam = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _cam!.initialize();
      if (!mounted) return;
      setState(() => _initializing = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Błąd kamery: $e';
        _initializing = false;
      });
    }
  }

  void _listenSensors() {
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 100),
    ).listen((event) {
      if (!mounted) return;
      // pitch = atan2(y, z) — negative when camera points downward
      final pitch = -atan2(event.y, event.z);
      setState(() => _pitch = pitch);
    });
  }

  Future<void> _fetchLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;
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
      // Location not critical — button will stay disabled
    }
  }

  Future<void> _capture() async {
    if (!_canCapture || _cam == null || !_cam!.value.isInitialized) return;
    setState(() => _capturing = true);

    try {
      final file = await _cam!.takePicture();
      final bytes = await file.readAsBytes();

      if (!mounted) return;

      // Show processing indicator
      _showProcessing();

      final response = await ref.read(gameProvider.notifier).submitPhoto(
            jpegBytes: bytes,
            lat: _lat!,
            lng: _lng!,
          );

      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss processing dialog

      if (response == null) {
        _showError('Nie udało się wysłać zdjęcia.');
      } else if (response.isOk) {
        await _showSuccess(response);
      } else if (response.isRejected) {
        _showError(response.reason ?? 'Zdjęcie odrzucone — spróbuj ponownie.');
      } else if (response.isPending) {
        _showError(response.reason ?? 'Analiza trwa. Sprawdź za chwilę.');
      } else {
        _showError(response.reason ?? 'Błąd analizy — spróbuj ponownie.');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss processing
        _showError('Błąd: $e');
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _showProcessing() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Analizuję zdjęcie...\nTo może zająć kilka sekund.',
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _showSuccess(CatchPhotoResponse response) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Złapano! +${response.points ?? 0} pkt'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Text(_spriteEmoji, style: const TextStyle(fontSize: 64)),
            ),
            const SizedBox(height: 12),
            if (response.result != null) ...[
              if (response.result!['steps'] != null)
                Text('Schody: ${response.result!['steps']}'),
              if (response.result!['kerbRange'] != null)
                Text('Krawężnik: ${response.result!['kerbRange']}'),
              if (response.result!['ramp'] == true)
                const Text('Podjazd: tak'),
              const SizedBox(height: 8),
            ],
            const Text(
              'Ocena AI — niezweryfikowane. Trafi na mapę po potwierdzeniu.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Super!'),
          ),
        ],
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.bad),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cam == null || !_cam!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cam!.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accelSub?.cancel();
    _cam?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Kamera')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(_error!, style: const TextStyle(color: AppColors.bad)),
          ),
        ),
      );
    }

    if (_initializing || _cam == null || !_cam!.value.isInitialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Kamera')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Sprite vertical position based on pitch.
    // At -70° (looking straight down) sprite is at center.
    // At -20° (almost horizontal) sprite is near the bottom.
    // Normalized: 0.0 (top) to 1.0 (bottom).
    final pitchNorm = ((_pitch - _minPitch) / (_maxPitch - _minPitch)).clamp(0.0, 1.0);
    final spriteTop = size.height * 0.25 + pitchNorm * (size.height * 0.35);

    // Gentle bob animation on the sprite
    final spriteVisible = _pitchOk;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _cam!.value.previewSize!.height,
                height: _cam!.value.previewSize!.width,
                child: CameraPreview(_cam!),
              ),
            ),
          ),

          // Creature sprite overlay
          if (spriteVisible)
            Positioned(
              top: spriteTop,
              left: 0,
              right: 0,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Shadow
                    Container(
                      width: 60,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    // Sprite
                    Transform.translate(
                      offset: const Offset(0, -10),
                      child: Text(
                        _spriteEmoji,
                        style: const TextStyle(fontSize: 56),
                      ),
                    ),
                  ].reversed.toList(),
                ),
              ),
            ),

          // Guide frame — target area for the barrier
          if (spriteVisible)
            Center(
              child: Container(
                width: size.width * 0.7,
                height: size.height * 0.35,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.5),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Bariera w ramce',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        shadows: [
                          Shadow(blurRadius: 8, color: Colors.black),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Hint when pitch is wrong
          if (!_pitchOk)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.phone_android, size: 40, color: AppColors.warn),
                    SizedBox(height: 8),
                    Text(
                      'Skieruj kamerę w dół\nna barierę lub chodnik',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),

          // Top bar
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
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: 'Wróć',
                    ),
                    const Spacer(),
                    // GPS indicator
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.gps_fixed,
                            size: 14,
                            color: _lat != null ? AppColors.ok : AppColors.warn,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _lat != null ? 'GPS OK' : 'Szukam GPS…',
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom capture button
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_canCapture && !_capturing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          !_pitchOk
                              ? 'Skieruj kamerę na barierę'
                              : 'Czekam na GPS…',
                          style: const TextStyle(
                            color: AppColors.warn,
                            fontSize: 12,
                            shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                          ),
                        ),
                      ),
                    GestureDetector(
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
                                    color: Colors.white,
                                    strokeWidth: 3,
                                  ),
                                )
                              : const Icon(Icons.camera_alt, color: Colors.white, size: 28),
                        ),
                      ),
                    ),
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
