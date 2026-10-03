import 'dart:convert';
import 'dart:math';

/// Creature rarity (TZ 7). Points: common 10, rare 25, epic 60, legendary 150.
enum Rarity {
  common(10, 'zwykły'),
  rare(25, 'rzadki'),
  epic(60, 'epicki'),
  legendary(150, 'legendarny');

  const Rarity(this.points, this.label);

  final int points;
  final String label;

  static Rarity fromJson(String v) => Rarity.values.firstWhere((r) => r.name == v);
}

class Species {
  const Species({required this.id, required this.name, required this.emoji, required this.rarity});

  final String id;
  final String name;
  final String emoji;
  final Rarity rarity;

  factory Species.fromJson(Map<String, dynamic> j) => Species(
        id: j['id'] as String,
        name: j['name'] as String,
        emoji: j['emoji'] as String,
        rarity: Rarity.fromJson(j['rarity'] as String),
      );
}

class VoucherOffer {
  const VoucherOffer({
    required this.id,
    required this.partner,
    required this.discount,
    required this.cost,
    required this.verifiedAccess,
    this.placeId,
  });

  final String id;
  final String partner;
  final String? placeId;
  final String discount;
  final int cost;
  final bool verifiedAccess;

  factory VoucherOffer.fromJson(Map<String, dynamic> j) => VoucherOffer(
        id: j['id'] as String,
        partner: j['partner'] as String,
        placeId: j['placeId'] as String?,
        discount: j['discount'] as String,
        cost: j['cost'] as int,
        verifiedAccess: j['verifiedAccess'] as bool? ?? false,
      );
}

class DistrictProgress {
  const DistrictProgress(this.name, this.percent);
  final String name;
  final int percent;
}

class GameCatalog {
  const GameCatalog({
    required this.initialPoints,
    required this.species,
    required this.offers,
    required this.districts,
    this.isDemo = true,
  });

  final int initialPoints;
  final List<Species> species;
  final List<VoucherOffer> offers;
  final List<DistrictProgress> districts;
  final bool isDemo;

  /// Only partners with verified accessibility may offer vouchers.
  List<VoucherOffer> get verifiedOffers => offers.where((o) => o.verifiedAccess).toList();

  Species? speciesById(String id) => species.where((s) => s.id == id).firstOrNull;

  factory GameCatalog.parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return GameCatalog(
      initialPoints: j['initialPoints'] as int? ?? 0,
      isDemo: j['isDemo'] as bool? ?? true,
      species: (j['species'] as List)
          .map((e) => Species.fromJson(e as Map<String, dynamic>))
          .toList(),
      offers: (j['offers'] as List)
          .map((e) => VoucherOffer.fromJson(e as Map<String, dynamic>))
          .toList(),
      districts: (j['districts'] as List? ?? [])
          .map((e) => DistrictProgress(
              (e as Map<String, dynamic>)['name'] as String, e['percent'] as int))
          .toList(),
    );
  }
}

enum CurbRange { none, low, mid, high }

enum PassageWidth { none, wide, medium, narrow }

/// Manual barrier survey (ankieta) — stands in for the camera until stage 9.
class BarrierReport {
  const BarrierReport({
    this.placeId,
    this.steps = 0,
    this.curb = CurbRange.none,
    this.passage = PassageWidth.none,
    this.noRamp = false,
    this.uneven = false,
    this.obstacles = false,
  });

  final String? placeId;
  final int steps;
  final CurbRange curb;
  final PassageWidth passage;
  final bool noRamp;
  final bool uneven;
  final bool obstacles;

  /// Higher = more/worse barriers reported.
  int get severity {
    var s = 0;
    if (steps > 0) s += steps >= 3 ? 2 : 1;
    s += switch (curb) {
      CurbRange.none || CurbRange.low => 0,
      CurbRange.mid => 1,
      CurbRange.high => 2,
    };
    s += switch (passage) {
      PassageWidth.none || PassageWidth.wide => 0,
      PassageWidth.medium => 1,
      PassageWidth.narrow => 2,
    };
    if (noRamp) s += 2;
    if (uneven) s += 1;
    if (obstacles) s += 1;
    return s;
  }

  /// API payload (`POST /game/reports` → `report`): Dart field names, enums by name.
  Map<String, dynamic> toJson() => {
        'placeId': placeId,
        'steps': steps,
        'curb': curb.name,
        'passage': passage.name,
        'noRamp': noRamp,
        'uneven': uneven,
        'obstacles': obstacles,
      };

  bool get isEmpty =>
      steps == 0 &&
      curb == CurbRange.none &&
      passage == PassageWidth.none &&
      !noRamp &&
      !uneven &&
      !obstacles;
}

/// Rarity grows with severity; the roll adds a bit of luck (0..3).
Rarity rarityFor(int severity, Random random) {
  final score = severity + random.nextInt(4);
  if (score >= 10) return Rarity.legendary;
  if (score >= 6) return Rarity.epic;
  if (score >= 3) return Rarity.rare;
  return Rarity.common;
}

class Voucher {
  const Voucher({
    required this.offerId,
    required this.code,
    required this.activatedAt,
  });

  static const validity = Duration(hours: 2);

  final String offerId;
  final String code;
  final DateTime activatedAt;

  DateTime get expiresAt => activatedAt.add(validity);
  bool isActive(DateTime now) => now.isBefore(expiresAt);
  Duration remaining(DateTime now) =>
      isActive(now) ? expiresAt.difference(now) : Duration.zero;

  Map<String, dynamic> toJson() =>
      {'offerId': offerId, 'code': code, 'activatedAt': activatedAt.toIso8601String()};

  factory Voucher.fromJson(Map<String, dynamic> j) => Voucher(
        offerId: j['offerId'] as String,
        code: j['code'] as String,
        activatedAt: DateTime.parse(j['activatedAt'] as String),
      );
}

String voucherCode(Random random) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return 'KBB-${List.generate(4, (_) => chars[random.nextInt(chars.length)]).join()}';
}

String formatCountdown(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mmss = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return h > 0 ? '$h:$mmss' : mmss;
}

class GameState {
  const GameState({required this.points, this.caught = const {}, this.vouchers = const []});

  final int points;

  /// speciesId -> count.
  final Map<String, int> caught;
  final List<Voucher> vouchers;

  int get totalCaught => caught.values.fold(0, (a, b) => a + b);

  GameState copyWith({int? points, Map<String, int>? caught, List<Voucher>? vouchers}) =>
      GameState(
        points: points ?? this.points,
        caught: caught ?? this.caught,
        vouchers: vouchers ?? this.vouchers,
      );

  Map<String, dynamic> toJson() => {
        'points': points,
        'caught': caught,
        'vouchers': vouchers.map((v) => v.toJson()).toList(),
      };

  factory GameState.fromJson(Map<String, dynamic> j) => GameState(
        points: j['points'] as int,
        caught: (j['caught'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as int)),
        vouchers: (j['vouchers'] as List? ?? [])
            .map((e) => Voucher.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class CatchResult {
  const CatchResult(this.species, this.points);
  final Species species;
  final int points;
}

/// Pure game rules, independent of Riverpod and storage.
class GameRules {
  GameRules(this.catalog, this.random);

  final GameCatalog catalog;
  final Random random;

  (GameState, CatchResult) submitReport(GameState state, BarrierReport report) {
    final rarity = rarityFor(report.severity, random);
    var pool = catalog.species.where((s) => s.rarity == rarity).toList();
    if (pool.isEmpty) pool = catalog.species;
    final species = pool[random.nextInt(pool.length)];
    final caught = Map<String, int>.of(state.caught)
      ..update(species.id, (c) => c + 1, ifAbsent: () => 1);
    final pts = species.rarity.points;
    return (
      state.copyWith(points: state.points + pts, caught: caught),
      CatchResult(species, pts),
    );
  }

  /// Returns null when not enough points or offer unverified.
  GameState? activate(GameState state, VoucherOffer offer, DateTime now) {
    if (!offer.verifiedAccess || state.points < offer.cost) return null;
    final v = Voucher(offerId: offer.id, code: voucherCode(random), activatedAt: now);
    return state.copyWith(points: state.points - offer.cost, vouchers: [v, ...state.vouchers]);
  }
}
