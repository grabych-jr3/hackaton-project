import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
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

/// "Postaw stworka tutaj" refuses fixes worse than this.
const spawnMaxAccuracyM = 50.0;

/// Shown when no accurate fresh GPS fix is available for "spawn here".
const spawnNoFixMessage = 'Brak dokładnej lokalizacji GPS — spróbuj na zewnątrz';

/// A fresh GPS reading.
typedef SpawnGpsFix = ({LatLng point, double accuracyM});

/// One-shot FRESH high-accuracy GPS fix (<= 15 s), or null when unavailable.
/// "Spawn here" must never use the map centre or a cached/stale position.
final freshGpsFixProvider =
    Provider<Future<SpawnGpsFix?> Function()>((ref) => () async {
          try {
            if (!await Geolocator.isLocationServiceEnabled()) return null;
            var perm = await Geolocator.checkPermission();
            if (perm == LocationPermission.denied) {
              perm = await Geolocator.requestPermission();
            }
            if (perm == LocationPermission.denied ||
                perm == LocationPermission.deniedForever) {
              return null;
            }
            final pos = await Geolocator.getCurrentPosition(
                locationSettings: const LocationSettings(
                    accuracy: LocationAccuracy.high,
                    timeLimit: Duration(seconds: 15)));
            return (
              point: LatLng(pos.latitude, pos.longitude),
              accuracyM: pos.accuracy
            );
          } catch (_) {
            return null;
          }
        });

/// Fresh fix usable for placing a creature (null when missing/too coarse).
Future<SpawnGpsFix?> accurateSpawnFix(
    Future<SpawnGpsFix?> Function() getFix) async {
  final fix = await getFix();
  if (fix == null || fix.accuracyM > spawnMaxAccuracyM) {
    debugPrint(
        'spawn-here: no accurate GPS fix (${fix?.accuracyM} m) - not created');
    return null;
  }
  return fix;
}
