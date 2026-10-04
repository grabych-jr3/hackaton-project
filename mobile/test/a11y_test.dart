import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hackaton_project/core/theme/app_theme.dart';
import 'package:hackaton_project/data/api/api_client.dart';
import 'package:hackaton_project/data/repositories/catch_repository.dart';
import 'package:hackaton_project/features/catch/catch_screen.dart';
import 'package:hackaton_project/features/rewards/rewards_screen.dart';
import 'package:hackaton_project/features/shell/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game/game_screens_test.dart' show pumpScreen;

Future<void> expectGuidelines(WidgetTester tester) async {
  final handle = tester.ensureSemantics();
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  handle.dispose();
}

Widget _shellApp({bool api = false}) {
  StatefulShellBranch branch(String path) => StatefulShellBranch(routes: [
        GoRoute(
          path: path,
          builder: (_, _) => Scaffold(body: Center(child: Text(path))),
        ),
      ]);
  final router = GoRouter(
    initialLocation: '/map',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(navigationShell: shell),
        branches: [
          branch('/map'),
          branch('/rewards'),
          branch('/catch'),
          branch('/collection'),
          branch('/profile'),
        ],
      ),
      GoRoute(
        path: '/catch/camera',
        builder: (_, _) => const Scaffold(body: Text('camera')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      catchRepositoryProvider.overrideWithValue(api
          ? CatchRepository(ApiClient(
              baseUrl: 'http://test',
              client: MockClient((_) async => http.Response('{}', 404))))
          : null),
    ],
    child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('a11y: survey & Zgłoszenia screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpScreen(tester, const CatchScreen());
    expect(find.text('AI: 99%'), findsNothing);
    await expectGuidelines(tester);
  });

  Future<void> pumpShell(WidgetTester tester, {bool api = false}) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shellApp(api: api));
    await tester.pumpAndSettle();
  }

  testWidgets('Złap: tap opens the camera directly, X returns', (tester) async {
    await pumpShell(tester, api: true);
    await tester.tap(find.bySemanticsLabel('Złap'));
    await tester.pumpAndSettle();
    expect(find.text('camera'), findsOneWidget);
    Navigator.of(tester.element(find.text('camera'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('/map'), findsOneWidget);
  });

  testWidgets('Złap: Enter key opens the camera', (tester) async {
    await pumpShell(tester, api: true);
    final focus = Focus.of(tester.element(find.byIcon(Icons.camera_alt_rounded)));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('camera'), findsOneWidget);
  });

  testWidgets('Złap: long-press opens survey & Zgłoszenia', (tester) async {
    await pumpShell(tester, api: true);
    final handle = tester.ensureSemantics();
    expect(
        tester.getSemantics(find.bySemanticsLabel('Złap')).hint,
        'Przytrzymaj, aby otworzyć ankietę i zgłoszenia');
    handle.dispose();
    await tester.longPress(find.bySemanticsLabel('Złap'));
    await tester.pumpAndSettle();
    expect(find.text('/catch'), findsOneWidget);
    expect(find.text('camera'), findsNothing);
  });

  testWidgets('Złap: demo mode tap opens the survey with a notice', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.bySemanticsLabel('Złap'));
    await tester.pumpAndSettle();
    expect(find.text('/catch'), findsOneWidget);
    expect(find.text(demoCameraMessage), findsOneWidget);
  });

  testWidgets('a11y: rewards screen with voucher label', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpScreen(tester, const RewardsScreen());
    await expectGuidelines(tester);

    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp(r'^Aktywuj voucher .+ za \d+ punktów$')), findsWidgets);
    await tester.tap(find.text('Aktywuj').first);
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp(r'^Voucher .+, kod KBB-.+, pozostało 2 godziny$')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a11y: home shell tabs are labelled, focusable, keyboard-activated', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shellApp());
    await tester.pumpAndSettle();

    final handle = tester.ensureSemantics();
    for (final l in ['Mapa', 'Nagrody', 'Złap', 'Kolekcja', 'Profil']) {
      expect(find.bySemanticsLabel(l), findsOneWidget, reason: l);
    }
    await expectGuidelines(tester);

    // Keyboard: the "Nagrody" tab owns a real FocusNode (InkWell); focus it and press Enter.
    final tabFocus = Focus.of(tester.element(find.text('Nagrody')));
    expect(tabFocus.canRequestFocus, isTrue);
    tabFocus.requestFocus();
    await tester.pump();
    expect(tabFocus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('/rewards'), findsOneWidget);
    final node = tester.getSemantics(find.bySemanticsLabel('Nagrody'));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isSelected, Tristate.isTrue);
    handle.dispose();
  });
}
