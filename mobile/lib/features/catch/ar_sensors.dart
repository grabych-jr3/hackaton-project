import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'ar_math.dart';

/// Raw motion sensor streams (injectable for tests).
class ArSensorStreams {
  const ArSensorStreams({required this.accel, required this.mag, required this.gyro});

  final Stream<Vec3> accel;
  final Stream<Vec3> mag;
  final Stream<Vec3> gyro;

  /// Real device sensors (sensors_plus), ~50 Hz.
  factory ArSensorStreams.device() {
    const period = Duration(milliseconds: 20);
    return ArSensorStreams(
      accel: accelerometerEventStream(samplingPeriod: period)
          .map((e) => Vec3(e.x, e.y, e.z)),
      mag: magnetometerEventStream(samplingPeriod: period)
          .map((e) => Vec3(e.x, e.y, e.z)),
      gyro: gyroscopeEventStream(samplingPeriod: period)
          .map((e) => Vec3(e.x, e.y, e.z)),
    );
  }
}

final arSensorStreamsProvider = Provider<ArSensorStreams>((_) => ArSensorStreams.device());

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

/// Fuses accelerometer + magnetometer + gyroscope into a smooth camera
/// heading (complementary filter) and elevation.
class HeadingFusion {
  HeadingFusion({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  Vec3? _accel; // low-passed gravity
  Vec3? _mag;
  double? _magHeading; // low-passed compass heading
  double? heading;
  double? elevation;
  DateTime? _lastGyro;
  bool magValid = true;

  bool get hasAccel => _accel != null;

  void onAccel(Vec3 a) {
    final p = _accel;
    _accel = p == null
        ? a
        : Vec3(p.x + 0.2 * (a.x - p.x), p.y + 0.2 * (a.y - p.y), p.z + 0.2 * (a.z - p.z));
    elevation = cameraElevationDeg(_accel!);
    _updateMagnetic();
  }

  void onMag(Vec3 m) {
    _mag = m;
    magValid = magneticFieldLooksValid(m);
    _updateMagnetic();
  }

  void _updateMagnetic() {
    final a = _accel, m = _mag;
    if (a == null || m == null) return;
    final h = headingFromSensors(a, m);
    if (h == null) return;
    _magHeading = lowPassAngle(_magHeading, h, 0.15);
    // No gyro yet (or none at all): follow the filtered compass.
    if (heading == null || _lastGyro == null) heading = _magHeading;
  }

  void onGyro(Vec3 g) {
    final now = _clock();
    final last = _lastGyro;
    _lastGyro = now;
    final a = _accel;
    if (last == null || a == null || heading == null) return;
    final dt = now.difference(last).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 0.5) return;
    heading = fuseHeading(
      previous: heading,
      magnetic: _magHeading,
      gyroRateDegPerSec: headingRateDegPerSec(g, a),
      dtSec: dt,
    );
  }
}

/// Tests turn the camera plugin off (overlay renders on black).
final arCameraEnabledProvider = Provider<bool>((_) => true);
