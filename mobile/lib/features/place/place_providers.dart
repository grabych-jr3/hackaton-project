import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/needs_profile.dart';
import '../../data/models/place.dart';
import '../../data/repositories/places_repository.dart';
import '../../data/repositories/profile_repository.dart';
import '../../domain/profile_match.dart';

/// Current time; overridden in tests.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final placeByIdProvider = Provider.family<AsyncValue<Place?>, String>((ref, id) {
  return ref.watch(placesProvider).whenData(
        (places) => places.where((p) => p.id == id).firstOrNull,
      );
});

final placeMatchProvider = Provider.family<PlaceMatch?, Place>((ref, place) {
  final NeedsProfile? profile = ref.watch(profileProvider).value;
  if (profile == null) return null;
  return matchPlace(place, profile, ref.watch(clockProvider)());
});
