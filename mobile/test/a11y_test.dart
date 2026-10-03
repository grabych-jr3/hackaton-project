import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/core/theme/app_theme.dart';
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

Widget _shellApp() {
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
    ],
  );
  return MaterialApp.router(theme: AppTheme.light(), routerConfig: router);
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('a11y: catch screen (camera + survey)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpScreen(tester, const CatchScreen());
    expect(find.text('AI: 99%'), findsNothing);
    await expectGuidelines(tester);

    await tester.tap(find.text('Ankieta'));
    await tester.pumpAndSettle();
    await expectGuidelines(tester);
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
