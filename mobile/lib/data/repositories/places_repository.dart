import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/place.dart';

/// Source of places. Stage 1: [DemoPlacesRepository];
/// stage 2: an API implementation backed by central-api.
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

final placesRepositoryProvider =
    Provider<PlacesRepository>((ref) => DemoPlacesRepository());

final placesProvider = FutureProvider<List<Place>>(
  (ref) => ref.watch(placesRepositoryProvider).getPlaces(),
);
