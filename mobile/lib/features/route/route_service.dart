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
import 'route_start.dart';

export 'route_start.dart' show rynekGlowny;

/// OpenRouteService key, passed with
/// `--dart-define-from-file=config/secrets.json` (never committed).
const orsApiKey = String.fromEnvironment('ORS_API_KEY');

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
    this.relaxed = false,
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

  /// true = found only after relaxing the wheelchair thresholds.
  final bool relaxed;

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
      return await _ors(from, startLabel, to, profile, strict: true);
    } on OrsException catch (e) {
      if (e.retryable) {
        try {
          return await _ors(from, startLabel, to, profile, strict: false);
        } catch (e2) {
          return demoRoute(from, startLabel, to,
              reason: 'OpenRouteService: ${_msg(e2)} — pokazano trasę przykładową');
        }
      }
      return demoRoute(from, startLabel, to,
          reason: 'OpenRouteService: ${e.message} — pokazano trasę przykładową');
    } catch (e) {
      return demoRoute(from, startLabel, to,
          reason: 'OpenRouteService niedostępny (${_msg(e)}) — pokazano trasę przykładową');
    }
  }

  static String _msg(Object e) => e is OrsException ? e.message : '$e';

  /// ORS codes meaning "no route found / point not routable".
  static const retryCodes = {2004, 2009, 2010, 2099};

  /// Builds the ORS request body; [strict] includes wheelchair restrictions.
  static Map<String, dynamic> orsBody(
      LatLng from, Place to, NeedsProfile profile, {bool strict = true}) {
    // ORS accepts only these values for the wheelchair profile.
    double nearest(List<double> allowed, double v) =>
        allowed.reduce((a, b) => (a - v).abs() <= (b - v).abs() ? a : b);
    return {
      'coordinates': [
        [from.longitude, from.latitude],
        [to.lng, to.lat],
      ],
      'radiuses': [-1, -1],
      'instructions': true,
      'language': 'pl',
      'units': 'm',
      if (strict)
        'options': {
          'profile_params': {
            'restrictions': {
              'maximum_sloped_kerb':
                  nearest([0.03, 0.06, 0.1], profile.maxKerbCm / 100),
              'maximum_incline': nearest(
                      [3, 6, 10, 15], profile.maxInclinePct.toDouble())
                  .round(),
              'minimum_width': profile.minWidthCm / 100,
            },
          },
        },
    };
  }

  Future<PlannedRoute> _ors(
      LatLng from, String startLabel, Place to, NeedsProfile profile,
      {required bool strict}) async {
    final body = orsBody(from, to, profile, strict: strict);

    final res = await _client
        .post(
          Uri.parse(
              'https://api.openrouteservice.org/v2/directions/wheelchair/geojson'),
          headers: {'Authorization': apiKey, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));
    final decoded = _tryDecode(res.bodyBytes);
    if (res.statusCode != 200) {
      final err = decoded is Map ? decoded['error'] : null;
      final code = err is Map ? (err['code'] as num?)?.toInt() : null;
      final message = err is Map
          ? (err['message'] as String? ?? 'błąd ${res.statusCode}')
          : (err is String ? err : 'błąd ${res.statusCode}');
      throw OrsException(message, code: code);
    }
    final features = decoded is Map ? decoded['features'] as List? : null;
    if (features == null || features.isEmpty) {
      throw const OrsException('brak trasy', code: 2009);
    }
    final route = parseOrs(decoded as Map<String, dynamic>,
        to: to, startLabel: startLabel, relaxed: !strict);
    if (route.points.length < 2) {
      throw const OrsException('pusta trasa', code: 2009);
    }
    return route;
  }

  static Object? _tryDecode(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  static PlannedRoute parseOrs(Map<String, dynamic> json,
      {required Place to, required String startLabel, bool relaxed = false}) {
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
      relaxed: relaxed,
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
      relaxed: json['relaxed'] as bool? ?? false,
      fallbackReason: json['fallbackReason'] as String? ??
          (fallback
              ? 'Serwer: trasa w linii prostej (OpenRouteService niedostępny)'
              : null),
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

class OrsException implements Exception {
  const OrsException(this.message, {this.code});
  final String message;
  final int? code;
  bool get retryable => RouteService.retryCodes.contains(code);
  @override
  String toString() => 'OrsException($code): $message';
}

final routeServiceProvider = Provider((ref) =>
    RouteService(api: useApi ? ref.watch(apiClientProvider) : null));

class RouteNotifier extends Notifier<AsyncValue<PlannedRoute?>> {
  @override
  AsyncValue<PlannedRoute?> build() => const AsyncData(null);

  Place? _lastDestination;

  /// Plans to [to]. Start: manual > GPS (near & accurate) > Rynek Główny.
  /// [myLocation] overrides the GPS fix from [userLocationProvider].
  Future<void> plan(Place to, {LatLng? myLocation, double? accuracyM}) async {
    _lastDestination = to;
    final profile =
        ref.read(profileProvider).value ?? NeedsProfile.wheelchair;
    final gps = myLocation != null
        ? UserLocation(myLocation, accuracyM: accuracyM ?? 0)
        : ref.read(userLocationProvider);
    final start = selectStart(
      manual: ref.read(manualStartProvider),
      gps: gps,
      preference: ref.read(startPreferenceProvider),
    );
    final from = start.point;
    final label = start.label;

    state = const AsyncLoading();
    state = AsyncData(await ref.read(routeServiceProvider).plan(
          from: from,
          startLabel: label,
          to: to,
          profile: profile,
        ));
  }

  /// Re-plans the last destination (e.g. after the start changed).
  Future<void> replan() async {
    final to = _lastDestination;
    if (to != null && state.value != null) await plan(to);
  }

  void clear() => state = const AsyncData(null);
}

final routeProvider =
    NotifierProvider<RouteNotifier, AsyncValue<PlannedRoute?>>(RouteNotifier.new);
