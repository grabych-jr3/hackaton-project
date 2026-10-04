import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:hackaton_project/app.dart';
import 'package:hackaton_project/features/shell/home_shell.dart';
import 'package:hackaton_project/data/api/api_client.dart';
import 'package:hackaton_project/data/repositories/catch_repository.dart';
import 'package:hackaton_project/features/catch/ar_catch_screen.dart';
import 'package:hackaton_project/features/catch/ar_projection.dart';
import 'package:hackaton_project/features/catch/ar_sensors.dart';
import 'package:hackaton_project/features/catch/gps_smoother.dart';
import 'package:hackaton_project/features/catch/pending_catches.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Position _pos(double lat, double lng, {double accuracy = 4, int sec = 0}) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime(2026).add(Duration(seconds: sec)),
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

const _lat0 = 50.06, _lng0 = 19.94;

/// Latitude [m] metres north of the user.
double _north(double m) => geoOffset(_lat0, _lng0, 0, m).lat;

/// Upright portrait, camera facing TRUE bearing [deg] (matrix is magnetic).
List<double> _facing(double deg) {
  final y = (deg - arDeclinationDeg) * math.pi / 180;
  final c = math.cos(y), s = math.sin(y);
  return [c, 0, -s, -s, 0, -c, 0, 1, 0];
}

void main() {
  late StreamController<List<double>> rot;
  late StreamController<Position> gps;

  List<Override> streamOverrides() {
    rot = StreamController();
    gps = StreamController();
    return [
      arRotationMatrixProvider.overrideWithValue(rot.stream),
      arPositionStreamProvider.overrideWithValue(() => gps.stream),
    ];
  }

  void setUpView(WidgetTester tester) {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pump(WidgetTester tester,
      {double? spawnLat, List<Override> extra = const []}) async {
    setUpView(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [...streamOverrides(), ...extra],
      child: MaterialApp(
        home: ArCatchScreen(
          spawnId: spawnLat == null ? null : 's1',
          speciesEmoji: '🐉',
          spawnLat: spawnLat,
          spawnLng: spawnLat == null ? null : _lng0,
          cameraEnabled: false,
        ),
      ),
    ));
  }

  Future<void> face(WidgetTester tester, double deg) async {
    for (var i = 0; i < 30; i++) {
      rot.add(_facing(deg));
    }
    await tester.pump();
    await tester.pump();
  }

  bool shutterEnabled(WidgetTester tester) =>
      tester
          .widget<InkWell>(find.ancestor(
              of: find.byIcon(Icons.camera_alt), matching: find.byType(InkWell)))
          .onTap !=
      null;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('12 m north: centred facing north, leaves screen when turning',
      (tester) async {
    await pump(tester, spawnLat: _north(12));
    gps.add(_pos(_lat0, _lng0));
    await face(tester, 0);

    final sprite = find.byKey(const ValueKey('ar-sprite'));
    expect(sprite, findsOneWidget);
    expect(find.text('Stworek przed Tobą — zrób zdjęcie'), findsOneWidget);
    expect(shutterEnabled(tester), isTrue);
    final c = tester.getCenter(sprite);
    expect(c.dx, closeTo(200, 2));
    expect(c.dy, greaterThan(400)); // below eye level

    await face(tester, 10);
    expect(tester.getCenter(sprite).dx, lessThan(150));

    await face(tester, 90);
    expect(sprite, findsNothing);
    expect(find.byKey(const ValueKey('ar-arrow-left')), findsOneWidget);
    expect(find.text('Obróć się w lewo — stworek 12 m'), findsOneWidget);
    expect(shutterEnabled(tester), isTrue); // no gating

    await tester.tap(find.byTooltip('Dane diagnostyczne'));
    await tester.pump();
    expect(find.byKey(const ValueKey('ar-debug')), findsOneWidget);
    expect(find.textContaining('dystans: 12.'), findsOneWidget);
    expect(find.textContaining('yaw (prawdziwa płn.): 90°'), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-fov-slider')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('GPS outlier is ignored (sprite does not jump)', (tester) async {
    await pump(tester, spawnLat: _north(12));
    gps.add(_pos(_lat0, _lng0));
    await face(tester, 0);
    final o = geoOffset(_lat0, _lng0, 90, 40);
    gps.add(_pos(o.lat, o.lng));
    await tester.pump();
    await face(tester, 0);
    expect(tester.getCenter(find.byKey(const ValueKey('ar-sprite'))).dx,
        closeTo(200, 2));
    await finish(tester);
  });

  Future<GoRouter> routed(WidgetTester tester, double meters) async {
    setUpView(tester);
    final router = GoRouter(initialLocation: '/map', routes: [
      GoRoute(
          path: '/map',
          builder: (_, _) => const Scaffold(body: Center(child: Text('MAPA')))),
      GoRoute(
        path: '/catch/camera',
        builder: (_, _) => ArCatchScreen(
          spawnId: 's1',
          spawnLat: _north(meters),
          spawnLng: _lng0,
          cameraEnabled: false,
          takePictureOverride: () async => Uint8List.fromList([1, 2, 3]),
        ),
      ),
    ]);
    // Upload never answers: the photo stays in the background queue.
    final never = MockClient((req) async => req.url.path.endsWith('/auth/anonymous')
        ? http.Response('{"token":"t"}', 200, headers: {'content-type': 'application/json'})
        : http.Response('{"catchId":"c1","status":"PENDING"}', 202,
            headers: {'content-type': 'application/json'}));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...streamOverrides(),
        catchRepositoryProvider.overrideWithValue(
            CatchRepository(ApiClient(baseUrl: 'http://test', client: never),
                sleep: (_) => Completer<void>().future)),
      ],
      child: MaterialApp.router(
          routerConfig: router, scaffoldMessengerKey: catchMessengerKey),
    ));
    router.push('/catch/camera');
    await tester.pumpAndSettle();
    gps.add(_pos(_lat0, _lng0));
    await face(tester, 0);
    return router;
  }

  testWidgets('after the shutter: back on /map with the saved snackbar', (tester) async {
    final router = await routed(tester, 12);
    expect(shutterEnabled(tester), isTrue);
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.routerDelegate.currentConfiguration.uri.path, '/map');
    expect(find.text(photoSavedMessage), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('too far (35 m): barrier-only photo + snackbar', (tester) async {
    await routed(tester, 35);
    expect(find.text('Podejdź bliżej — stworek 35 m stąd'), findsOneWidget);
    expect(shutterEnabled(tester), isTrue);
    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(barrierOnlyMessage), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('camera route is fullscreen: no bottom navigation, shutter present',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final router = buildAppRouter(
        initialLocation: '/catch/camera?spawnId=s1&spawnLat=52.00027&spawnLng=21.0');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        arCameraEnabledProvider.overrideWithValue(false),
        arRotationMatrixProvider.overrideWithValue(const Stream.empty()),
        arPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    expect(find.byType(ArCatchScreen), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byIcon(Icons.camera_alt), findsOneWidget);
    expect(find.byTooltip('Zamknij aparat'), findsOneWidget);
  });
}
