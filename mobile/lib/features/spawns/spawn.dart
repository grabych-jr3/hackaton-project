import 'package:latlong2/latlong.dart';

import '../game/game_models.dart';

/// Max distance (m) from which a spawn can be caught.
const catchRadiusM = 80.0;

/// A creature standing on the map (`GET /spawns`).
class Spawn {
  const Spawn({
    required this.id,
    required this.lat,
    required this.lng,
    required this.speciesId,
    required this.name,
    required this.emoji,
    required this.rarity,
    required this.expiresAt,
    this.kind = 'world',
    this.caughtByMe = false,
    this.isDemo = false,
  });

  final String id;
  final double lat;
  final double lng;
  final String speciesId;
  final String name;
  final String emoji;
  final Rarity rarity;
  final DateTime expiresAt;
  final String kind;
  final bool caughtByMe;
  final bool isDemo;

  LatLng get point => LatLng(lat, lng);

  /// [defaultTtl] is used when `expiresAt` is missing (demo data).
  factory Spawn.fromJson(Map<String, dynamic> j,
      {bool isDemo = false, Duration defaultTtl = const Duration(hours: 2)}) {
    final rarity = Rarity.values.firstWhere(
        (r) => r.name == (j['rarity'] as String?)?.toLowerCase(),
        orElse: () => Rarity.common);
    final exp = j['expiresAt'] as String?;
    return Spawn(
      id: j['id'].toString(),
      lat: (j['lat'] as num).toDouble(),
      lng: (j['lng'] as num).toDouble(),
      speciesId: (j['speciesId'] ?? '').toString(),
      name: (j['name'] ?? 'Stworek').toString(),
      emoji: (j['emoji'] ?? '🐾').toString(),
      rarity: rarity,
      expiresAt: (exp == null ? null : DateTime.tryParse(exp)) ??
          DateTime.now().add(defaultTtl),
      kind: (j['kind'] ?? 'world').toString(),
      caughtByMe: j['caughtByMe'] == true,
      isDemo: isDemo,
    );
  }
}

/// Visible map area: `minLng,minLat,maxLng,maxLat`.
class SpawnBbox {
  const SpawnBbox(this.minLng, this.minLat, this.maxLng, this.maxLat);

  /// Central Kraków (used before the map reports its camera).
  static const krakow = SpawnBbox(19.89, 50.03, 19.99, 50.09);

  final double minLng;
  final double minLat;
  final double maxLng;
  final double maxLat;

  bool contains(double lat, double lng) =>
      lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng;

  String toQuery() => [minLng, minLat, maxLng, maxLat]
      .map((v) => v.toStringAsFixed(5))
      .join(',');

  @override
  bool operator ==(Object other) =>
      other is SpawnBbox && other.toQuery() == toQuery();

  @override
  int get hashCode => toQuery().hashCode;
}
