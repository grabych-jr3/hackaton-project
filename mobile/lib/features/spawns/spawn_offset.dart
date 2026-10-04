import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../catch/ar_sensors.dart';
import '../catch/gps_smoother.dart';

/// "Postaw stworka tutaj" places the test creature this far in front of the
/// user (inside the 6–10 m band) so it is immediately visible in the camera.
const spawnAheadM = 8.0;

/// Point [meters] ahead of [here] in the [headingDeg] direction; north when
/// the heading is unknown.
LatLng spawnAheadOf(LatLng here, double? headingDeg, {double meters = spawnAheadM}) {
  final p = geoOffset(here.latitude, here.longitude, headingDeg ?? 0, meters);
  return LatLng(p.lat, p.lng);
}

/// One-shot current compass heading (null when unavailable within 800 ms).
final currentHeadingProvider = Provider<Future<double?> Function()>((ref) => () async {
      try {
        final h = await ref
            .read(arHeadingProvider)
            .first
            .timeout(const Duration(milliseconds: 800));
        return h.degrees;
      } catch (_) {
        return null;
      }
    });
