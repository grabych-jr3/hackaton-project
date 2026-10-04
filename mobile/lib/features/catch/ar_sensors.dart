import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart' hide SensorInterval;

import 'ar_math.dart';
import 'ar_projection.dart';

/// Raw accelerometer stream (injectable for tests). Used only for camera
/// tilt; heading comes from the OS fused compass ([arCompassSourceProvider]).
class ArSensorStreams {
  const ArSensorStreams({required this.accel});

  final Stream<Vec3> accel;

  /// Real device accelerometer (sensors_plus), ~50 Hz.
  factory ArSensorStreams.device() => ArSensorStreams(
        accel: accelerometerEventStream(
                samplingPeriod: const Duration(milliseconds: 20))
            .map((e) => Vec3(e.x, e.y, e.z)),
      );
}

final arSensorStreamsProvider =
    Provider<ArSensorStreams>((_) => ArSensorStreams.device());

/// One raw reading from the OS compass.
class CompassReading {
  const CompassReading({required this.heading, this.accuracyDeg});

  /// Degrees clockwise from north, or null when the OS has no fix.
  final double? heading;

  /// Estimated error in degrees (null = unknown).
  final double? accuracyDeg;
}

/// Raw OS compass: Android TYPE_ROTATION_VECTOR / iOS CLHeading via
/// `flutter_compass`. Override in tests with a fake stream.
final arCompassSourceProvider = Provider<Stream<CompassReading>>((_) {
  if (kIsWeb) return const Stream.empty();
  final events = FlutterCompass.events;
  if (events == null) return const Stream.empty();
  return events
      .map((e) => CompassReading(heading: e.heading, accuracyDeg: e.accuracy));
});

/// Whether the compass source reports magnetic north (needs declination).
/// flutter_compass on Android returns a magnetic heading; on iOS it returns
/// CLHeading.trueHeading (already true north).
final arCompassIsMagneticProvider =
    Provider<bool>((_) => defaultTargetPlatform != TargetPlatform.iOS);

/// Magnetic declination for Kraków: about +6.0° (east), NOAA WMM 2025.
/// Added to a magnetic heading to get true north. It's a constant because
/// the app runs in one city. Changes ~0.1°/year.
const krakowDeclinationDeg = 6.0;

/// Accuracy worse than this (degrees) means the heading is unreliable and
/// the compass needs a figure-eight calibration.
const compassAccuracyLimitDeg = 30.0;

/// No compass event for this long marks the heading unreliable.
const compassStaleAfter = Duration(seconds: 2);

/// Smoothed camera heading.
class ArHeading {
  const ArHeading({
    required this.degrees,
    required this.accuracyDeg,
    required this.reliable,
  });

  /// 0..360, true north (declination applied when the source is magnetic).
  final double degrees;
  final double? accuracyDeg;
  final bool reliable;

  /// Low accuracy (Android): screen shows
  /// "Skalibruj kompas: porusz telefonem ósemką".
  bool get needsCalibration =>
      accuracyDeg != null && accuracyDeg! > compassAccuracyLimitDeg;

  @override
  String toString() =>
      'ArHeading($degrees, acc: $accuracyDeg, reliable: $reliable)';
}

/// Circular exponential moving average (wrap-safe): moves [prev] towards
/// [next] by [alpha] along the shortest arc. Result in 0..360.
double circularEma(double? prev, double next, double alpha) {
  if (prev == null) return wrap360(next);
  return wrap360(prev + alpha * wrap180(next - prev));
}

/// Pure heading filter: declination + circular EMA + ±[deadBandDeg]
/// dead-band on the output.
class HeadingSmoother {
  HeadingSmoother({
    this.alpha = 0.15,
    this.deadBandDeg = 1.0,
    this.declinationDeg = 0,
  });

  final double alpha;
  final double deadBandDeg;
  final double declinationDeg;
  double? _ema;
  double? _out;

  /// Feeds a raw heading; returns the smoothed (dead-banded) output.
  double add(double raw) {
    final ema = _ema = circularEma(_ema, wrap360(raw + declinationDeg), alpha);
    final out = _out;
    if (out == null || wrap180(ema - out).abs() > deadBandDeg) _out = ema;
    return _out!;
  }
}

bool _accuracyOk(double? acc) =>
    acc != null && acc >= 0 && acc <= compassAccuracyLimitDeg;

/// Turns raw compass readings into smoothed [ArHeading]s. Re-emits the last
/// heading as unreliable when the source is silent for [staleAfter].
Stream<ArHeading> smoothHeadings(
  Stream<CompassReading> source, {
  required bool magnetic,
  Duration staleAfter = compassStaleAfter,
}) {
  final smoother =
      HeadingSmoother(declinationDeg: magnetic ? krakowDeclinationDeg : 0);
  late final StreamController<ArHeading> ctrl;
  StreamSubscription<CompassReading>? sub;
  Timer? stale;
  ArHeading? last;

  void armStale() {
    stale?.cancel();
    stale = Timer(staleAfter, () {
      final l = last;
      if (l != null && l.reliable) {
        last = ArHeading(
            degrees: l.degrees, accuracyDeg: l.accuracyDeg, reliable: false);
        ctrl.add(last!);
      }
    });
  }

  ctrl = StreamController<ArHeading>(
    onListen: () {
      sub = source.listen((r) {
        final h = r.heading;
        if (h == null || h.isNaN) return;
        final next = ArHeading(
          degrees: smoother.add(h),
          accuracyDeg: r.accuracyDeg,
          reliable: _accuracyOk(r.accuracyDeg),
        );
        last = next;
        ctrl.add(next);
        armStale();
      }, onError: ctrl.addError, onDone: () {
        stale?.cancel();
        ctrl.close();
      });
    },
    onCancel: () async {
      stale?.cancel();
      await sub?.cancel();
    },
  );
  return ctrl.stream;
}

/// Smoothed camera heading from the OS compass (one subscription per screen).
final arHeadingProvider = Provider<Stream<ArHeading>>((ref) => smoothHeadings(
      ref.watch(arCompassSourceProvider),
      magnetic: ref.watch(arCompassIsMagneticProvider),
    ));

/// Camera elevation above the horizon in radians (negative = pointing down)
/// from a low-passed accelerometer. No gyroscope.
Stream<double> pitchFromAccel(Stream<Vec3> accel, {double alpha = 0.2}) {
  Vec3? g;
  return accel.map((a) {
    final p = g;
    final n = g = p == null
        ? a
        : Vec3(p.x + alpha * (a.x - p.x), p.y + alpha * (a.y - p.y),
            p.z + alpha * (a.z - p.z));
    return cameraElevationDeg(n) * math.pi / 180;
  });
}

final arPitchProvider = Provider<Stream<double>>(
    (ref) => pitchFromAccel(ref.watch(arSensorStreamsProvider).accel));

/// Live GPS position stream (high accuracy, 2 m filter) after permission.
Stream<Position> devicePositionStream() async* {
  if (!kIsWeb && !await Geolocator.isLocationServiceEnabled()) {
    throw StateError('off');
  }
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) {
    perm = await Geolocator.requestPermission();
  }
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
    throw StateError('denied');
  }
  // A cold high-accuracy GPS fix can take 10–60 s. Start immediately with the
  // last known position (if recent) and a quick coarse fix (network/Wi-Fi);
  // the high-accuracy stream below then refines it.
  if (!kIsWeb) {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null &&
          DateTime.now().difference(last.timestamp) < const Duration(minutes: 5)) {
        yield last;
      }
    } catch (_) {}
  }
  try {
    yield await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 4),
      ),
    );
  } catch (_) {}
  yield* Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 2,
    ),
  );
}

final arPositionStreamProvider =
    Provider<Stream<Position> Function()>((_) => devicePositionStream);

/// Live AR state consumed by the screen.
class ArLiveState {
  double? heading; // degrees, true north
  double? elevation; // degrees above horizon
  bool magValid = true; // false → calibration hint
}

/// Tests turn the camera plugin off (overlay renders on black).
final arCameraEnabledProvider = Provider<bool>((_) => true);

/// Where the AR rotation matrix comes from (debug overlay).
enum ArRotationSource {
  /// OS fused rotation vector (Android TYPE_ROTATION_VECTOR / iOS CoreMotion).
  os,

  /// Fallback: compass yaw + accelerometer gravity.
  fallback,
}

/// A 3×3 rotation matrix (9 values, row-major, world = M·device; world X=East,
/// Y=magnetic North, Z=Up) tagged with its [source].
class ArRotationMatrix extends ListBase<double> {
  ArRotationMatrix(List<double> values, this.source)
      : assert(values.length == 9),
        _m = List.unmodifiable(values);

  final List<double> _m;
  final ArRotationSource source;

  @override
  int get length => 9;
  @override
  set length(int _) => throw UnsupportedError('fixed');
  @override
  double operator [](int i) => _m[i];
  @override
  void operator []=(int i, double v) => throw UnsupportedError('read-only');
}

/// Raw OS rotation matrices from `flutter_rotation_sensor` (device frame).
///
/// Layout verified in the 0.2.0 source: the Android plugin forwards the
/// TYPE_ROTATION_VECTOR quaternion; `Quaternion.toRotationMatrix()` is the
/// standard row-major device→world matrix (same as
/// `SensorManager.getRotationMatrixFromVector`), `Matrix3[i]` row-major.
final arOsRotationProvider = Provider<Stream<List<double>>>((_) {
  if (!RotationSensor.isPlatformSupported) return const Stream.empty();
  // App is locked to portrait → device frame == display frame.
  RotationSensor.coordinateSystem = CoordinateSystem.device();
  RotationSensor.samplingPeriod = SensorInterval.gameInterval;
  var boosted = false;
  return RotationSensor.orientationStream.map((e) {
    if (!boosted) {
      // 0.2.0 Android ignores the period until a listener exists
      // (FlutterRotationSensorPlugin.onMethodCall): re-apply it once.
      boosted = true;
      RotationSensor.samplingPeriod = SensorInterval.gameInterval;
    }
    final m = e.rotationMatrix;
    return [for (var i = 0; i < 9; i++) m[i]];
  });
});

/// No OS rotation event for this long → compass+gravity fallback.
const arRotationFallbackAfter = Duration(milliseconds: 1500);

/// OS rotation matrices, falling back to compass yaw + gravity when the OS
/// stream is silent for [timeout] (or errors). Switches back to the OS source
/// as soon as it produces events again.
Stream<ArRotationMatrix> rotationWithFallback({
  required Stream<List<double>> os,
  required Stream<Vec3> accel,
  required Stream<CompassReading> compass,
  required bool compassMagnetic,
  Duration timeout = arRotationFallbackAfter,
}) {
  late final StreamController<ArRotationMatrix> ctrl;
  StreamSubscription<List<double>>? osSub;
  final fbSubs = <StreamSubscription<dynamic>>[];
  Timer? timer;
  Vec3? g;
  double? heading;

  void stopFallback() {
    for (final s in fbSubs) {
      s.cancel();
    }
    fbSubs.clear();
  }

  void emitFallback() {
    final gg = g, h = heading;
    if (gg == null || h == null) return;
    // Matrix north must be magnetic, like the rotation vector.
    final magH = compassMagnetic ? h : h - krakowDeclinationDeg;
    final m = matrixFromGravityHeading(gg.x, gg.y, gg.z, magH);
    if (m != null) ctrl.add(ArRotationMatrix(m, ArRotationSource.fallback));
  }

  void startFallback() {
    if (fbSubs.isNotEmpty || ctrl.isClosed) return;
    try {
      fbSubs.add(accel.listen((a) {
        final p = g;
        const k = 0.2;
        g = p == null
            ? a
            : Vec3(p.x + k * (a.x - p.x), p.y + k * (a.y - p.y),
                p.z + k * (a.z - p.z));
        emitFallback();
      }, onError: (Object _) {}));
      fbSubs.add(compass.listen((c) {
        final h = c.heading;
        if (h == null || h.isNaN) return;
        heading = h;
        emitFallback();
      }, onError: (Object _) {}));
    } catch (_) {
      // No sensors at all (web/desktop).
    }
  }

  void arm() {
    timer?.cancel();
    timer = Timer(timeout, startFallback);
  }

  ctrl = StreamController<ArRotationMatrix>(
    onListen: () {
      // Compass+gravity from the very first frame: sprites never wait for
      // the OS rotation vector (dropped as soon as it produces events).
      arm();
      startFallback();
      try {
        osSub = os.listen((m) {
          if (m.length != 9) return;
          stopFallback();
          arm();
          ctrl.add(m is ArRotationMatrix
              ? m
              : ArRotationMatrix(m, ArRotationSource.os));
        }, onError: (Object _) {
          timer?.cancel();
          startFallback();
        });
      } catch (_) {
        startFallback();
      }
    },
    onCancel: () async {
      timer?.cancel();
      stopFallback();
      await osSub?.cancel();
    },
  );
  return ctrl.stream;
}

/// Device rotation matrix for the AR projection (9 values; tagged
/// [ArRotationMatrix] in production). Override in tests with a fake stream.
final arRotationMatrixProvider = Provider<Stream<List<double>>>((ref) =>
    rotationWithFallback(
      os: ref.watch(arOsRotationProvider),
      accel: ref.watch(arSensorStreamsProvider).accel,
      compass: ref.watch(arCompassSourceProvider),
      compassMagnetic: ref.watch(arCompassIsMagneticProvider),
    ));
