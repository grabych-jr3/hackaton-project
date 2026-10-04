import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import '../../data/api/api_client.dart';
import '../game/game_models.dart';
import 'spawn.dart';

abstract class SpawnRepository {
  Future<List<Spawn>> getSpawns(SpawnBbox bbox);

  /// Test helper: places a creature next to [lat]/[lng] (kind `user`, 2 h).
  Future<Spawn> spawnHere(double lat, double lng, {String? speciesId});
}

/// `GET /spawns?bbox=…` / `POST /spawns/here`.
class ApiSpawnRepository implements SpawnRepository {
  ApiSpawnRepository(this._api);

  final ApiClient _api;

  static List<Spawn> parseList(Object? json) => [
        for (final j in (json as List? ?? const []))
          Spawn.fromJson(j as Map<String, dynamic>),
      ];

  @override
  Future<List<Spawn>> getSpawns(SpawnBbox bbox) async =>
      parseList(await _api.get('/spawns?bbox=${bbox.toQuery()}', auth: true));

  @override
  Future<Spawn> spawnHere(double lat, double lng, {String? speciesId}) async {
    final json = await _api.post('/spawns/here',
        auth: true,
        body: {'lat': lat, 'lng': lng, 'speciesId': ?speciesId});
    return Spawn.fromJson(json as Map<String, dynamic>);
  }
}

/// DANE PRZYKŁADOWE from `assets/demo/spawns.json`; "spawn here" is kept in
/// memory only.
class DemoSpawnRepository implements SpawnRepository {
  DemoSpawnRepository({AssetBundle? bundle, Random? random})
      : _bundle = bundle ?? rootBundle,
        _random = random ?? Random();

  static const assetPath = 'assets/demo/spawns.json';

  final AssetBundle _bundle;
  final Random _random;
  List<Spawn>? _demo;
  final List<Spawn> _local = [];
  int _seq = 0;

  static List<Spawn> parseDemo(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    return [
      for (final j in json['spawns'] as List)
        Spawn.fromJson(j as Map<String, dynamic>, isDemo: true),
    ];
  }

  static const _pool = [
    ('golab', 'Gołąb', '🐦', Rarity.common),
    ('jez', 'Jeż', '🦔', Rarity.common),
    ('lis', 'Lis', '🦊', Rarity.common),
    ('sowa', 'Sowa', '🦉', Rarity.rare),
    ('wydra', 'Wydra', '🦦', Rarity.rare),
    ('smok', 'Smok', '🐉', Rarity.legendary),
  ];

  @override
  Future<List<Spawn>> getSpawns(SpawnBbox bbox) async {
    _demo ??= parseDemo(await _bundle.loadString(assetPath));
    final now = DateTime.now();
    _local.removeWhere((s) => s.expiresAt.isBefore(now));
    return [..._demo!, ..._local]
        .where((s) => bbox.contains(s.lat, s.lng))
        .toList();
  }

  @override
  Future<Spawn> spawnHere(double lat, double lng, {String? speciesId}) async {
    final pick = _pool.firstWhere((p) => p.$1 == speciesId,
        orElse: () => _pool[_random.nextInt(_pool.length)]);
    // ~10–20 m away, so it is "next to you" and immediately catchable.
    final angle = _random.nextDouble() * 2 * pi;
    final d = 10 + _random.nextDouble() * 10;
    final dLat = d * cos(angle) / 111320;
    final dLng = d * sin(angle) / (111320 * cos(lat * pi / 180));
    final spawn = Spawn(
      id: 'local-${++_seq}',
      lat: lat + dLat,
      lng: lng + dLng,
      speciesId: pick.$1,
      name: pick.$2,
      emoji: pick.$3,
      rarity: pick.$4,
      expiresAt: DateTime.now().add(const Duration(hours: 2)),
      kind: 'user',
      isDemo: true,
    );
    _local.add(spawn);
    return spawn;
  }
}
