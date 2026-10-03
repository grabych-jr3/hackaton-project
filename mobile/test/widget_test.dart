import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/app.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/data/repositories/places_repository.dart';
import 'package:hackaton_project/data/repositories/profile_repository.dart';
import 'package:hackaton_project/features/place/place_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      clockProvider.overrideWithValue(() => DateTime(2026, 10, 3)),
      placesRepositoryProvider.overrideWithValue(_FilePlacesRepository()),
    ],
    child: const KrakowBezBarierApp(),
  ));
  await tester.pumpAndSettle();
}

void withProfile(NeedsProfile profile) => SharedPreferences.setMockInitialValues(
      {'needs_profile': jsonEncode(profile.toJson())},
    );

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  filterTests();

  testWidgets('first launch shows onboarding and saves chosen preset',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpApp(tester);

    expect(find.text('Dalej'), findsOneWidget);

    await tester.tap(find.text('Wózek dziecięcy'));
    await tester.pump();
    await tester.tap(find.text('Dalej'));
    await tester.pumpAndSettle();

    expect(find.text('Lista'), findsOneWidget);
    final saved = await ProfileRepository().load();
    expect(saved?.preset, ProfilePreset.stroller);
  });

  testWidgets('saved profile skips onboarding; tabs switch', (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);

    expect(find.text('Dalej'), findsNothing);

    await tester.tap(find.text('Profil').last);
    await tester.pumpAndSettle();
    expect(find.text('Jak się poruszasz'), findsOneWidget);
  });

  testWidgets('place detail shows verdict, sources and demo badge',
      (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);

    await openList(tester);
    await tester.tap(find.text('Zamek Królewski na Wawelu'));
    await tester.pumpAndSettle();

    expect(find.text('Częściowo pasuje'), findsOneWidget);
    expect(find.text('DANE PRZYKŁADOWE'), findsOneWidget);
    expect(find.text('Właściciel obiektu'), findsOneWidget);
  });

  testWidgets('conflicting data shows a warning', (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);

    await openList(tester);
    await tester.tap(find.text('Sukiennice'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dane sprzeczne (schody)'), findsOneWidget);
  });
}

/// Reads the demo asset synchronously; real asset loading never settles
/// inside the fake-async test zone.
class _FilePlacesRepository implements PlacesRepository {
  @override
  Future<List<Place>> getPlaces() async => DemoPlacesRepository.parsePlaces(
        File(DemoPlacesRepository.assetPath).readAsStringSync(),
      );
}

Future<void> openList(WidgetTester tester) async {
  await tester.tap(find.text('Lista'));
  await tester.pumpAndSettle();
}

void filterTests() {
  testWidgets('"Pasujące do mnie" hides unsuitable places', (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);
    await openList(tester);
    expect(find.text('Bazylika Mariacka'), findsOneWidget);

    await tester.tap(find.text('Pasujące do mnie'));
    await tester.pumpAndSettle();
    expect(find.text('Bazylika Mariacka'), findsNothing);
  });

  testWidgets('search filters by name', (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);
    await openList(tester);

    await tester.enterText(find.byType(TextField), 'schindler');
    await tester.pumpAndSettle();
    expect(find.text('Fabryka Emalia Oskara Schindlera'), findsOneWidget);
    expect(find.text('Sukiennice'), findsNothing);
  });
}
