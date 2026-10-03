import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/api/api_client.dart';
import 'game_models.dart';

/// Where game state lives: on the device ([LocalGameRepository]) or on the
/// backend ([ApiGameRepository]).
abstract interface class GameRepository {
  Future<GameState> load(GameCatalog catalog);

  Future<(GameState, CatchResult)> submitReport(
      GameCatalog catalog, GameState state, BarrierReport report);

  /// Returns null when not enough points or the offer is not verified.
  Future<GameState?> activate(
      GameCatalog catalog, GameState state, VoucherOffer offer, DateTime now);

  /// Throws [SellException] on invalid count / not enough creatures.
  Future<SellResult> sell(GameCatalog catalog, GameState state, String speciesId, int count);
}

/// Original offline logic: [GameRules] + shared_preferences.
class LocalGameRepository implements GameRepository {
  LocalGameRepository(this.random);

  static const key = 'game_state';

  final Random random;

  @override
  Future<GameState> load(GameCatalog catalog) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return GameState(points: catalog.initialPoints);
    return GameState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> _save(GameState s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(s.toJson()));
  }

  @override
  Future<(GameState, CatchResult)> submitReport(
      GameCatalog catalog, GameState state, BarrierReport report) async {
    final (next, result) = GameRules(catalog, random).submitReport(state, report);
    await _save(next);
    return (next, result);
  }

  @override
  Future<GameState?> activate(
      GameCatalog catalog, GameState state, VoucherOffer offer, DateTime now) async {
    final next = GameRules(catalog, random).activate(state, offer, now);
    if (next != null) await _save(next);
    return next;
  }

  @override
  Future<SellResult> sell(
      GameCatalog catalog, GameState state, String speciesId, int count) async {
    final result = GameRules(catalog, random).sell(state, speciesId, count);
    await _save(result.state);
    return result;
  }
}

/// Server-side game (contract v2). When the server is unreachable it falls
/// back to [local] so the game keeps working offline.
class ApiGameRepository implements GameRepository {
  ApiGameRepository(this._api, {required this.local});

  final ApiClient _api;
  final GameRepository local;

  @override
  Future<GameState> load(GameCatalog catalog) async {
    try {
      return GameState.fromJson(
          await _api.get('/game/state', auth: true) as Map<String, dynamic>);
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      return local.load(catalog);
    }
  }

  @override
  Future<(GameState, CatchResult)> submitReport(
      GameCatalog catalog, GameState state, BarrierReport report) async {
    final Map<String, dynamic> json;
    try {
      json = await _api.post('/game/reports',
          body: {'placeId': report.placeId, 'report': report.toJson()},
          auth: true) as Map<String, dynamic>;
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      return local.submitReport(catalog, state, report);
    }
    final rawSpecies = json['species'];
    final species = rawSpecies is Map<String, dynamic>
        ? (catalog.speciesById(rawSpecies['id'] as String) ??
            Species.fromJson(rawSpecies))
        : catalog.speciesById(rawSpecies as String)!;
    final points = (json['points'] as num?)?.toInt() ?? species.sellValue;
    return (
      GameState.fromJson(json['state'] as Map<String, dynamic>),
      CatchResult(species, points),
    );
  }

  @override
  Future<GameState?> activate(
      GameCatalog catalog, GameState state, VoucherOffer offer, DateTime now) async {
    try {
      final json = await _api.post('/game/vouchers',
          body: {'offerId': offer.id}, auth: true) as Map<String, dynamic>;
      return GameState.fromJson(json['state'] as Map<String, dynamic>);
    } on ApiException catch (e) {
      // 402 INSUFFICIENT_POINTS, 403 OFFER_NOT_VERIFIED.
      if (e.status == 402 || e.status == 403) return null;
      rethrow;
    } catch (_) {
      return local.activate(catalog, state, offer, now);
    }
  }

  @override
  Future<SellResult> sell(
      GameCatalog catalog, GameState state, String speciesId, int count) async {
    final Map<String, dynamic> json;
    try {
      json = await _api.post('/game/sell',
          body: {'speciesId': speciesId, 'count': count}, auth: true) as Map<String, dynamic>;
    } on ApiException catch (e) {
      if (e.status == 400 || e.code == 'INVALID_COUNT') {
        throw const SellException(SellFailure.invalidCount);
      }
      if (e.status == 409 || e.code == 'NOT_ENOUGH_CREATURES') {
        throw const SellException(SellFailure.notEnoughCreatures);
      }
      rethrow;
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      return local.sell(catalog, state, speciesId, count);
    }
    return SellResult(
      GameState.fromJson(json['state'] as Map<String, dynamic>),
      (json['earned'] as num?)?.toInt() ?? 0,
    );
  }
}
