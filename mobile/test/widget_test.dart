import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/app.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/repositories/profile_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const ProviderScope(child: KrakowBezBarierApp()));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('first launch shows onboarding and saves chosen preset',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpApp(tester);

    expect(find.text('Dalej'), findsOneWidget);

    await tester.tap(find.text('Wózek dziecięcy'));
    await tester.pump();
    await tester.tap(find.text('Dalej'));
    await tester.pumpAndSettle();

    expect(find.text('Mapa dostępności — etap 5'), findsOneWidget);
    final saved = await ProfileRepository().load();
    expect(saved?.preset, ProfilePreset.stroller);
  });

  testWidgets('saved profile skips onboarding; tabs switch', (tester) async {
    SharedPreferences.setMockInitialValues({
      'needs_profile': jsonEncode(NeedsProfile.wheelchair.toJson()),
    });
    await pumpApp(tester);

    expect(find.text('Dalej'), findsNothing);

    await tester.tap(find.text('Profil').last);
    await tester.pumpAndSettle();
    expect(find.text('Jak się poruszasz'), findsOneWidget);
    expect(find.text('Maks. liczba schodów'), findsOneWidget);
  });
}
