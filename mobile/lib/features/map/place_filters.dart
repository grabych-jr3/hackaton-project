import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/accessibility_fact.dart';
import '../../data/models/place.dart';
import '../../data/repositories/places_repository.dart';
import '../../domain/profile_match.dart';
import '../place/place_providers.dart';

/// Search + filter state shared by the map and its text list.
class PlaceFilters {
  const PlaceFilters({
    this.query = '',
    this.onlyMatching = false,
    this.toilet = false,
    this.benches = false,
  });

  final String query;

  /// Hide places that are "Nie pasuje" for the current profile.
  final bool onlyMatching;
  final bool toilet;
  final bool benches;

  PlaceFilters copyWith({
    String? query,
    bool? onlyMatching,
    bool? toilet,
    bool? benches,
  }) =>
      PlaceFilters(
        query: query ?? this.query,
        onlyMatching: onlyMatching ?? this.onlyMatching,
        toilet: toilet ?? this.toilet,
        benches: benches ?? this.benches,
      );
}

class PlaceFiltersNotifier extends Notifier<PlaceFilters> {
  @override
  PlaceFilters build() => const PlaceFilters();

  void update(PlaceFilters Function(PlaceFilters) change) =>
      state = change(state);
}

final placeFiltersProvider =
    NotifierProvider<PlaceFiltersNotifier, PlaceFilters>(PlaceFiltersNotifier.new);

bool _hasTrue(Place place, Feature feature) =>
    place.factsFor(feature).any((f) => f.flag == true);

final filteredPlacesProvider = Provider<AsyncValue<List<Place>>>((ref) {
  final filters = ref.watch(placeFiltersProvider);
  final query = filters.query.trim().toLowerCase();

  return ref.watch(placesProvider).whenData((places) => places.where((p) {
        if (query.isNotEmpty &&
            !p.name.toLowerCase().contains(query) &&
            !(p.address?.toLowerCase().contains(query) ?? false)) {
          return false;
        }
        if (filters.toilet && !_hasTrue(p, Feature.toilet)) return false;
        if (filters.benches && !_hasTrue(p, Feature.bench)) return false;
        if (filters.onlyMatching &&
            ref.watch(placeMatchProvider(p))?.verdict == Verdict.notSuitable) {
          return false;
        }
        return true;
      }).toList());
});
