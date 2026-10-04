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

const _lat0 = 52.0, _lng0 = 21.0;

/// Latitude [m] metres north of the user.
double _north(double m) => geoOffset(_lat0, _lng0, 0, m).lat;

void main() {
  late StreamController<ArHeading> heading;
  late StreamController<double> pitch;
  late StreamController<Position> gps;

  List<Override> streamOverrides() {
    heading = StreamController();
    pitch = StreamController();
    gps = StreamController();
    return [
      arHeadingProvider.overrideWithValue(heading.stream),
      arPitchProvider.overrideWithValue(pitch.stream),
      arPositionStreamProvider.overrideWithValue(() => gps.stream),
    ];
  }

  void setUpView(WidgetTester tester) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pump(WidgetTester tester, {required double spawnLat}) async {
    setUpView(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: streamOverrides(),
      child: MaterialApp(
        home: ArCatchScreen(
          spawnId: 's1',
          speciesEmoji: '🐉',
          spawnLat: spawnLat,
          spawnLng: _lng0,
          cameraEnabled: false,
        ),
      ),
    ));
  }

  /// Camera pointing at [deg] (reliable compass), held upright-ish.
  Future<void> face(WidgetTester tester, double deg, {bool reliable = true}) async {
    for (var i = 0; i < 40; i++) {
      heading.add(ArHeading(degrees: deg, accuracyDeg: 5, reliable: reliable));
      pitch.add(-5 * 3.141592653589793 / 180);
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

  testWidgets('creature 12 m north: visible & centred facing north, arrow facing east',
      (tester) async {
    await pump(tester, spawnLat: _north(12));
    gps.add(_pos(_lat0, _lng0));
    await face(tester, 0);

    expect(find.byKey(const ValueKey('ar-sprite')), findsOneWidget);
    expect(find.text('Stworek przed Tobą — zrób zdjęcie'), findsOneWidget);
    expect(shutterEnabled(tester), isTrue);
    final c = tester.getCenter(find.byKey(const ValueKey('ar-sprite')));
    expect(c.dx, closeTo(200, 2));
    expect(c.dy, closeTo(400, 4));

    await face(tester, 90);
    expect(find.byKey(const ValueKey('ar-sprite')), findsNothing);
    expect(find.byKey(const ValueKey('ar-arrow-left')), findsOneWidget);
    expect(find.text('Obróć się w lewo — stworek 12 m stąd'), findsOneWidget);
    expect(shutterEnabled(tester), isFalse);

    await tester.tap(find.byTooltip('Dane diagnostyczne'));
    await tester.pump();
    expect(find.byKey(const ValueKey('ar-debug')), findsOneWidget);
    expect(find.textContaining('dystans: 12.'), findsOneWidget);
    expect(find.textContaining('GPS surowy: ±4.0 m'), findsOneWidget);
    expect(find.textContaining('GPS wygładzony: ±4.0 m'), findsOneWidget);
    expect(find.textContaining('namiar wiarygodny: tak'), findsOneWidget);

    await face(tester, 90, reliable: false);
    expect(find.text('Skalibruj kompas: porusz telefonem ósemką'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('30 m away: sprite hidden, radar + "Podejdź bliżej" hint', (tester) async {
    await pump(tester, spawnLat: _north(30));
    gps.add(_pos(_lat0, _lng0));
    await face(tester, 0);
    expect(find.byKey(const ValueKey('ar-sprite')), findsNothing);
    expect(find.byKey(const ValueKey('ar-radar')), findsOneWidget);
    expect(find.text('Podejdź bliżej — stworek 30 m stąd, kierunek ↑'), findsOneWidget);
    expect(shutterEnabled(tester), isFalse);
    await finish(tester);
  });

  testWidgets('very close with poor GPS: near-field mode, centred-ish, catchable',
      (tester) async {
    await pump(tester, spawnLat: _north(3));
    gps.add(_pos(_lat0, _lng0, accuracy: 10));
    await face(tester, 60); // bearing says it is 60° to the left
    expect(find.text('Jesteś bardzo blisko — rozejrzyj się'), findsOneWidget);
    final c = tester.getCenter(find.byKey(const ValueKey('ar-sprite')));
    // 60° × (3 m / 10 m) = 18° → well inside the view, not at the edge.
    expect(c.dx, closeTo(200 - 18 / 30 * 200, 3));
    expect(shutterEnabled(tester), isTrue);
    await finish(tester);
  });

  testWidgets('GPS outlier is ignored (sprite does not jump)', (tester) async {
    await pump(tester, spawnLat: _north(12));
    gps.add(_pos(_lat0, _lng0));
    await face(tester, 0);
    gps.add(_pos(geoOffset(_lat0, _lng0, 90, 40).lat,
        geoOffset(_lat0, _lng0, 90, 40).lng)); // 40 m east, same second
    await tester.pump();
    await face(tester, 0);
    final c = tester.getCenter(find.byKey(const ValueKey('ar-sprite')));
    expect(c.dx, closeTo(200, 2));
    await finish(tester);
  });

  testWidgets('after the shutter: back on /map with the saved snackbar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    setUpView(tester);
    final router = GoRouter(initialLocation: '/map', routes: [
      GoRoute(
          path: '/map',
          builder: (_, _) => const Scaffold(body: Center(child: Text('MAPA')))),
      GoRoute(
        path: '/catch/camera',
        builder: (_, _) => ArCatchScreen(
          spawnId: 's1',
          spawnLat: _north(12),
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
        arHeadingProvider.overrideWithValue(const Stream.empty()),
        arPitchProvider.overrideWithValue(const Stream.empty()),
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
