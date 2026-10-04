import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../api/api_client.dart';
import '../models/accessibility_fact.dart';
import '../models/place.dart';

/// Source of places: [DemoPlacesRepository] (bundled JSON) or
/// [ApiPlacesRepository] (central API, falls back to demo when offline).
abstract interface class PlacesRepository {
  Future<List<Place>> getPlaces();
}

class DemoPlacesRepository implements PlacesRepository {
  DemoPlacesRepository({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static const assetPath = 'assets/demo/places.json';

  final AssetBundle _bundle;

  @override
  Future<List<Place>> getPlaces() async {
    final raw = await _bundle.loadString(assetPath);
    return parsePlaces(raw);
  }

  static List<Place> parsePlaces(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final isDemo = json['isDemo'] as bool? ?? true;
    return (json['places'] as List<dynamic>)
        .map((p) => Place.fromJson(p as Map<String, dynamic>, isDemo: isDemo))
        .toList();
  }
}

Place placeFromApi(Map<String, dynamic> j) =>
    Place.fromJson(j, isDemo: j['isDemo'] as bool? ?? false);

/// Places from the backend. On network failure returns [fallback] data and
/// reports `true` through [onOffline] (`false` once the server answers).
class ApiPlacesRepository implements PlacesRepository {
  ApiPlacesRepository(this._api, {required this.fallback, this.onOffline});

  final ApiClient _api;
  final PlacesRepository fallback;
  final void Function(bool offline)? onOffline;

  @override
  Future<List<Place>> getPlaces() async {
    try {
      final json = await _api.get('/places') as Map<String, dynamic>;
      onOffline?.call(false);
      return (json['places'] as List<dynamic>)
          .map((p) => placeFromApi(p as Map<String, dynamic>))
          .toList();
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      onOffline?.call(true);
      return fallback.getPlaces();
    }
  }

  Future<Place> getPlace(String id) async =>
      placeFromApi(await _api.get('/places/$id') as Map<String, dynamic>);

  Future<AccessibilityFact> addFact(String placeId, Feature feature, Object value) async =>
      AccessibilityFact.fromJson(await _api.post('/places/$placeId/facts',
          body: {'feature': feature.name, 'value': value}, auth: true) as Map<String, dynamic>);

  /// Throws [ApiException] 409 when this device already voted.
  Future<AccessibilityFact> vote(String factId, {required bool confirm}) async =>
      AccessibilityFact.fromJson(await _api.post(
              '/facts/$factId/${confirm ? 'confirm' : 'dispute'}',
              auth: true) as Map<String, dynamic>);
}

final placesRepositoryProvider = Provider<PlacesRepository>((ref) {
  if (!useApi) return DemoPlacesRepository();
  return ApiPlacesRepository(
    ref.watch(apiClientProvider),
    fallback: DemoPlacesRepository(),
    onOffline: (v) => ref.read(serverUnavailableProvider.notifier).state = v,
  );
});

final placesProvider = FutureProvider<List<Place>>(
  (ref) => ref.watch(placesRepositoryProvider).getPlaces(),
);
