import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/core/theme/app_theme.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/data/repositories/places_repository.dart';
import 'package:hackaton_project/features/catch/catch_screen.dart';
import 'package:hackaton_project/features/collection/collection_screen.dart';
import 'package:hackaton_project/features/game/game_models.dart';
import 'package:hackaton_project/features/game/game_providers.dart';
import 'package:hackaton_project/features/rewards/rewards_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FileCatalogRepository implements GameCatalogRepository {
  @override
  Future<GameCatalog> load() async =>
      GameCatalog.parse(File(DemoGameCatalogRepository.assetPath).readAsStringSync());
}

class _FilePlacesRepository implements PlacesRepository {
  @override
  Future<List<Place>> getPlaces() async => DemoPlacesRepository.parsePlaces(
        File(DemoPlacesRepository.assetPath).readAsStringSync(),
      );
}

DateTime now = DateTime(2026, 10, 3, 12);

Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
  // Decorative looping animations stop when reduce-motion is on.
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      gameCatalogRepositoryProvider.overrideWithValue(_FileCatalogRepository()),
      placesRepositoryProvider.overrideWithValue(_FilePlacesRepository()),
      gameClockProvider.overrideWithValue(() => now),
      gameRandomProvider.overrideWithValue(Random(3)),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: screen),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() => now = DateTime(2026, 10, 3, 12));

  testWidgets('catch: survey catches a creature and adds points', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpScreen(tester, const CatchScreen());

    expect(find.text('DANE PRZYKŁADOWE'), findsWidgets);
    await tester.tap(find.text('Ankieta'));
    await tester.pumpAndSettle();
    expect(find.text('Saldo: 120 pkt'), findsOneWidget);
    final send = find.ancestor(of: find.text('Wyślij zgłoszenie i złap'), matching: find.bySubtype<FilledButton>());
    await tester.scrollUntilVisible(find.text('Wyślij zgłoszenie i złap'), 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);

    await tester.tap(find.text('Brak podjazdu / rampy'));
    await tester.pump();
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(find.textContaining('Złapano:'), findsOneWidget);
    expect(find.textContaining('Zgłoszenie niezweryfikowane'), findsOneWidget);
    await tester.tap(find.text('Odbierz punkty'));
    await tester.pumpAndSettle();
    expect(find.text('Saldo: 120 pkt'), findsNothing);
  });

  testWidgets('collection: locked and caught species, city progress', (tester) async {
    SharedPreferences.setMockInitialValues({
      'game_state': jsonEncode(const GameState(points: 0, caught: {'smok': 2}).toJson()),
    });
    await pumpScreen(tester, const CollectionScreen());

    expect(find.text('Smok'), findsOneWidget);
    expect(find.text('×2'), findsOneWidget);
    expect(find.text('???'), findsNWidgets(7));
    expect(find.text('Odkryto 1/8'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Nowa Huta'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Odkryte miasto'), findsOneWidget);
  });

  testWidgets('rewards: activate voucher, countdown, expiry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpScreen(tester, const RewardsScreen());

    expect(find.text('120 pkt'), findsOneWidget);
    expect(find.text('Bar Na Schodach (demo)'), findsNothing); // unverified
    expect(find.text('Za mało pkt'), findsOneWidget); // 150-pt offer

    await tester.tap(find.text('Aktywuj').first);
    await tester.pumpAndSettle();
    expect(find.text('70 pkt'), findsOneWidget);
    expect(find.textContaining(RegExp(r'KBB-')), findsOneWidget);
    expect(find.text('2:00:00'), findsOneWidget);

    now = now.add(const Duration(minutes: 90));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('30:00'), findsOneWidget);

    now = now.add(const Duration(hours: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Wygasł'), findsOneWidget);
  });
}
