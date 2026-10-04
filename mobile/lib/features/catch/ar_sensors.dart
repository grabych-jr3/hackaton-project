import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'ar_math.dart';

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
