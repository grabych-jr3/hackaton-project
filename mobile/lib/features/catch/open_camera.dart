import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/catch_repository.dart';
import '../spawns/spawn_providers.dart';
import 'ar_catch_screen.dart' show CatchExit;

/// Shown when the camera is requested without a backend (no AI analysis).
const demoCameraMessage =
    'Tryb demo: analiza zdjęć AI wymaga serwera — zgłoś barierę w ankiecie.';

/// `/catch/camera` location with the nearest spawn (≤ 50 m) as query params.
String catchCameraLocation(WidgetRef ref, {String? placeId}) {
  final spawn = ref.read(nearestSpawnProvider(50));
  final params = <String, String>{
    'placeId': ?placeId,
    if (spawn != null) ...{
      'spawnId': spawn.id,
      'emoji': spawn.emoji,
      'name': spawn.name,
      'spawnLat': '${spawn.lat}',
      'spawnLng': '${spawn.lng}',
    },
  };
  final query = params.isEmpty ? '' : '?${Uri(queryParameters: params).query}';
  return '/catch/camera$query';
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// Opens the fullscreen AR camera (pushed, so its X returns to the caller).
/// Demo mode (no API): the AI needs the server, so the survey opens instead.
Future<void> openCatchCamera(BuildContext context, WidgetRef ref,
    {String? placeId}) async {
  final router = GoRouter.of(context);
  if (ref.read(catchRepositoryProvider) == null) {
    router.go('/catch');
    _snack(context, demoCameraMessage);
    return;
  }
  final exit =
      await router.push<CatchExit>(catchCameraLocation(ref, placeId: placeId));
  if (!context.mounted) return;
  switch (exit) {
    case CatchExit.survey:
      router.go('/catch');
      _snack(context, 'Kamera lub AI niedostępne — zgłoś barierę w ankiecie.');
    case CatchExit.collection:
      router.go('/collection');
    case null:
      break;
  }
}
