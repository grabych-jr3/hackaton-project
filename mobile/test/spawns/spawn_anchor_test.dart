import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/data/api/api_client.dart';
import 'package:hackaton_project/data/repositories/catch_repository.dart';
import 'package:hackaton_project/features/catch/catch_screen.dart';
import 'package:hackaton_project/features/game/game_models.dart';
import 'package:hackaton_project/features/route/route_start.dart';
import 'package:hackaton_project/features/spawns/spawn.dart';
import 'package:hackaton_project/features/spawns/spawn_offset.dart';
import 'package:hackaton_project/features/spawns/spawn_providers.dart';
import 'package:hackaton_project/features/spawns/spawn_repository.dart';
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _here = LatLng(50.0617, 19.9373);

Spawn _spawn(String id, LatLng p,
        {bool caught = false, Duration ttl = const Duration(hours: 1)}) =>
    Spawn(
      id: id,
      lat: p.latitude,
      lng: p.longitude,
      speciesId: 'smok',
      name: 'Smok $id',
      emoji: '🐉',
      rarity: Rarity.common,
      expiresAt: DateTime.now().add(ttl),
      caughtByMe: caught,
    );

LatLng _at(double bearing, double m) => spawnAheadOf(_here, bearing, meters: m);

/// getSpawns waits on [pending] (if set); spawnHere returns a fixed id.
class _FakeRepo implements SpawnRepository {
  _FakeRepo([this.list = const []]);
  List<Spawn> list;
  Completer<List<Spawn>>? pending;
  Duration ttl = const Duration(hours: 1);

  @override
  Future<List<Spawn>> getSpawns(SpawnBbox bbox) =>
      pending?.future ?? Future.value(list);

  @override
  Future<Spawn> spawnHere(double lat, double lng, {String? speciesId}) async =>
      _spawn('new', LatLng(lat, lng), ttl: ttl);
}

ProviderContainer _container(_FakeRepo repo) {
  final c = ProviderContainer(overrides: [
    spawnRepositoryProvider.overrideWithValue(repo),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('anchor bearing', () {
    test('stored on spawnHere, persisted, null for other spawns', () async {
      final c = _container(_FakeRepo());
      await c.read(spawnsProvider.future);
      await c.read(spawnsProvider.notifier).spawnHere(_here, headingDeg: -90);
      expect(c.read(spawnAnchorBearingProvider('new')), 270);
      expect(c.read(spawnAnchorBearingProvider('other')), isNull);
      await Future<void>.delayed(Duration.zero);
      final raw = (await SharedPreferences.getInstance())
          .getString(SpawnAnchorsNotifier.prefsKey)!;
      expect((jsonDecode(raw) as Map)['new']['b'], 270);
    });

    test('defaults to 0 (north) without heading', () async {
      final c = _container(_FakeRepo());
      await c.read(spawnsProvider.notifier).spawnHere(_here);
      expect(c.read(spawnAnchorBearingProvider('new')), 0);
    });

    test('loaded from prefs; expired entries ignored', () async {
      final future = DateTime.now().add(const Duration(hours: 1));
      final past = DateTime.now().subtract(const Duration(minutes: 1));
      SharedPreferences.setMockInitialValues({
        SpawnAnchorsNotifier.prefsKey: jsonEncode({
          'a': SpawnAnchor(45, future).toJson(),
          'b': SpawnAnchor(90, past).toJson(),
        }),
      });
      final c = _container(_FakeRepo());
      c.read(spawnAnchorsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.read(spawnAnchorBearingProvider('a')), 45);
      expect(c.read(spawnAnchorBearingProvider('b')), isNull);
    });

    test('expires with the spawn', () async {
      final repo = _FakeRepo()..ttl = const Duration(milliseconds: 30);
      final c = _container(repo);
      await c.read(spawnsProvider.notifier).spawnHere(_here, headingDeg: 10);
      expect(c.read(spawnAnchorBearingProvider('new')), 10);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      c.invalidate(spawnAnchorBearingProvider('new'));
      expect(c.read(spawnAnchorBearingProvider('new')), isNull);
    });
  });

  group('nearest spawn', () {
    Future<ProviderContainer> setup(List<Spawn> spawns, {bool gps = true}) async {
      final c = _container(_FakeRepo(spawns));
      if (gps) c.read(userLocationProvider.notifier).set(const UserLocation(_here));
      await c.read(spawnsProvider.future);
      return c;
    }

    test('picks the closest within range', () async {
      final c = await setup([_spawn('far', _at(0, 40)), _spawn('near', _at(90, 10))]);
      expect(c.read(nearestSpawnProvider(50))?.id, 'near');
      expect(c.read(nearestSpawnProvider(5)), isNull);
    });

    test('ignores spawns beyond range and expired ones', () async {
      final c = await setup([
        _spawn('gone', _at(0, 5), ttl: const Duration(seconds: -1)),
        _spawn('out', _at(0, 80)),
      ]);
      expect(c.read(nearestSpawnProvider(50)), isNull);
    });

    test('prefers not-caught; falls back to caught', () async {
      var c = await setup(
          [_spawn('caught', _at(0, 5), caught: true), _spawn('fresh', _at(0, 30))]);
      expect(c.read(nearestSpawnProvider(50))?.id, 'fresh');
      c = await setup([_spawn('caught', _at(0, 5), caught: true)]);
      expect(c.read(nearestSpawnProvider(50))?.id, 'caught');
    });

    test('null without a GPS fix', () async {
      final c = await setup([_spawn('near', _at(0, 5))], gps: false);
      expect(c.read(nearestSpawnProvider(50)), isNull);
    });

    test('recomputes when location changes', () async {
      final c = await setup([_spawn('a', _at(0, 30)), _spawn('b', _at(180, 30))]);
      c.read(userLocationProvider.notifier).set(UserLocation(_at(180, 25)));
      expect(c.read(nearestSpawnProvider(50))?.id, 'b');
    });
  });

  test('spawn-here survives an in-flight refetch, dropped once server returns it',
      () async {
    final repo = _FakeRepo([_spawn('old', _at(0, 30))]);
    final c = _container(repo);
    final sub = c.listen(spawnsProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(spawnsProvider.future);

    repo.pending = Completer();
    c.invalidate(spawnsProvider);
    c.read(spawnsProvider); // refetch in flight
    final created =
        await c.read(spawnsProvider.notifier).spawnHere(_here, headingDeg: 0);
    expect(c.read(spawnsProvider).value!.map((s) => s.id), contains('new'));

    repo.pending!.complete([_spawn('old', _at(0, 30))]);
    final after = await c.read(spawnsProvider.future);
    expect(after.map((s) => s.id), containsAll(['old', 'new']));

    // Server now returns it: no duplicate, local copy released.
    repo.pending = null;
    repo.list = [_spawn('old', _at(0, 30)), created];
    c.invalidate(spawnsProvider);
    final confirmed = await c.read(spawnsProvider.future);
    expect(confirmed.where((s) => s.id == 'new'), hasLength(1));
    expect(c.read(localSpawnsProvider.notifier).spawns, isEmpty);
  });

  testWidgets('Złap tab camera passes the nearest spawn to /catch/camera',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({ApiClient.tokenKey: 'tok'});
    final target = _spawn('s9', _at(0, 20));
    Uri? opened;
    final router = GoRouter(initialLocation: '/catch', routes: [
      GoRoute(path: '/catch', builder: (_, _) => const CatchScreen()),
      GoRoute(
          path: '/catch/camera',
          builder: (_, s) {
            opened = s.uri;
            return const Scaffold(body: Text('camera'));
          }),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        catchRepositoryProvider.overrideWithValue(CatchRepository(ApiClient(
            baseUrl: 'http://test',
            client: MockClient((_) async => throw UnimplementedError())))),
        nearestSpawnProvider.overrideWith((ref, d) => d >= 50 ? target : null),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Otwórz kamerę AR i złap stworka'));
    await tester.pumpAndSettle();
    expect(find.text('camera'), findsOneWidget);
    final q = opened!.queryParameters;
    expect(q['spawnId'], 's9');
    expect(q['emoji'], '🐉');
    expect(q['name'], 'Smok s9');
    expect(double.parse(q['spawnLat']!), closeTo(target.lat, 1e-9));
    expect(double.parse(q['spawnLng']!), closeTo(target.lng, 1e-9));
  });
}
