import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../data/api/api_client.dart';
import '../../data/models/needs_profile.dart';
import '../../data/models/place.dart';
import '../../data/repositories/profile_repository.dart';

/// OpenRouteService key, passed with
/// `--dart-define-from-file=config/secrets.json` (never committed).
const orsApiKey = String.fromEnvironment('ORS_API_KEY');

/// Default start when GPS is off or far away: Rynek Główny.
const rynekGlowny = LatLng(50.0617, 19.9373);

class RouteSegment {
  const RouteSegment({
    required this.instruction,
    required this.distanceM,
    this.warning,
  });

  final String instruction;
  final double distanceM;

  /// Accessibility note for this step, e.g. "kostka brukowa", "rampa".
  final String? warning;
}

class PlannedRoute {
  const PlannedRoute({
    required this.destination,
    required this.startLabel,
    required this.points,
    required this.distanceM,
    required this.durationS,
    required this.segments,
    required this.isDemo,
    this.fallbackReason,
  });

  final Place destination;
  final String startLabel;
  final List<LatLng> points;
  final double distanceM;
  final double durationS;
  final List<RouteSegment> segments;

  /// true = sample route (no key / no network); must be labelled in UI.
  final bool isDemo;
  final String? fallbackReason;

  String get sourceLabel => isDemo
      ? 'Trasa przykładowa'
      : 'OpenRouteService · profil wózka';
}

String formatDistance(double m) =>
    m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

String formatDuration(double s) {
  final min = (s / 60).round();
  return min < 60 ? '$min min' : '${min ~/ 60} h ${min % 60} min';
}

class RouteService {
  RouteService({http.Client? client, this.apiKey = orsApiKey, this.api})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String apiKey;

  /// When set (API mode), routes are planned by the backend `/routes`.
  final ApiClient? api;

  Future<PlannedRoute> plan({
    required LatLng from,
    required String startLabel,
    required Place to,
    required NeedsProfile profile,
  }) async {
    final api = this.api;
    if (api != null) {
      try {
        final json = await api.post('/routes', body: {
          'points': [
            {'lat': from.latitude, 'lng': from.longitude},
            {'lat': to.lat, 'lng': to.lng},
          ],
          'profile': {
            'maxKerbCm': profile.maxKerbCm,
            'minWidthCm': profile.minWidthCm,
            'maxInclinePct': profile.maxInclinePct,
          },
        });
        return parseApi(json as Map<String, dynamic>,
            to: to, startLabel: startLabel);
      } catch (_) {
        return demoRoute(from, startLabel, to,
            reason: 'Serwer niedostępny — pokazano trasę przykładową');
      }
    }
    if (apiKey.isEmpty) {
      return demoRoute(from, startLabel, to, reason: 'Brak klucza OpenRouteService');
    }
    try {
      return await _ors(from, startLabel, to, profile);
    } catch (_) {
      return demoRoute(from, startLabel, to,
          reason: 'OpenRouteService niedostępny — pokazano trasę przykładową');
    }
  }

  Future<PlannedRoute> _ors(
      LatLng from, String startLabel, Place to, NeedsProfile profile) async {
    // ORS accepts only these values for the wheelchair profile.
    double nearest(List<double> allowed, double v) =>
        allowed.reduce((a, b) => (a - v).abs() <= (b - v).abs() ? a : b);

    final body = {
      'coordinates': [
        [from.longitude, from.latitude],
        [to.lng, to.lat],
      ],
      'instructions': true,
      'language': 'pl',
      'units': 'm',
      'options': {
        'profile_params': {
          'restrictions': {
            'maximum_sloped_kerb':
                nearest([0.03, 0.06, 0.1], profile.maxKerbCm / 100),
            'maximum_incline':
                nearest([3, 6, 10, 15], profile.maxInclinePct.toDouble()).round(),
            'minimum_width': profile.minWidthCm / 100,
          },
        },
      },
    };

    final res = await _client
        .post(
          Uri.parse(
              'https://api.openrouteservice.org/v2/directions/wheelchair/geojson'),
          headers: {'Authorization': apiKey, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw Exception('ORS ${res.statusCode}');
    }
    return parseOrs(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
        to: to, startLabel: startLabel);
  }

  static PlannedRoute parseOrs(Map<String, dynamic> json,
      {required Place to, required String startLabel}) {
    final feature = (json['features'] as List).first as Map<String, dynamic>;
    final coords = (feature['geometry']['coordinates'] as List)
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
    final props = feature['properties'] as Map<String, dynamic>;
    final summary = props['summary'] as Map<String, dynamic>? ?? const {};
    final steps = [
      for (final seg in props['segments'] as List? ?? const [])
        for (final step in (seg as Map<String, dynamic>)['steps'] as List? ?? const [])
          step as Map<String, dynamic>,
    ];
    return PlannedRoute(
      destination: to,
      startLabel: startLabel,
      points: coords,
      distanceM: (summary['distance'] as num?)?.toDouble() ?? 0,
      durationS: (summary['duration'] as num?)?.toDouble() ?? 0,
      segments: [
        for (final s in steps)
          RouteSegment(
            instruction: s['instruction'] as String? ?? '',
            distanceM: (s['distance'] as num?)?.toDouble() ?? 0,
          ),
      ],
      isDemo: false,
    );
  }

  /// Maps the backend `/routes` response (contract v2).
  static PlannedRoute parseApi(Map<String, dynamic> json,
      {required Place to, required String startLabel}) {
    final fallback = json['fallback'] as bool? ?? false;
    return PlannedRoute(
      destination: to,
      startLabel: startLabel,
      points: [
        for (final c in json['geometry'] as List? ?? const [])
          LatLng(((c as List)[0] as num).toDouble(), (c[1] as num).toDouble()),
      ],
      distanceM: (json['distanceM'] as num?)?.toDouble() ?? 0,
      durationS: (json['durationS'] as num?)?.toDouble() ?? 0,
      segments: [
        for (final s in json['segments'] as List? ?? const [])
          RouteSegment(
            instruction:
                (s as Map<String, dynamic>)['instruction'] as String? ?? '',
            distanceM: (s['distanceM'] as num?)?.toDouble() ?? 0,
            warning: s['warning'] as String?,
          ),
      ],
      isDemo: fallback,
      fallbackReason: fallback
          ? 'Serwer: trasa w linii prostej (OpenRouteService niedostępny)'
          : null,
    );
  }

  /// Sample route used without a key or network. Clearly marked as demo.
  static PlannedRoute demoRoute(LatLng from, String startLabel, Place to,
      {String? reason}) {
    const distance = Distance();
    final end = LatLng(to.lat, to.lng);
    final total = distance(from, end);

    // A gently bent line so it does not look like a ruler on the map.
    final mid = LatLng(
      (from.latitude + end.latitude) / 2 + 0.0006,
      (from.longitude + end.longitude) / 2 - 0.0008,
    );
    final points = [from, mid, end];
    final first = distance(from, mid);
    final second = max(0.0, total - first);

    return PlannedRoute(
      destination: to,
      startLabel: startLabel,
      points: points,
      distanceM: total,
      durationS: total / 1.0, // ~3.6 km/h wheelchair pace
      segments: [
        RouteSegment(
          instruction: 'Ruszaj: $startLabel — chodnik bez schodów',
          distanceM: first * 0.4,
        ),
        RouteSegment(
          instruction: 'Przejście dla pieszych z sygnalizacją',
          distanceM: 15,
          warning: 'Obniżony krawężnik',
        ),
        RouteSegment(
          instruction: 'Prosto, deptak',
          distanceM: max(0, first * 0.6 - 15),
          warning: 'Nawierzchnia: kostka brukowa',
        ),
        RouteSegment(
          instruction: 'Skręć w lewo i jedź łagodnym podjazdem',
          distanceM: second * 0.7,
          warning: 'Rampa, nachylenie ok. 5%',
        ),
        RouteSegment(
          instruction: 'Cel: ${to.name}',
          distanceM: second * 0.3,
        ),
      ],
      isDemo: true,
      fallbackReason: reason,
    );
  }
}

final routeServiceProvider = Provider((ref) =>
    RouteService(api: useApi ? ref.watch(apiClientProvider) : null));

class RouteNotifier extends Notifier<AsyncValue<PlannedRoute?>> {
  @override
  AsyncValue<PlannedRoute?> build() => const AsyncData(null);

  Future<void> plan(Place to, {LatLng? myLocation}) async {
    final profile =
        ref.read(profileProvider).value ?? NeedsProfile.wheelchair;

    // Use GPS only when the user is in Kraków; otherwise start at the Rynek.
    final nearKrakow = myLocation != null &&
        const Distance()(myLocation, rynekGlowny) < 15000;
    final from = nearKrakow ? myLocation : rynekGlowny;
    final label = nearKrakow ? 'Twoja lokalizacja' : 'Rynek Główny';

    state = const AsyncLoading();
    state = AsyncData(await ref.read(routeServiceProvider).plan(
          from: from,
          startLabel: label,
          to: to,
          profile: profile,
        ));
  }

  void clear() => state = const AsyncData(null);
}

final routeProvider =
    NotifierProvider<RouteNotifier, AsyncValue<PlannedRoute?>>(RouteNotifier.new);
