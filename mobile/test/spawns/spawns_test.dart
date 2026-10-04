import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/app.dart';
import 'package:hackaton_project/data/api/api_client.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/data/repositories/places_repository.dart';
import 'package:hackaton_project/features/game/game_models.dart';
import 'package:hackaton_project/features/route/route_start.dart';
import 'package:hackaton_project/features/spawns/spawn.dart';
import 'package:hackaton_project/features/spawns/spawn_offset.dart';
import 'package:hackaton_project/features/spawns/spawn_providers.dart';
import 'package:hackaton_project/features/spawns/spawn_repository.dart';
import 'package:hackaton_project/features/spawns/spawn_widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const base = 'http://test/api/v1';

class _FileRepo implements PlacesRepository {
  @override
  Future<List<Place>> getPlaces() async => DemoPlacesRepository.parsePlaces(
      File(DemoPlacesRepository.assetPath).readAsStringSync());
}

class _FileSpawns extends DemoSpawnRepository {
  @override
  Future<List<Spawn>> getSpawns(SpawnBbox bbox) async =>
      DemoSpawnRepository.parseDemo(
          File(DemoSpawnRepository.assetPath).readAsStringSync());
}

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

final _spawnJson = {
  'id': 's-1',
  'lat': 50.06,
  'lng': 19.94,
  'speciesId': 'smok',
  'name': 'Smok',
  'emoji': '🐉',
  'rarity': 'legendary',
  'expiresAt': '2099-01-01T00:00:00Z',
  'kind': 'world',
  'caughtByMe': true,
};

/// Fake geolocator fix used by "spawn here" (null = no fix).
SpawnGpsFix? _fakeFix = (point: const LatLng(50.0617, 19.9373), accuracyM: 10);

Future<void> _pumpApp(WidgetTester tester, SpawnRepository spawns) async {
  SharedPreferences.setMockInitialValues({
    'needs_profile': jsonEncode(NeedsProfile.wheelchair.toJson()),
    ApiClient.tokenKey: 'tok',
  });
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      placesRepositoryProvider.overrideWithValue(_FileRepo()),
      currentHeadingProvider.overrideWithValue(() async => null),
      freshGpsFixProvider.overrideWithValue(() async => _fakeFix),
      spawnRepositoryProvider.overrideWithValue(spawns),
    ],
    child: const KrakowBezBarierApp(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({ApiClient.tokenKey: 'tok'});
    _fakeFix = (point: const LatLng(50.0617, 19.9373), accuracyM: 10);
  });

  test('API: GET /spawns parses a bare array and sends the bbox', () async {
    Uri? seen;
    final api = ApiClient(
        baseUrl: base,
        client: MockClient((req) async {
          seen = req.url;
          return _json([
            _spawnJson,
            {'id': 7, 'lat': 50.05, 'lng': 19.93, 'rarity': 'rare'},
          ]);
        }));
    final list = await ApiSpawnRepository(api)
        .getSpawns(const SpawnBbox(19.9, 50.0, 20.0, 50.1));
    expect(seen!.path, '/api/v1/spawns');
    expect(seen!.queryParameters['bbox'], '19.90000,50.00000,20.00000,50.10000');
    expect(list, hasLength(2));
    expect(list[0].name, 'Smok');
    expect(list[0].rarity, Rarity.legendary);
    expect(list[0].caughtByMe, isTrue);
    expect(list[0].expiresAt.year, 2099);
    expect(list[1].id, '7');
    expect(list[1].caughtByMe, isFalse);
  });

  test('demo: spawns.json has ~12 creatures around Kraków', () {
    final list = DemoSpawnRepository.parseDemo(
        File(DemoSpawnRepository.assetPath).readAsStringSync());
    expect(list.length, greaterThanOrEqualTo(10));
    expect(list.every((s) => s.isDemo), isTrue);
    expect(list.every((s) => SpawnBbox.krakow.contains(s.lat, s.lng)), isTrue);
    expect(list.any((s) => s.rarity == Rarity.legendary), isTrue);
    expect(list.where((s) => s.caughtByMe), hasLength(1));
    expect(
        File(DemoSpawnRepository.assetPath).readAsStringSync(),
        contains('DANE PRZYKŁADOWE'));
  });

  test('geo offset helper: N m ahead along the heading; spawn-here default is 0 m', () {
    const here = LatLng(50.06, 19.94);
    const d = Distance();
    for (final h in [0.0, 90.0, 225.0]) {
      final p = spawnAheadOf(here, h, meters: 8);
      expect(d(here, p), closeTo(8, 0.1));
      expect(d.bearing(here, p) % 360, closeTo(h, 0.5));
      expect(d(here, p), inInclusiveRange(6, 10));
    }
    expect(d(here, spawnAheadOf(here, 90)), closeTo(0, 0.01)); // test spawn = exact GPS point
    final north = spawnAheadOf(here, null, meters: 8);
    expect(north.longitude, closeTo(here.longitude, 1e-12));
    expect(north.latitude, greaterThan(here.latitude));
    expect(d(here, north), closeTo(8, 0.1));
  });

  test('demo: spawn here is kept in memory at the given point', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final repo = DemoSpawnRepository();
    const here = LatLng(50.06, 19.94);
    final at = spawnAheadOf(here, 90);
    final s = await repo.spawnHere(at.latitude, at.longitude, speciesId: 'smok');
    expect(s.kind, 'user');
    expect(s.name, 'Smok Wawelski');
    expect(s.lat, at.latitude);
    expect(s.lng, at.longitude);
    expect(const Distance()(here, s.point), closeTo(0, 0.1));
    final all = await repo.getSpawns(SpawnBbox.krakow);
    expect(all.map((x) => x.id), contains(s.id));
  });

  testWidgets('map shows creature markers; tap opens the sheet',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpApp(tester, _FileSpawns());
    final smok = find.bySemanticsLabel(
        RegExp(r'^Stworek: Smok Wawelski, legendarny, .* od Rynku Głównego$'));
    expect(smok, findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Stworek: Motylosmok, .*już złapany$')),
        findsOneWidget);

    await tester.tap(smok);
    await tester.pumpAndSettle();
    // No GPS: catching is blocked straight away.
    expect(find.text('Włącz lokalizację, aby złapać stworka'), findsOneWidget);
    final far = tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('Za daleko'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(far.onPressed, isNull);
    semantics.dispose();
  });

  testWidgets('spawn here posts the GPS position and centers the map',
      (tester) async {
    final posts = <Map<String, dynamic>>[];
    final created = <Map<String, dynamic>>[];
    final api = ApiClient(
        baseUrl: base,
        client: MockClient((req) async {
          if (req.method == 'POST' && req.url.path.endsWith('/spawns/here')) {
            expect(req.headers['Authorization'], 'Bearer tok');
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            posts.add(body);
            final spawn = {
              ..._spawnJson,
              'id': 'u-1',
              'lat': body['lat'],
              'lng': body['lng'],
              'kind': 'user',
              'caughtByMe': false,
            };
            created.add(spawn);
            return _json(spawn, 201);
          }
          return _json(created);
        }));
    await _pumpApp(tester, ApiSpawnRepository(api));

    final container = ProviderScope.containerOf(
        tester.element(find.byType(KrakowBezBarierApp)));
    // A stale cached location far away (e.g. SW corner of Kraków) must be
    // ignored: only the fresh GPS fix counts, never the map centre.
    container
        .read(userLocationProvider.notifier)
        .set(const UserLocation(LatLng(49.97674, 19.82533), accuracyM: 10));
    await tester.pumpAndSettle();

    final btn = find.byTooltip('Postaw stworka tutaj (test)');
    expect(tester.getSize(btn), const Size(52, 52));
    final gps = tester.getRect(find.byTooltip('Jak tłoczno?'));
    expect(tester.getRect(btn).top - gps.bottom, 12);
    expect(tester.getRect(btn).right, gps.right);

    await tester.tap(btn);
    await tester.pumpAndSettle();
    // Test spawn is placed exactly at the user's GPS position.
    expect(posts, hasLength(1));
    expect(posts.single['lat'], closeTo(50.0617, 1e-9));
    expect(posts.single['lng'], closeTo(19.9373, 1e-9));
    expect(
        const Distance()(const LatLng(50.0617, 19.9373),
            LatLng(posts.single['lat'] as double, posts.single['lng'] as double)),
        closeTo(0, 0.1));
    expect(find.text('Stworek pojawił się obok Ciebie — otwórz aparat'),
        findsOneWidget);
    final spawns = container.read(spawnsProvider).value!;
    expect(spawns.map((s) => s.id), contains('u-1'));
    final camera = MapCamera.of(tester.element(find.byType(MarkerLayer).first));
    expect(camera.center.latitude, closeTo(50.0617, 1e-6));
    expect(container.read(userLocationProvider)!.point,
        const LatLng(50.0617, 19.9373));
  });

  for (final (name, fix) in <(String, SpawnGpsFix?)>[
    ('no GPS fix', null),
    ('inaccurate fix', (point: const LatLng(50.0617, 19.9373), accuracyM: 120.0)),
  ]) {
    testWidgets('spawn here with $name: no POST, snackbar', (tester) async {
      final posts = <Object>[];
      final api = ApiClient(
          baseUrl: base,
          client: MockClient((req) async {
            if (req.method == 'POST') posts.add(req.body);
            return _json(const []);
          }));
      _fakeFix = fix;
      await _pumpApp(tester, ApiSpawnRepository(api));
      await tester.tap(find.byTooltip('Postaw stworka tutaj (test)'));
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
      expect(find.text(spawnNoFixMessage), findsOneWidget);
    });
  }

  test('spawnAtGps places the creature exactly at the fresh fix', () async {
    const fix = LatLng(50.068, 19.99);
    final c = ProviderContainer(overrides: [
      freshGpsFixProvider
          .overrideWithValue(() async => (point: fix, accuracyM: 5.0)),
      spawnRepositoryProvider.overrideWithValue(DemoSpawnRepository()),
    ]);
    addTearDown(c.dispose);
    for (final h in [0.0, 90.0, 213.0, 359.0]) {
      final s = await c.read(spawnsProvider.notifier).spawnAtGps(headingDeg: h);
      expect(const Distance()(fix, s!.point), lessThan(0.5));
    }
  });

  testWidgets('catch button is enabled only within the catch radius',
      (tester) async {
    await _pumpApp(tester, _FileSpawns());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(KrakowBezBarierApp)));
    final target = (await container.read(spawnsProvider.future)).first;

    Future<ButtonStyleButton> sheetButton(double meters) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SpawnSheet(
                  distance: SpawnDistance(target, meters, fromGps: true),
                  onCatch: () {}))));
      return tester.widget<ButtonStyleButton>(
          find.byWidgetPredicate((w) => w is ButtonStyleButton));
    }

    // Other part of the city (3 km away): blocked with "Podejdź bliżej".
    expect((await sheetButton(3000)).onPressed, isNull);
    expect(find.text('Podejdź bliżej (≤ 80 m), aby złapać'), findsOneWidget);
    expect(find.text('Za daleko'), findsOneWidget);

    // Next to it: allowed.
    expect((await sheetButton(20)).onPressed, isNotNull);
    expect(find.text('Złap aparatem'), findsOneWidget);
  });

  testWidgets('list mode has a "Stworki w pobliżu" section sorted by distance',
      (tester) async {
    await _pumpApp(tester, _FileSpawns());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(KrakowBezBarierApp)));
    await tester.tap(find.byTooltip('Lista miejsc'));
    await tester.pumpAndSettle();
    expect(find.text('Stworki w pobliżu'), findsOneWidget);
    expect(find.text('Za daleko'), findsWidgets); // no GPS in tests -> blocked
    final nearby = container.read(nearbySpawnsProvider);
    for (var i = 1; i < nearby.length; i++) {
      expect(nearby[i].meters, greaterThanOrEqualTo(nearby[i - 1].meters));
    }
    // The nearest creature is listed first.
    final first = nearby.first.spawn.name;
    expect(find.text(first), findsWidgets);
  });
}
