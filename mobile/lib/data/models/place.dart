import 'accessibility_fact.dart';

enum PlaceCategory {
  attraction,
  museum,
  church,
  cafe,
  restaurant,
  park,
  bridge;

  static PlaceCategory fromJson(String value) =>
      PlaceCategory.values.firstWhere((c) => c.name == value);
}

class Place {
  const Place({
    required this.id,
    required this.name,
    required this.category,
    required this.lat,
    required this.lng,
    required this.facts,
    this.address,
    this.isDemo = false,
  });

  final String id;
  final String name;
  final PlaceCategory category;
  final double lat;
  final double lng;
  final String? address;
  final List<AccessibilityFact> facts;

  /// Sample data must be clearly marked in the UI ("DANE PRZYKŁADOWE").
  final bool isDemo;

  List<AccessibilityFact> factsFor(Feature feature) =>
      facts.where((f) => f.feature == feature).toList();

  /// Two non-outdated facts about the same feature disagree.
  bool hasConflict(Feature feature, DateTime now) {
    final values = factsFor(feature)
        .where((f) => f.trustAt(now) != TrustLevel.outdated)
        .map((f) => f.value)
        .toSet();
    return values.length > 1;
  }

  TrustLevel trustFor(Feature feature, DateTime now) {
    final list = factsFor(feature);
    if (list.isEmpty) return TrustLevel.noData;
    if (hasConflict(feature, now)) return TrustLevel.conflicting;
    final levels = list.map((f) => f.trustAt(now)).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return levels.first;
  }

  factory Place.fromJson(Map<String, dynamic> json, {bool isDemo = false}) {
    return Place(
      id: json['id'] as String,
      name: json['name'] as String,
      category: PlaceCategory.fromJson(json['category'] as String),
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      address: json['address'] as String?,
      facts: (json['facts'] as List<dynamic>? ?? [])
          .map((f) => AccessibilityFact.fromJson(f as Map<String, dynamic>))
          .toList(),
      isDemo: isDemo,
    );
  }
}
