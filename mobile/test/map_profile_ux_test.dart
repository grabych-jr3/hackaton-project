import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/features/map/place_filters.dart';

import 'widget_test.dart' show pumpApp, withProfile;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('search normalization ignores case and diacritics', () {
    expect(normalizeSearch('Kościół Mariacki'), 'kosciol mariacki');
    expect(normalizeSearch('ŻÓŁĆ'), 'zolc');
  });

  testWidgets('typing shows suggestions (diacritics-insensitive), tap selects',
      (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);

    await tester.enterText(find.byType(TextField), 'krolewski');
    await tester.pumpAndSettle();
    expect(find.text('Zamek Królewski na Wawelu'), findsOneWidget);
    expect(find.text('Wawel 5'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'SUKIEN');
    await tester.pumpAndSettle();
    expect(find.text('Sukiennice'), findsOneWidget);
    expect(find.text('Rynek Główny 1/3'), findsOneWidget);

    await tester.tap(find.text('Sukiennice'));
    await tester.pumpAndSettle();
    // Dropdown closed, preview open, name in the field.
    expect(find.text('Rynek Główny 1/3'), findsOneWidget); // preview address
    expect(find.text('Szczegóły dostępności'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Sukiennice');
  });

  testWidgets('empty suggestions state, Esc closes, Enter selects',
      (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'xyzxyz');
    await tester.pumpAndSettle();
    expect(find.text('Brak wyników'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Brak wyników'), findsNothing);

    await tester.enterText(find.byType(TextField), 'schindler');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Szczegóły dostępności'), findsOneWidget);
  });

  testWidgets('suggestions work in list mode too', (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);
    await tester.tap(find.text('Lista'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'kladka');
    await tester.pumpAndSettle();
    // In the dropdown and in the filtered list.
    expect(find.text('Kładka Ojca Bernatka'), findsNWidgets(2));
    expect(find.text('Sukiennice'), findsNothing);
  });

  testWidgets('toilet/bench chips default off; preview amenities follow chips',
      (tester) async {
    withProfile(NeedsProfile.wheelchair);
    await pumpApp(tester);

    final toilet = find.widgetWithText(FilterChip, 'Toaleta');
    final benches = find.widgetWithText(FilterChip, 'Ławki');
    expect(tester.widget<FilterChip>(toilet).selected, isFalse);
    expect(tester.widget<FilterChip>(benches).selected, isFalse);

    await tester.enterText(find.byType(TextField), 'muzeum narodowe');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Muzeum Narodowe — Gmach Główny').first);
    await tester.pumpAndSettle();
    expect(find.text('Szczegóły dostępności'), findsOneWidget);
    expect(find.text('Toaleta dostępna'), findsNothing);
    expect(find.textContaining(RegExp(r'Ławki w pobliżu|o ławkach')),
        findsNothing);

    await tester.tap(toilet);
    await tester.pumpAndSettle();
    expect(find.text('Toaleta dostępna'), findsOneWidget);

    await tester.ensureVisible(benches);
    await tester.pumpAndSettle();
    await tester.tap(benches);
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'Ławki w pobliżu|o ławkach')),
        findsOneWidget);

    await tester.ensureVisible(toilet);
    await tester.pumpAndSettle();
    await tester.tap(toilet);
    await tester.pumpAndSettle();
    expect(find.text('Toaleta dostępna'), findsNothing);
  });

  testWidgets('profile screen has no threshold sliders', (tester) async {
    withProfile(NeedsProfile.wheelchair.copyWith(preset: ProfilePreset.custom));
    await pumpApp(tester);
    await tester.tap(find.text('Profil').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('szerokość'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Własne'), findsNothing);
    expect(find.text('Inwalidzki'), findsOneWidget);
  });

  test('width is a constant 75 cm; old stored values are ignored', () {
    expect(NeedsProfile.wheelchair.minWidthCm, 75);
    expect(NeedsProfile.stroller.minWidthCm, 75);
    final json = NeedsProfile.stroller.toJson();
    expect(json['minWidthCm'], 75);
    final old = {...json, 'minWidthCm': 60};
    expect(NeedsProfile.fromJson(old).minWidthCm, 75);
  });
}
