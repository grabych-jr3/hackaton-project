import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hackaton_project/features/catch/ar_catch_screen.dart';
import 'package:hackaton_project/features/catch/ar_projection.dart';
import 'package:hackaton_project/features/catch/ar_sensors.dart';
import 'package:hackaton_project/features/catch/gps_smoother.dart';
import 'package:hackaton_project/features/game/game_models.dart';
import 'package:hackaton_project/features/route/route_start.dart';
import 'package:hackaton_project/features/spawns/spawn.dart';
import 'package:hackaton_project/features/spawns/spawn_providers.dart';
import 'package:hackaton_project/features/spawns/spawn_offset.dart';
import 'package:latlong2/latlong.dart';
import 'package:hackaton_project/features/spawns/spawn_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _lat0 = 50.06, _lng0 = 19.94;

Position _pos(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime(2026),
      accuracy: 4,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

List<double> _facing(double deg) {
  final y = (deg - arDeclinationDeg) * math.pi / 180;
  final c = math.cos(y), s = math.sin(y);
  return [c, 0, -s, -s, 0, -c, 0, 1, 0];
}

Spawn _spawn(String id, String name, String emoji, double bearing, double m) {
  final p = geoOffset(_lat0, _lng0, bearing, m);
  return Spawn(
    id: id,
    lat: p.lat,
    lng: p.lng,
    speciesId: id,
    name: name,
    emoji: emoji,
    rarity: Rarity.common,
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
}

class _FakeRepo implements SpawnRepository {
  _FakeRepo(this.spawns);
  final List<Spawn> spawns;
  int fetches = 0;
  @override
  Future<List<Spawn>> getSpawns(SpawnBbox bbox) async {
    fetches++;
    return [...spawns];
  }

  @override
  Future<Spawn> spawnHere(double lat, double lng, {String? speciesId}) async {
    final s = Spawn(
      id: 'new',
      lat: lat,
      lng: lng,
      speciesId: 'smok',
      name: 'Smok',
      emoji: '🐲',
      rarity: Rarity.common,
      expiresAt: DateTime.now().add(const Duration(hours: 2)),
    );
    spawns.add(s);
    return s;
  }
}

void main() {
  late StreamController<List<double>> rot;
  late StreamController<Position> gps;
  late _FakeRepo repo;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, List<Spawn> spawns) async {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    rot = StreamController();
    gps = StreamController();
    repo = _FakeRepo(spawns);
    container = ProviderContainer(overrides: [
      arRotationMatrixProvider.overrideWithValue(rot.stream),
      arPositionStreamProvider.overrideWithValue(() => gps.stream),
      spawnRepositoryProvider.overrideWithValue(repo),
      freshGpsFixProvider.overrideWithValue(
          () async => (point: const LatLng(_lat0, _lng0), accuracyM: 5.0)),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ArCatchScreen(cameraEnabled: false)),
    ));
    await tester.pump();
  }

  Future<void> fixAndFace(WidgetTester tester, double deg) async {
    gps.add(_pos(_lat0, _lng0));
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      rot.add(_facing(deg));
    }
    await tester.pump();
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('no fix yet: waiting for GPS (not "no creatures")', (tester) async {
    await pump(tester, [_spawn('a', 'Lis', '🦊', 0, 10)]);
    expect(find.text(waitingGpsHint), findsOneWidget);
    expect(find.textContaining(noSpawnsHint), findsNothing);
    expect(find.byKey(const ValueKey('ar-spawn-here')), findsNothing);
    await finish(tester);
  });

  testWidgets('all spawns within 60 m shown, nearest is target, tap selects',
      (tester) async {
    await pump(tester, [
      _spawn('a', 'Lis', '🦊', 0, 15),
      _spawn('b', 'Sowa', '🦉', 10, 40),
      _spawn('far', 'Wilk', '🐺', 0, 300),
    ]);
    await fixAndFace(tester, 0);
    expect(find.byKey(const ValueKey('ar-item-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-item-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-item-far')), findsNothing);
    expect(find.text('Lis · 15 m'), findsOneWidget);
    expect(find.text('Sowa · 40 m'), findsOneWidget);
    // Nearest = target (carries the ar-sprite key).
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('ar-item-a')),
            matching: find.byKey(const ValueKey('ar-sprite'))),
        findsOneWidget);
    expect(find.text('Stworek przed Tobą — zrób zdjęcie'), findsOneWidget);

    await tester.tap(find.text('Sowa · 40 m'));
    await tester.pump();
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('ar-item-b')),
            matching: find.byKey(const ValueKey('ar-sprite'))),
        findsOneWidget);
    expect(find.text('Podejdź bliżej — stworek 40 m stąd'), findsOneWidget);

    await tester.tap(find.byTooltip('Dane diagnostyczne'));
    await tester.pump();
    expect(find.textContaining('stworki wczytane: 3, w 60 m: 2'), findsOneWidget);
    expect(find.textContaining('cel: b'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('camera fix updates userLocationProvider; spawns refetched',
      (tester) async {
    await pump(tester, [_spawn('a', 'Lis', '🦊', 0, 15)]);
    expect(container.read(userLocationProvider), isNull);
    await fixAndFace(tester, 0);
    final loc = container.read(userLocationProvider);
    expect(loc, isNotNull);
    expect(loc!.point.latitude, closeTo(_lat0, 1e-6));
    final before = repo.fetches;
    await tester.pump(arSpawnRefreshInterval);
    await tester.pump();
    expect(repo.fetches, greaterThan(before));
    await finish(tester);
  });

  testWidgets('none within 60 m: hint with nearest + spawn-here button',
      (tester) async {
    await pump(tester, [_spawn('far', 'Lis', '🦊', 90, 340)]);
    await fixAndFace(tester, 0);
    expect(find.textContaining('$noSpawnsHint — najbliższy: Lis, 340 m'),
        findsOneWidget);
    expect(find.textContaining('(w prawo)'), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-far-arrow')), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-sprite')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ar-spawn-here')));
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      rot.add(_facing(0));
    }
    await tester.pump();
    expect(find.byKey(const ValueKey('ar-item-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-sprite')), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-spawn-here')), findsNothing);
    await finish(tester);
  });
}
