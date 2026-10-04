import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/app.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/data/repositories/places_repository.dart';
import 'package:hackaton_project/features/map/map_screen.dart';
import 'package:hackaton_project/features/map/place_filters.dart';
import 'package:hackaton_project/features/route/route_start.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FileRepo implements PlacesRepository {
  @override
  Future<List<Place>> getPlaces() async => DemoPlacesRepository.parsePlaces(
        File(DemoPlacesRepository.assetPath).readAsStringSync(),
      );
}

ProviderContainer _container() {
  final c = ProviderContainer(overrides: [
    placesRepositoryProvider.overrideWithValue(_FileRepo()),
  ]);
  addTearDown(c.dispose);
  return c;
}

List<double> _distances(List<Place> places, LatLng from) =>
    [for (final p in places) distanceToPlace(from, p)];

bool _ascending(List<double> d) {
  for (var i = 1; i < d.length; i++) {
    if (d[i] < d[i - 1]) return false;
  }
  return true;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('formatDistance', () {
    expect(formatDistance(350.4), '350 m');
    expect(formatDistance(999), '999 m');
    expect(formatDistance(1200), '1,2 km');
    expect(formatDistance(12345), '12,3 km');
  });

  test('without GPS the list is sorted from Rynek Główny', () async {
    final c = _container();
    await c.read(placesProvider.future);
    final origin = c.read(distanceOriginProvider);
    expect(origin.fromGps, isFalse);
    expect(origin.label, 'Odległość od Rynku Głównego');
    final places = c.read(filteredPlacesProvider).value!;
    expect(places, isNotEmpty);
    expect(_ascending(_distances(places, rynekGlowny)), isTrue);
  });

  test('with a usable GPS fix the list is sorted from the user', () async {
    final c = _container();
    final all = await c.read(placesProvider.future);
    // Stand at the place farthest from the Rynek.
    final far = (all.toList()
          ..sort((a, b) => distanceToPlace(rynekGlowny, a)
              .compareTo(distanceToPlace(rynekGlowny, b))))
        .last;
    final here = LatLng(far.lat, far.lng);
    c.read(userLocationProvider.notifier).set(UserLocation(here, accuracyM: 20));
    final origin = c.read(distanceOriginProvider);
    expect(origin.fromGps, isTrue);
    expect(origin.label, 'Najbliżej Ciebie');
    final places = c.read(filteredPlacesProvider).value!;
    expect(places.first.id, far.id);
    expect(_ascending(_distances(places, here)), isTrue);
    expect(_ascending(_distances(places, rynekGlowny)), isFalse);
  });

  test('inaccurate GPS falls back to Rynek', () {
    final c = _container();
    c.read(userLocationProvider.notifier)
        .set(const UserLocation(LatLng(50.05, 19.94), accuracyM: 2000));
    expect(c.read(distanceOriginProvider).fromGps, isFalse);
  });

  testWidgets('map controls are equal squares; list shows distances',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'needs_profile': jsonEncode(NeedsProfile.wheelchair.toJson())});
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [placesRepositoryProvider.overrideWithValue(_FileRepo())],
      child: const KrakowBezBarierApp(),
    ));
    await tester.pumpAndSettle();

    final layer = find.byTooltip('Widok uliczny');
    final list = find.byTooltip('Lista miejsc');
    final gps = find.byTooltip('Moja lokalizacja');
    for (final f in [layer, list, gps]) {
      expect(tester.getSize(f), const Size(52, 52));
    }
    final r1 = tester.getRect(layer);
    final r2 = tester.getRect(list);
    final r3 = tester.getRect(gps);
    expect(r1.right, r2.right);
    expect(r2.right, r3.right);
    expect(r2.top - r1.bottom, 12);
    expect(r3.top - r2.bottom, 12);
    expect(find.text('Lista'), findsNothing);

    await tester.tap(list);
    await tester.pumpAndSettle();
    expect(find.text('Odległość od Rynku Głównego'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d+(,\d)? (m|km)$')), findsWidgets);
    expect(tester.getSize(find.byTooltip('Pokaż mapę')), const Size(52, 52));
    await tester.tap(find.byTooltip('Pokaż mapę'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Lista miejsc'), findsOneWidget);
  });

  testWidgets('map camera cannot leave Kraków + 20 km', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'needs_profile': jsonEncode(NeedsProfile.wheelchair.toJson())});
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [placesRepositoryProvider.overrideWithValue(_FileRepo())],
      child: const KrakowBezBarierApp(),
    ));
    await tester.pumpAndSettle();
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final ctrl = map.mapController!;
    ctrl.move(const LatLng(52.23, 21.01), 12); // Warsaw
    await tester.pump();
    final c = ctrl.camera.center;
    expect(krakowMapBounds.contains(c), isTrue);
    expect(c.latitude, lessThanOrEqualTo(50.126 + 0.18 + 1e-6));
    expect(c.longitude, lessThanOrEqualTo(20.217 + 0.28 + 1e-6));
    expect(map.options.minZoom, 10);
  });
}
