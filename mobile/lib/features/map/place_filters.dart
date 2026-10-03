import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/models/accessibility_fact.dart';
import '../../data/models/place.dart';
import '../../data/repositories/places_repository.dart';
import '../../domain/profile_match.dart';
import '../place/place_providers.dart';
import '../route/route_start.dart';

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

const _diacritics = {
  'ą': 'a', 'ć': 'c', 'ę': 'e', 'ł': 'l', 'ń': 'n', 'ó': 'o', 'ś': 's',
  'ź': 'z', 'ż': 'z', 'á': 'a', 'à': 'a', 'ä': 'a', 'é': 'e', 'è': 'e',
  'ë': 'e', 'í': 'i', 'ö': 'o', 'ü': 'u', 'ú': 'u', 'č': 'c', 'š': 's',
  'ž': 'z',
};

/// Lower-cases and strips (mostly Polish) diacritics: "Kościół" -> "kosciol".
String normalizeSearch(String s) {
  final out = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    out.write(_diacritics[ch] ?? ch);
  }
  return out.toString();
}

/// Case- and diacritics-insensitive match on name or address.
bool placeMatchesQuery(Place p, String query) {
  final q = normalizeSearch(query.trim());
  if (q.isEmpty) return true;
  return normalizeSearch(p.name).contains(q) ||
      (p.address != null && normalizeSearch(p.address!).contains(q));
}

/// Search dropdown: at most 6 places matching the current query.
final searchSuggestionsProvider = Provider<List<Place>>((ref) {
  final query = ref.watch(placeFiltersProvider.select((f) => f.query));
  if (query.trim().isEmpty) return const [];
  return (ref.watch(filteredPlacesProvider).value ?? const <Place>[])
      .take(6)
      .toList();
});

final filteredPlacesProvider = Provider<AsyncValue<List<Place>>>((ref) {
  final filters = ref.watch(placeFiltersProvider);
  final origin = ref.watch(distanceOriginProvider);

  return ref.watch(placesProvider).whenData((places) => places.where((p) {
        if (!placeMatchesQuery(p, filters.query)) return false;
        if (filters.toilet && !_hasTrue(p, Feature.toilet)) return false;
        if (filters.benches && !_hasTrue(p, Feature.bench)) return false;
        if (filters.onlyMatching &&
            ref.watch(placeMatchProvider(p))?.verdict == Verdict.notSuitable) {
          return false;
        }
        return true;
      }).toList()
        ..sort((a, b) => _dist(origin.point, a).compareTo(_dist(origin.point, b))));
});

/// Point that list distances are measured from: the user's usable GPS fix,
/// otherwise Rynek Główny.
class DistanceOrigin {
  const DistanceOrigin(this.point, {required this.fromGps});
  final LatLng point;
  final bool fromGps;

  /// List header.
  String get label => fromGps ? 'Najbliżej Ciebie' : 'Odległość od Rynku Głównego';
}

final distanceOriginProvider = Provider<DistanceOrigin>((ref) {
  final gps = ref.watch(userLocationProvider);
  if (gps != null && gps.isUsable) {
    return DistanceOrigin(gps.point, fromGps: true);
  }
  return const DistanceOrigin(rynekGlowny, fromGps: false);
});

const _distance = Distance();

double _dist(LatLng from, Place p) => _distance(from, LatLng(p.lat, p.lng));

/// Meters from [from] to [place].
double distanceToPlace(LatLng from, Place place) => _dist(from, place);

/// "350 m" / "1,2 km" (Polish decimal comma).
String formatDistance(double m) => m >= 1000
    ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
    : '${m.round()} m';
