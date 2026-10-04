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

  testWidgets('catch: survey catches a creature without adding points', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpScreen(tester, const CatchScreen());

    expect(find.text('DANE PRZYKŁADOWE'), findsWidgets);
    expect(find.text('Zgłoszenia i ankieta'), findsOneWidget);
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
    expect(find.textContaining('sprzedaj w Kolekcji'), findsOneWidget);
    await tester.tap(find.text('Do kolekcji'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Złapano:'), findsNothing);
  });

  testWidgets('collection: locked and caught species, city progress', (tester) async {
    SharedPreferences.setMockInitialValues({
      'game_state': jsonEncode(const GameState(points: 0, caught: {'smok': 2}).toJson()),
    });
    await pumpScreen(tester, const CollectionScreen());

    expect(find.text('Smok Wawelski'), findsOneWidget);
    expect(find.text('×2'), findsOneWidget);
    expect(find.text('???'), findsNWidgets(9));
    expect(find.text('Odkryto 1/10'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Nowa Huta'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Odkryte miasto'), findsOneWidget);
  });

  testWidgets('collection: sell sheet changes quantity and updates balance', (tester) async {
    SharedPreferences.setMockInitialValues({
      'game_state':
          jsonEncode(const GameState(points: 10, caught: {'sowa': 3}).toJson()),
    });
    await pumpScreen(tester, const CollectionScreen());

    expect(find.text('Saldo: 10 pkt'), findsOneWidget);
    expect(find.text('Sprzedaj · 25 pkt'), findsOneWidget);
    expect(find.bySemanticsLabel('Motylosmok, rzadki, posiadasz 3, wartość 25 punktów'),
        findsOneWidget);

    await tester.tap(find.text('Motylosmok'));
    await tester.pumpAndSettle();
    expect(find.text('Sprzedaj (1) za 25 pkt'), findsOneWidget);
    expect(find.textContaining('Collegium Maius'), findsOneWidget);
    await tester.tap(find.byTooltip('Zwiększ liczbę'));
    await tester.pump();
    expect(find.text('Sprzedaj (2) za 50 pkt'), findsOneWidget);
    await tester.tap(find.byTooltip('Zwiększ liczbę'));
    await tester.pump();
    await tester.tap(find.byTooltip('Zmniejsz liczbę'));
    await tester.pump();

    await tester.tap(find.text('Sprzedaj (2) za 50 pkt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Potwierdź'));
    await tester.pumpAndSettle();

    expect(find.text('Sprzedano 2 × Motylosmok za 50 pkt'), findsOneWidget);
    expect(find.text('Saldo: 60 pkt'), findsOneWidget);
    expect(find.text('×1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collection: locked species are not sellable', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpScreen(tester, const CollectionScreen());
    expect(find.textContaining('Sprzedaj'), findsNothing);
    await tester.tap(find.text('???').first);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('collection: sold-out species shown in grayscale, owned in color', (tester) async {
    SharedPreferences.setMockInitialValues({
      'game_state': jsonEncode(
          const GameState(points: 0, caught: {'smok': 0, 'sowa': 2}).toJson()),
    });
    await pumpScreen(tester, const CollectionScreen());

    expect(find.text('sprzedane'), findsOneWidget);
    final smok = find.ancestor(of: find.text('Smok Wawelski'), matching: find.byType(Column)).first;
    expect(find.descendant(of: smok, matching: find.byType(Grayscale)), findsOneWidget);
    expect(find.descendant(of: smok, matching: find.byType(ColorFiltered)), findsOneWidget);
    final sowa = find.ancestor(of: find.text('Motylosmok'), matching: find.byType(Column)).first;
    expect(find.descendant(of: sowa, matching: find.byType(ColorFiltered)), findsNothing);
    expect(find.byType(Grayscale), findsOneWidget);
    expect(find.bySemanticsLabel('Smok Wawelski, legendarny, sprzedany, brak w kolekcji'), findsOneWidget);

    await tester.tap(find.text('Smok Wawelski'));
    await tester.pumpAndSettle();
    expect(find.text('Nie masz już tego stworka — złap go ponownie'), findsOneWidget);
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Grayscale)),
        findsOneWidget);
    expect(find.textContaining('Sprzedaj ('), findsNothing);
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
