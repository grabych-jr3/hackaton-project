import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game_models.dart';

abstract interface class GameCatalogRepository {
  Future<GameCatalog> load();
}

class DemoGameCatalogRepository implements GameCatalogRepository {
  static const assetPath = 'assets/demo/game.json';

  @override
  Future<GameCatalog> load() async => GameCatalog.parse(await rootBundle.loadString(assetPath));
}

final gameCatalogRepositoryProvider =
    Provider<GameCatalogRepository>((ref) => DemoGameCatalogRepository());

final gameCatalogProvider = FutureProvider<GameCatalog>(
  (ref) => ref.watch(gameCatalogRepositoryProvider).load(),
);

/// Injectable clock (voucher expiry) and RNG (catches, codes).
final gameClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final gameRandomProvider =
    Provider<Random>((ref) => Random(DateTime.now().millisecondsSinceEpoch));

class GameNotifier extends AsyncNotifier<GameState> {
  static const _key = 'game_state';

  late GameRules _rules;

  @override
  Future<GameState> build() async {
    final catalog = await ref.watch(gameCatalogProvider.future);
    _rules = GameRules(catalog, ref.watch(gameRandomProvider));
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return GameState(points: catalog.initialPoints);
    return GameState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> _save(GameState s) async {
    state = AsyncData(s);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(s.toJson()));
  }

  Future<CatchResult?> submitReport(BarrierReport report) async {
    final current = state.value;
    if (current == null) return null;
    final (next, result) = _rules.submitReport(current, report);
    await _save(next);
    return result;
  }

  Future<bool> activate(VoucherOffer offer) async {
    final current = state.value;
    if (current == null) return false;
    final next = _rules.activate(current, offer, ref.read(gameClockProvider)());
    if (next == null) return false;
    await _save(next);
    return true;
  }
}

final gameProvider = AsyncNotifierProvider<GameNotifier, GameState>(GameNotifier.new);
