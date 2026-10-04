import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/features/route/route_panel.dart';
import 'package:hackaton_project/features/route/route_service.dart';
import 'package:hackaton_project/features/route/route_start.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

const wawel = Place(
  id: 'wawel',
  name: 'Zamek Królewski na Wawelu',
  category: PlaceCategory.attraction,
  lat: 50.0541,
  lng: 19.9354,
  facts: [],
);

const kazimierz = LatLng(50.0510, 19.9440);
const warszawa = LatLng(52.2297, 21.0122);

void main() {
  group('selectStart order', () {
    test('manual start wins over accurate GPS', () {
      final s = selectStart(
          manual: kazimierz,
          gps: const UserLocation(LatLng(50.06, 19.94), accuracyM: 20));
      expect(s.kind, StartKind.manual);
      expect(s.label, 'Wybrany punkt');
    });

    test('accurate GPS in Kraków is used with accuracy in label', () {
      final s = selectStart(
          gps: const UserLocation(LatLng(50.06, 19.94), accuracyM: 40));
      expect(s.kind, StartKind.gps);
      expect(s.label, 'Twoja lokalizacja (±40 m)');
    });

    test('inaccurate GPS falls back to Rynek', () {
      final s = selectStart(
          gps: const UserLocation(LatLng(50.06, 19.94), accuracyM: 1200));
      expect(s.kind, StartKind.rynek);
      expect(s.point, rynekGlowny);
      expect(s.label, 'Rynek Główny (lokalizacja niedokładna)');
    });

    test('GPS far from Kraków falls back to Rynek', () {
      final s =
          selectStart(gps: const UserLocation(warszawa, accuracyM: 10));
      expect(s.kind, StartKind.rynek);
      expect(s.label, contains('Rynek Główny'));
    });

    test('no GPS → Rynek, location unavailable', () {
      expect(selectStart().label, 'Rynek Główny (lokalizacja niedostępna)');
    });

    test('preference rynek overrides auto order; cycling options', () {
      final gps = const UserLocation(LatLng(50.06, 19.94), accuracyM: 30);
      expect(
          selectStart(
                  manual: kazimierz,
                  gps: gps,
                  preference: StartPreference.rynek)
              .kind,
          StartKind.rynek);
      expect(availableStarts(manual: kazimierz, gps: gps),
          [StartKind.rynek, StartKind.gps, StartKind.manual]);
      expect(availableStarts(), [StartKind.rynek]);
    });

    test('formatAccuracy uses Polish decimal comma', () {
      expect(formatAccuracy(1200), '±1,2 km');
      expect(formatAccuracy(40), '±40 m');
    });
  });

  test('manual start (as set by long-press) is used by RouteNotifier',
      () async {
    final container = ProviderContainer(overrides: [
      routeServiceProvider.overrideWithValue(RouteService(apiKey: '')),
    ]);
    addTearDown(container.dispose);
    container.read(manualStartProvider.notifier).set(kazimierz);
    await container.read(routeProvider.notifier).plan(wawel,
        myLocation: const LatLng(50.06, 19.94), accuracyM: 20);
    final route = container.read(routeProvider).value!;
    expect(route.startLabel, 'Wybrany punkt');
    expect(route.points.first, kazimierz);
    expect(route.isDemo, isTrue); // demo mode unaffected

    container.read(manualStartProvider.notifier).clear();
    await container.read(routeProvider.notifier).replan();
    expect(container.read(routeProvider).value!.startLabel,
        'Rynek Główny (lokalizacja niedostępna)');
  });

  test('API response: relaxed, fallbackReason and warnings parsed', () {
    final r = RouteService.parseApi({
      'geometry': [
        [50.06, 19.93],
        [50.05, 19.93],
      ],
      'distanceM': 900,
      'durationS': 800,
      'relaxed': true,
      'fallbackReason': 'Brak trasy z progami',
      'segments': [
        {'instruction': 'Prosto', 'distanceM': 900, 'warning': 'Kostka'},
      ],
    }, to: wawel, startLabel: 'Rynek Główny');
    expect(r.relaxed, isTrue);
    expect(r.fallbackReason, 'Brak trasy z progami');
    expect(r.segments.single.warning, 'Kostka');

    final plain = RouteService.parseApi(
        {'geometry': [], 'segments': []}, to: wawel, startLabel: 'x');
    expect(plain.relaxed, isFalse);
    expect(plain.fallbackReason, isNull);
  });

  test(
      'walking route with steps → wheelchair alternative; on 2009 retries '
      'without restrictions', () async {
    final fixture =
        File('test/route/fixtures/ors_rynek_wawel.json').readAsStringSync();
    final walking = jsonDecode(fixture) as Map<String, dynamic>;
    (walking['features'] as List).first['properties']['extras'] = {
      'waytypes': {
        'values': [
          [0, 2, 3],
          [2, 4, 8],
        ],
      },
    };
    final walkingBodies = <Map<String, dynamic>>[];
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      if (req.url.path.contains('foot-walking')) {
        walkingBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response.bytes(utf8.encode(jsonEncode(walking)), 200);
      }
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      if (bodies.length == 1) {
        return http.Response(
            jsonEncode({
              'error': {'code': 2009, 'message': 'Route could not be found'}
            }),
            404);
      }
      return http.Response.bytes(utf8.encode(fixture), 200);
    });
    final route = await RouteService(client: client, apiKey: 'k').plan(
        from: rynekGlowny,
        startLabel: 'Rynek Główny',
        to: wawel,
        profile: NeedsProfile.wheelchair);
    expect(bodies, hasLength(2));
    expect(bodies.first['radiuses'], [-1, -1]);
    expect(bodies.first['options'], isNotNull);
    expect(bodies.last.containsKey('options'), isFalse);
    expect(walkingBodies.single['extra_info'],
        ['steepness', 'surface', 'waytype']);
    expect(route.profile, 'foot-walking');
    expect(route.accessible, isFalse);
    expect(route.barriers.single.type, 'steps');
    expect(route.alternative!.relaxed, isTrue);
    expect(route.alternative!.isWheelchair, isTrue);
    expect(route.isDemo, isFalse);
  });

  test('ORS retry failing too → demo with ORS message', () async {
    final client = MockClient((req) async => http.Response(
        jsonEncode({
          'error': {'code': 2010, 'message': 'Point not routable'}
        }),
        404));
    final route = await RouteService(client: client, apiKey: 'k').plan(
        from: rynekGlowny,
        startLabel: 'Rynek Główny',
        to: wawel,
        profile: NeedsProfile.wheelchair);
    expect(route.isDemo, isTrue);
    expect(route.fallbackReason, contains('Point not routable'));
  });

  testWidgets('route panel shows relaxed note and cycles start',
      (tester) async {
    var cycled = 0;
    final route = RouteService.parseApi({
      'geometry': [
        [50.06, 19.93],
        [50.05, 19.93],
      ],
      'relaxed': true,
      'segments': [],
    }, to: wawel, startLabel: 'Wybrany punkt');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoutePanel(
          route: route,
          onClose: () {},
          onCycleStart: () => cycled++,
          onClearManualStart: () {},
        ),
      ),
    ));
    expect(find.text(RoutePanel.relaxedNote), findsOneWidget);
    expect(find.text('Usuń wybrany start'), findsOneWidget);
    await tester.tap(find.text('Start: Wybrany punkt'));
    expect(cycled, 1);
  });
}
