// TEMPORARY SHIM — delete at merge. The real `ArHeading`, `arHeadingProvider`
// and `arPitchProvider` (flutter_compass based) come from ar_sensors.dart.
// Same names/shapes so ar_catch_screen.dart compiles unchanged once removed.

import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ar_math.dart';
import 'ar_sensors.dart';

/// Camera heading sample.
class ArHeading {
  const ArHeading({required this.degrees, required this.accuracyDeg, required this.reliable});

  /// Degrees clockwise from north (0..360).
  final double degrees;

  /// Estimated accuracy (±deg).
  final double accuracyDeg;

  /// False when the compass needs calibration.
  final bool reliable;
}

/// Camera heading stream (shim: existing HeadingFusion on sensors_plus).
final arHeadingProvider = Provider<Stream<ArHeading>>((ref) {
  final s = ref.watch(arSensorStreamsProvider);
  late final StreamController<ArHeading> out;
  final fusion = HeadingFusion();
  final subs = <StreamSubscription<Vec3>>[];
  void emit() {
    final h = fusion.heading;
    if (h != null && !out.isClosed) {
      out.add(ArHeading(
          degrees: h, accuracyDeg: fusion.magValid ? 10 : 45, reliable: fusion.magValid));
    }
  }

  out = StreamController<ArHeading>(
    onListen: () {
      void sub(Stream<Vec3> st, void Function(Vec3) on) {
        try {
          subs.add(st.listen((e) {
            on(e);
            emit();
          }, onError: (Object _) {}, cancelOnError: true));
        } catch (_) {}
      }

      sub(s.accel, fusion.onAccel);
      sub(s.mag, fusion.onMag);
      sub(s.gyro, fusion.onGyro);
    },
    onCancel: () {
      for (final x in subs) {
        x.cancel();
      }
    },
  );
  return out.stream;
});

/// Camera pitch (radians, + above horizon, upright = 0).
final arPitchProvider = Provider<Stream<double>>((ref) {
  final s = ref.watch(arSensorStreamsProvider);
  return s.accel.map((a) => cameraElevationDeg(a) * pi / 180);
});
