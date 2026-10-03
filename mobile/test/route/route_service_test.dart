import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/features/route/route_service.dart';

const wawel = Place(
  id: 'wawel',
  name: 'Zamek Królewski na Wawelu',
  category: PlaceCategory.attraction,
  lat: 50.0541,
  lng: 19.9354,
  facts: [],
);

void main() {
  test('parses real ORS wheelchair response into street-following route', () {
    final json = jsonDecode(
        File('test/route/fixtures/ors_rynek_wawel.json').readAsStringSync());
    final route = RouteService.parseOrs(json as Map<String, dynamic>,
        to: wawel, startLabel: 'Rynek Główny');

    expect(route.isDemo, isFalse);
    expect(route.points.length, greaterThan(10)); // follows streets
    expect(route.distanceM, closeTo(1521, 1));
    expect(route.segments, isNotEmpty);
    expect(route.segments.first.instruction, isNotEmpty);
  });

  test('without API key falls back to a clearly marked demo route', () async {
    final route = await RouteService(apiKey: '').plan(
      from: rynekGlowny,
      startLabel: 'Rynek Główny',
      to: wawel,
      profile: NeedsProfile.wheelchair,
    );
    expect(route.isDemo, isTrue);
    expect(route.fallbackReason, isNotNull);
    expect(route.segments.last.instruction, contains('Wawel'));
  });
}
