import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../data/api/api_client.dart';
import 'game_models.dart';
import 'game_repository.dart';

abstract interface class GameCatalogRepository {
  Future<GameCatalog> load();
}

class DemoGameCatalogRepository implements GameCatalogRepository {
  static const assetPath = 'assets/demo/game.json';

  @override
  Future<GameCatalog> load() async => GameCatalog.parse(await rootBundle.loadString(assetPath));
}

/// `GET /game/catalog`; bundled demo catalog when the server is unreachable.
class ApiGameCatalogRepository implements GameCatalogRepository {
  ApiGameCatalogRepository(this._api, {required this.fallback});

  final ApiClient _api;
  final GameCatalogRepository fallback;

  @override
  Future<GameCatalog> load() async {
    try {
      final json = await _api.get('/game/catalog');
      return GameCatalog.parse(jsonEncode(json));
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      return fallback.load();
    }
  }
}

final gameCatalogRepositoryProvider = Provider<GameCatalogRepository>((ref) => useApi
    ? ApiGameCatalogRepository(ref.watch(apiClientProvider),
        fallback: DemoGameCatalogRepository())
    : DemoGameCatalogRepository());

final gameCatalogProvider = FutureProvider<GameCatalog>(
  (ref) => ref.watch(gameCatalogRepositoryProvider).load(),
);

/// Injectable clock (voucher expiry) and RNG (catches, codes).
final gameClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final gameRandomProvider =
    Provider<Random>((ref) => Random(DateTime.now().millisecondsSinceEpoch));

final gameRepositoryProvider = Provider<GameRepository>((ref) {
  final local = LocalGameRepository(ref.watch(gameRandomProvider));
  return useApi ? ApiGameRepository(ref.watch(apiClientProvider), local: local) : local;
});

class GameNotifier extends AsyncNotifier<GameState> {
  late GameCatalog _catalog;
  late GameRepository _repo;

  @override
  Future<GameState> build() async {
    _catalog = await ref.watch(gameCatalogProvider.future);
    _repo = ref.watch(gameRepositoryProvider);
    return _repo.load(_catalog);
  }

  Future<CatchResult?> submitReport(BarrierReport report) async {
    final current = state.value;
    if (current == null) return null;
    final (next, result) = await _repo.submitReport(_catalog, current, report);
    state = AsyncData(next);
    return result;
  }

  Future<bool> activate(VoucherOffer offer) async {
    final current = state.value;
    if (current == null) return false;
    final next = await _repo.activate(_catalog, current, offer, ref.read(gameClockProvider)());
    if (next == null) return false;
    state = AsyncData(next);
    return true;
  }
}

final gameProvider = AsyncNotifierProvider<GameNotifier, GameState>(GameNotifier.new);
