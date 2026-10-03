import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/data/models/accessibility_fact.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/data/repositories/places_repository.dart';

void main() {
  final now = DateTime(2026, 10, 3);
  late Map<String, Place> places;

  setUpAll(() {
    final raw = File(DemoPlacesRepository.assetPath).readAsStringSync();
    places = {for (final p in DemoPlacesRepository.parsePlaces(raw)) p.id: p};
  });

  test('demo dataset loads and is marked as demo', () {
    expect(places, hasLength(11));
    expect(places.values.every((p) => p.isDemo), isTrue);
  });

  test('owner fact is confirmed', () {
    expect(places['wawel']!.trustFor(Feature.steps, now), TrustLevel.confirmed);
  });

  test('OSM vs user report on steps is a conflict', () {
    final sukiennice = places['sukiennice']!;
    expect(sukiennice.hasConflict(Feature.steps, now), isTrue);
    expect(sukiennice.trustFor(Feature.steps, now), TrustLevel.conflicting);
  });

  test('place without facts has no data, never "accessible"', () {
    expect(
      places['nowa-prowincja']!.trustFor(Feature.steps, now),
      TrustLevel.noData,
    );
  });

  test('facts older than a year are outdated', () {
    expect(places['barbakan']!.trustFor(Feature.steps, now), TrustLevel.outdated);
  });

  test('AI and estimate facts keep their own trust level', () {
    expect(places['massolit']!.trustFor(Feature.steps, now), TrustLevel.ai);
    expect(places['wawel']!.trustFor(Feature.incline, now), TrustLevel.estimate);
  });

  test('profile survives JSON round trip', () {
    final profile = NeedsProfile.stroller.copyWith(needsBenches: true);
    final restored = NeedsProfile.fromJson(profile.toJson());
    expect(restored.toJson(), profile.toJson());
  });
}
