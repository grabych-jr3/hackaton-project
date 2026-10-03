import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:hackaton_project/app.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('bottom navigation switches tabs', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: KrakowBezBarierApp()));
    await tester.pumpAndSettle();

    expect(find.text('Mapa dostępności — etap 5'), findsOneWidget);

    await tester.tap(find.text('Profil').last);
    await tester.pumpAndSettle();
    expect(find.text('Profil potrzeb — etap 3'), findsOneWidget);
  });
}
