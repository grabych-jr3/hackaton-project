import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/data/models/accessibility_fact.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/data/repositories/places_repository.dart';
import 'package:hackaton_project/domain/profile_match.dart';

void main() {
  final now = DateTime(2026, 10, 3);
  late Map<String, Place> places;

  setUpAll(() {
    final raw = File(DemoPlacesRepository.assetPath).readAsStringSync();
    places = {for (final p in DemoPlacesRepository.parsePlaces(raw)) p.id: p};
  });

  Verdict verdict(String id, NeedsProfile profile) =>
      matchPlace(places[id]!, profile, now).verdict;

  group('wheelchair profile', () {
    const p = NeedsProfile.wheelchair;

    test('Pasuje: no steps, wide door, toilet', () {
      expect(verdict('mnk-gmach', p), Verdict.suitable);
    });

    test('Częściowo: incline above threshold is not critical', () {
      final match = matchPlace(places['wawel']!, p, now);
      expect(match.verdict, Verdict.partial);
      expect(match.problems.single.feature, Feature.incline);
    });

    test('Nie pasuje: steps without ramp', () {
      expect(verdict('mariacki', p), Verdict.notSuitable);
    });

    test('Za mało danych: place without facts is never suitable', () {
      expect(verdict('nowa-prowincja', p), Verdict.insufficientData);
    });

    test('outdated facts are not used to decide', () {
      expect(verdict('barbakan', p), Verdict.insufficientData);
    });

    test('elevator makes steps passable', () {
      final steps = matchPlace(places['sukiennice']!, p, now)
          .checks
          .firstWhere((c) => c.feature == Feature.steps);
      expect(steps.status, CheckStatus.pass);
      expect(steps.note, 'Schody, ale jest winda');
    });
  });

  test('stroller profile accepts 2 steps', () {
    expect(verdict('mariacki', NeedsProfile.stroller), Verdict.suitable);
  });

  test('AI range value is compared by its upper bound', () {
    final kerb = matchPlace(places['massolit']!, NeedsProfile.wheelchair, now)
        .checks
        .firstWhere((c) => c.feature == Feature.kerbHeight);
    expect(kerb.status, CheckStatus.borderline);
  });
}
