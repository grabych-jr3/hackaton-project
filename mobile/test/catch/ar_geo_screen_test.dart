import 'dart:async';
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
import 'package:hackaton_project/features/catch/pending_catches.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hackaton_project/features/catch/ar_math.dart';
import 'package:hackaton_project/features/catch/ar_sensors.dart';

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

void main() {
  late StreamController<Vec3> accel, mag, gyro;
  late StreamController<Position> gps;

  Future<void> pump(WidgetTester tester, {required double spawnLat}) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    accel = StreamController();
    mag = StreamController();
    gyro = StreamController();
    gps = StreamController();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        arSensorStreamsProvider.overrideWithValue(
            ArSensorStreams(accel: accel.stream, mag: mag.stream, gyro: gyro.stream)),
        arPositionStreamProvider.overrideWithValue(() => gps.stream),
      ],
      child: MaterialApp(
        home: ArCatchScreen(
          spawnId: 's1',
          speciesEmoji: '🐉',
          spawnLat: spawnLat,
          spawnLng: 21.0,
          cameraEnabled: false,
        ),
      ),
    ));
  }

  Future<void> face(WidgetTester tester, Vec3 m) async {
    for (var i = 0; i < 80; i++) {
      accel.add(const Vec3(0, 9.81, 0));
      mag.add(m);
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

  testWidgets('creature anchored north: visible facing north, arrow facing east',
      (tester) async {
    await pump(tester, spawnLat: 52.00027); // ~30 m north
    gps.add(_pos(52.0, 21.0));
    await face(tester, const Vec3(0, -40, -20)); // camera → north

    expect(find.byKey(const ValueKey('ar-sprite')), findsOneWidget);
    expect(find.text('Stworek przed Tobą — zrób zdjęcie'), findsOneWidget);
    expect(shutterEnabled(tester), isTrue);
    final spriteCenter = tester.getCenter(find.byKey(const ValueKey('ar-sprite')));
    expect(spriteCenter.dx, closeTo(200, 2));

    await face(tester, const Vec3(-20, -40, 0)); // camera → east
    expect(find.byKey(const ValueKey('ar-sprite')), findsNothing);
    expect(find.byKey(const ValueKey('ar-arrow-left')), findsOneWidget);
    expect(find.text('Obróć się w lewo — stworek 30 m stąd'), findsOneWidget);
    expect(shutterEnabled(tester), isFalse);

    await tester.tap(find.byTooltip('Dane diagnostyczne'));
    await tester.pump();
    expect(find.byKey(const ValueKey('ar-debug')), findsOneWidget);
    expect(find.textContaining('dystans: 30.'), findsOneWidget);

    await face(tester, const Vec3(0, 0, 3)); // bogus field
    expect(find.text('Skalibruj kompas: porusz telefonem ósemką'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('too far: visible but shutter disabled', (tester) async {
    await pump(tester, spawnLat: 52.001); // ~111 m north
    gps.add(_pos(52.0, 21.0));
    await face(tester, const Vec3(0, -40, -20));
    expect(find.byKey(const ValueKey('ar-sprite')), findsOneWidget);
    expect(find.textContaining('Podejdź bliżej'), findsOneWidget);
    expect(shutterEnabled(tester), isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('after the shutter: back on /map with the saved snackbar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    accel = StreamController();
    mag = StreamController();
    gyro = StreamController();
    gps = StreamController();
    final router = GoRouter(initialLocation: '/map', routes: [
      GoRoute(
          path: '/map',
          builder: (_, _) => const Scaffold(body: Center(child: Text('MAPA')))),
      GoRoute(
        path: '/catch/camera',
        builder: (_, _) => ArCatchScreen(
          spawnId: 's1',
          spawnLat: 52.00027,
          spawnLng: 21.0,
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
        arSensorStreamsProvider.overrideWithValue(
            ArSensorStreams(accel: accel.stream, mag: mag.stream, gyro: gyro.stream)),
        arPositionStreamProvider.overrideWithValue(() => gps.stream),
        catchRepositoryProvider.overrideWithValue(
            CatchRepository(ApiClient(baseUrl: 'http://test', client: never),
                sleep: (_) => Completer<void>().future)),
      ],
      child: MaterialApp.router(
          routerConfig: router, scaffoldMessengerKey: catchMessengerKey),
    ));
    router.push('/catch/camera');
    await tester.pumpAndSettle();
    gps.add(_pos(52.0, 21.0));
    await face(tester, const Vec3(0, -40, -20));
    expect(shutterEnabled(tester), isTrue);

    await tester.tap(find.byIcon(Icons.camera_alt));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.routerDelegate.currentConfiguration.uri.path, '/map');
    expect(find.text('MAPA'), findsOneWidget);
    expect(find.text(photoSavedMessage), findsOneWidget);
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
        arSensorStreamsProvider.overrideWithValue(const ArSensorStreams(
            accel: Stream.empty(), mag: Stream.empty(), gyro: Stream.empty())),
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
