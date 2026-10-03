import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/features/game/game_models.dart';

GameCatalog loadCatalog() =>
    GameCatalog.parse(File('assets/demo/game.json').readAsStringSync());

void main() {
  final catalog = loadCatalog();

  test('catalog parses and filters unverified partners', () {
    expect(catalog.species, hasLength(8));
    expect(catalog.offers.any((o) => !o.verifiedAccess), isTrue);
    expect(catalog.verifiedOffers.every((o) => o.verifiedAccess), isTrue);
  });

  test('points per rarity', () {
    expect(Rarity.common.points, 10);
    expect(Rarity.rare.points, 25);
    expect(Rarity.epic.points, 60);
    expect(Rarity.legendary.points, 150);
  });

  test('severity grows with barriers', () {
    expect(const BarrierReport().severity, 0);
    const heavy = BarrierReport(
      steps: 5,
      curb: CurbRange.high,
      passage: PassageWidth.narrow,
      noRamp: true,
      uneven: true,
      obstacles: true,
    );
    expect(heavy.severity, 10);
    expect(rarityFor(0, Random(1)), anyOf(Rarity.common, Rarity.rare));
    expect(rarityFor(heavy.severity, Random(1)), Rarity.legendary);
  });

  test('submitting a report adds creature but no points', () {
    final rules = GameRules(catalog, Random(42));
    const start = GameState(points: 100);
    final (next, result) = rules.submitReport(
        start, const BarrierReport(steps: 5, curb: CurbRange.high, passage: PassageWidth.narrow, noRamp: true, uneven: true, obstacles: true));
    expect(result.species.rarity, Rarity.legendary);
    expect(result.species.name, 'Smok');
    expect(result.points, 150); // sell value, not awarded
    expect(next.points, 100);
    expect(next.caught['smok'], 1);
  });

  test('catalog species carry sellValue and description; defaults by rarity', () {
    for (final s in catalog.species) {
      expect(s.sellValue, s.rarity.points);
      expect(s.description, isNotEmpty);
    }
    final bare = Species.fromJson(
        {'id': 'x', 'name': 'X', 'emoji': 'x', 'rarity': 'epic'});
    expect(bare.sellValue, 60);
    expect(bare.description, isNull);
  });

  test('sell adds sellValue * count and removes creatures', () {
    final rules = GameRules(catalog, Random(1));
    const start = GameState(points: 5, caught: {'sowa': 3, 'smok': 1});
    final r = rules.sell(start, 'sowa', 2);
    expect(r.earned, 50);
    expect(r.state.points, 55);
    expect(r.state.caught['sowa'], 1);
    final all = rules.sell(r.state, 'smok', 1);
    expect(all.earned, 150);
    expect(all.state.points, 205);
    expect(all.state.caught.containsKey('smok'), isFalse);
  });

  test('sell validation', () {
    final rules = GameRules(catalog, Random(1));
    const st = GameState(points: 0, caught: {'lis': 2});
    Matcher fails(SellFailure f) =>
        throwsA(isA<SellException>().having((e) => e.failure, 'failure', f));
    expect(() => rules.sell(st, 'lis', 0), fails(SellFailure.invalidCount));
    expect(() => rules.sell(st, 'lis', -1), fails(SellFailure.invalidCount));
    expect(() => rules.sell(st, 'lis', 3), fails(SellFailure.notEnoughCreatures));
    expect(() => rules.sell(st, 'sowa', 1), fails(SellFailure.notEnoughCreatures));
    expect(() => rules.sell(st, 'nope', 1), fails(SellFailure.unknownSpecies));
  });

  test('voucher activation deducts points and expires after 2h', () {
    final rules = GameRules(catalog, Random(7));
    final offer = catalog.verifiedOffers.first;
    final t0 = DateTime(2026, 10, 3, 12);
    expect(rules.activate(GameState(points: offer.cost - 1), offer, t0), isNull);

    final s = rules.activate(GameState(points: offer.cost + 5), offer, t0)!;
    expect(s.points, 5);
    final v = s.vouchers.single;
    expect(v.code, matches(RegExp(r'^KBB-[A-Z0-9]{4}$')));
    expect(v.isActive(t0.add(const Duration(minutes: 119))), isTrue);
    expect(formatCountdown(v.remaining(t0.add(const Duration(minutes: 119)))), '01:00');
    expect(v.isActive(t0.add(const Duration(hours: 2))), isFalse);
    expect(v.remaining(t0.add(const Duration(hours: 3))), Duration.zero);
  });

  test('unverified offer cannot be activated', () {
    final rules = GameRules(catalog, Random(7));
    final bad = catalog.offers.firstWhere((o) => !o.verifiedAccess);
    expect(rules.activate(const GameState(points: 1000), bad, DateTime(2026)), isNull);
  });

  test('state round-trips through json', () {
    final s = GameState(points: 3, caught: const {'lis': 2}, vouchers: [
      Voucher(offerId: 'x', code: 'KBB-AAAA', activatedAt: DateTime(2026, 10, 3)),
    ]);
    final r = GameState.fromJson(s.toJson());
    expect(r.points, 3);
    expect(r.caught['lis'], 2);
    expect(r.vouchers.single.code, 'KBB-AAAA');
  });
}
