import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../data/api/api_client.dart';
import '../map/place_filters.dart';
import 'spawn.dart';
import 'spawn_offset.dart';
import 'spawn_repository.dart';

final spawnRepositoryProvider = Provider<SpawnRepository>((ref) => useApi
    ? ApiSpawnRepository(ref.watch(apiClientProvider))
    : DemoSpawnRepository());

/// How often visible spawns are refreshed.
const spawnRefreshInterval = Duration(seconds: 60);

/// Visible map area (set by the map, debounced). Defaults to central Kraków.
class SpawnBboxNotifier extends Notifier<SpawnBbox> {
  @override
  SpawnBbox build() => SpawnBbox.krakow;
  void set(SpawnBbox bbox) {
    if (bbox != state) state = bbox;
  }
}

final spawnBboxProvider =
    NotifierProvider<SpawnBboxNotifier, SpawnBbox>(SpawnBboxNotifier.new);

/// Spawns in the visible area; refetched on bbox change and every 60 s.
class SpawnsNotifier extends AsyncNotifier<List<Spawn>> {
  @override
  Future<List<Spawn>> build() async {
    final bbox = ref.watch(spawnBboxProvider);
    final timer = Timer(spawnRefreshInterval, ref.invalidateSelf);
    ref.onDispose(timer.cancel);
    final previous = state.value;
    try {
      final now = DateTime.now();
      return (await ref.read(spawnRepositoryProvider).getSpawns(bbox))
          .where((s) => s.expiresAt.isAfter(now))
          .toList();
    } catch (_) {
      // Keep showing the last known creatures when the server is unreachable.
      if (previous != null) return previous;
      rethrow;
    }
  }

  /// Places a test creature [spawnAheadM] in front of [here] (towards
  /// [headingDeg], north if unknown) and adds it to the list.
  Future<Spawn> spawnHere(LatLng here, {String? speciesId, double? headingDeg}) async {
    final at = spawnAheadOf(here, headingDeg);
    final spawn = await ref
        .read(spawnRepositoryProvider)
        .spawnHere(at.latitude, at.longitude, speciesId: speciesId);
    final current = state.value ?? const <Spawn>[];
    state = AsyncData([
      for (final s in current)
        if (s.id != spawn.id) s,
      spawn,
    ]);
    return spawn;
  }
}

final spawnsProvider =
    AsyncNotifierProvider<SpawnsNotifier, List<Spawn>>(SpawnsNotifier.new);

/// A spawn with its distance from the distance origin (GPS or Rynek).
class SpawnDistance {
  const SpawnDistance(this.spawn, this.meters, {required this.fromGps});
  final Spawn spawn;
  final double meters;
  final bool fromGps;

  bool get inRange => fromGps && meters <= catchRadiusM;

  /// "120 m od Ciebie" / "1,2 km od Rynku Głównego".
  String get label =>
      '${formatDistance(meters)} ${fromGps ? 'od Ciebie' : 'od Rynku Głównego'}';
}

/// Visible spawns sorted by distance (nearest first).
final nearbySpawnsProvider = Provider<List<SpawnDistance>>((ref) {
  final spawns = ref.watch(spawnsProvider).value ?? const <Spawn>[];
  final origin = ref.watch(distanceOriginProvider);
  const dist = Distance();
  return [
    for (final s in spawns)
      SpawnDistance(s, dist(origin.point, s.point), fromGps: origin.fromGps),
  ]..sort((a, b) => a.meters.compareTo(b.meters));
});
