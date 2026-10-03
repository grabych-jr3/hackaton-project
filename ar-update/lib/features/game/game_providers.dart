import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/catch_repository.dart'; // AR update
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

// AR update: catch repository provider
final catchRepositoryProvider = Provider<CatchRepository>(
  (ref) => CatchRepository(baseUrl: const String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8080')),
);

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

  // ─── AR update: submit photo to backend ───

  /// Sends a photo to the backend for AI analysis.
  /// Returns the catch response, or null if game state is not loaded.
  /// The method polls GET /catches/{id} until the status is no longer PENDING.
  Future<CatchPhotoResponse?> submitPhoto({
    required List<int> jpegBytes,
    required double lat,
    required double lng,
    String? spawnId,
    String? placeId,
  }) async {
    final current = state.value;
    if (current == null) return null;

    final repo = ref.read(catchRepositoryProvider);
    final response = await repo.submitPhoto(
      jpegBytes: jpegBytes,
      lat: lat,
      lng: lng,
      spawnId: spawnId,
      placeId: placeId,
    );

    // If OK, update local game state with points
    if (response.isOk && response.points != null) {
      final rarity = response.rarity != null
          ? Rarity.fromJson(response.rarity!)
          : Rarity.common;
      // Pick a species of matching rarity
      final catalog = await ref.read(gameCatalogProvider.future);
      var pool = catalog.species.where((s) => s.rarity == rarity).toList();
      if (pool.isEmpty) pool = catalog.species;
      final random = ref.read(gameRandomProvider);
      final species = pool[random.nextInt(pool.length)];
      final caught = Map<String, int>.of(current.caught)
        ..update(species.id, (c) => c + 1, ifAbsent: () => 1);
      await _save(current.copyWith(
        points: current.points + (response.points ?? 0),
        caught: caught,
      ));
    }

    return response;
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
