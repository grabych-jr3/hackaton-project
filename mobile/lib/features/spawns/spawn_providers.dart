import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config.dart';
import '../../data/api/api_client.dart';
import '../map/place_filters.dart';
import '../route/route_start.dart';
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
      final fetched =
          await ref.read(spawnRepositoryProvider).getSpawns(bbox);
      return mergeSpawns(fetched, ref.read(localSpawnsProvider.notifier));
    } catch (_) {
      // Keep showing the last known creatures when the server is unreachable.
      if (previous != null) {
        return mergeSpawns(previous, ref.read(localSpawnsProvider.notifier));
      }
      rethrow;
    }
  }

  /// Places a test creature [spawnAheadM] in front of [here] (towards
  /// [headingDeg], north if unknown) and adds it to the list immediately.
  /// Its bearing from [here] is remembered as the AR anchor.
  Future<Spawn> spawnHere(LatLng here, {String? speciesId, double? headingDeg}) async {
    final at = spawnAheadOf(here, headingDeg);
    final spawn = await ref
        .read(spawnRepositoryProvider)
        .spawnHere(at.latitude, at.longitude, speciesId: speciesId);
    final local = ref.read(localSpawnsProvider.notifier)..add(spawn);
    ref
        .read(spawnAnchorsProvider.notifier)
        .put(spawn.id, ((headingDeg ?? 0) % 360 + 360) % 360, spawn.expiresAt);
    state = AsyncData(mergeSpawns(state.value ?? const <Spawn>[], local));
    return spawn;
  }
}

/// Drops expired spawns from [fetched] and appends locally created spawns the
/// server has not returned yet (kept until returned or expired), so a refetch
/// that was in flight while placing cannot drop the new creature.
List<Spawn> mergeSpawns(List<Spawn> fetched, LocalSpawnsNotifier local,
    {DateTime? now}) {
  final t = now ?? DateTime.now();
  final ids = {for (final s in fetched) s.id};
  final pending = [
    for (final s in local.spawns)
      if (!ids.contains(s.id) && s.expiresAt.isAfter(t)) s,
  ];
  local.prune(ids, t);
  return [
    for (final s in fetched)
      if (s.expiresAt.isAfter(t)) s,
    ...pending,
  ];
}

/// Spawns created on this device ("Postaw stworka tutaj") not yet confirmed
/// by a server fetch. Plain holder so it survives spawnsProvider rebuilds.
class LocalSpawnsNotifier extends Notifier<int> {
  final Map<String, Spawn> _spawns = {};
  @override
  int build() => 0;
  Iterable<Spawn> get spawns => _spawns.values;
  void add(Spawn s) => _spawns[s.id] = s;
  void prune(Set<String> returnedIds, DateTime now) => _spawns.removeWhere(
      (id, s) => returnedIds.contains(id) || !s.expiresAt.isAfter(now));
}

final localSpawnsProvider =
    NotifierProvider<LocalSpawnsNotifier, int>(LocalSpawnsNotifier.new);

/// World bearing (0..360) from the user's position at creation to a spawn
/// placed with "Postaw stworka tutaj", with its expiry.
class SpawnAnchor {
  const SpawnAnchor(this.bearingDeg, this.expiresAt);
  final double bearingDeg;
  final DateTime expiresAt;
  Map<String, dynamic> toJson() =>
      {'b': bearingDeg, 'e': expiresAt.toIso8601String()};
  static SpawnAnchor? fromJson(Object? j) {
    if (j is! Map) return null;
    final b = j['b'];
    final e = DateTime.tryParse('${j['e']}');
    if (b is! num || e == null) return null;
    return SpawnAnchor(b.toDouble(), e);
  }
}

/// Anchor bearings keyed by spawnId; persisted in shared_preferences.
class SpawnAnchorsNotifier extends Notifier<Map<String, SpawnAnchor>> {
  static const prefsKey = 'spawn_anchor_bearings';

  @override
  Map<String, SpawnAnchor> build() {
    _load();
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return;
      final now = DateTime.now();
      final loaded = <String, SpawnAnchor>{};
      for (final e in (jsonDecode(raw) as Map).entries) {
        final a = SpawnAnchor.fromJson(e.value);
        if (a != null && a.expiresAt.isAfter(now)) loaded['${e.key}'] = a;
      }
      state = {...loaded, ...state};
    } catch (_) {}
  }

  void put(String spawnId, double bearingDeg, DateTime expiresAt) {
    final now = DateTime.now();
    state = {
      for (final e in state.entries)
        if (e.value.expiresAt.isAfter(now)) e.key: e.value,
      spawnId: SpawnAnchor(bearingDeg, expiresAt),
    };
    _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey,
          jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}));
    } catch (_) {}
  }
}

final spawnAnchorsProvider =
    NotifierProvider<SpawnAnchorsNotifier, Map<String, SpawnAnchor>>(
        SpawnAnchorsNotifier.new);

/// Bearing (deg, 0..360) from the creation point to the spawn, for spawns
/// placed via "Postaw stworka tutaj"; null for others or once expired.
final spawnAnchorBearingProvider =
    Provider.family<double?, String>((ref, spawnId) {
  final a = ref.watch(spawnAnchorsProvider)[spawnId];
  if (a == null || !a.expiresAt.isAfter(DateTime.now())) return null;
  return a.bearingDeg;
});

/// Nearest active spawn to the GPS fix within [maxDistanceM]; not-yet-caught
/// spawns are preferred. Null without a GPS fix.
final nearestSpawnProvider =
    Provider.family<Spawn?, double>((ref, maxDistanceM) {
  final loc = ref.watch(userLocationProvider);
  if (loc == null) return null;
  final spawns = ref.watch(spawnsProvider).value ?? const <Spawn>[];
  final now = DateTime.now();
  const dist = Distance();
  Spawn? best;
  Spawn? bestCaught;
  var bestD = double.infinity;
  var bestCaughtD = double.infinity;
  for (final s in spawns) {
    if (!s.expiresAt.isAfter(now)) continue;
    final d = dist(loc.point, s.point);
    if (d > maxDistanceM) continue;
    if (s.caughtByMe) {
      if (d < bestCaughtD) {
        bestCaught = s;
        bestCaughtD = d;
      }
    } else if (d < bestD) {
      best = s;
      bestD = d;
    }
  }
  return best ?? bestCaught;
});

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
