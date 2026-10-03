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

const barrierLabels = {
  'steps': 'Schody',
  'steep': 'Stromy odcinek',
  'surface': 'Nieodpowiednia nawierzchnia',
  'narrow': 'Wąskie przejście',
};

/// Part of a route not passable for the user's profile
/// (indices into [PlannedRoute.points], inclusive).
class RouteBarrier {
  const RouteBarrier({
    required this.fromIndex,
    required this.toIndex,
    required this.type,
    required this.label,
    this.detail,
  });

  final int fromIndex;
  final int toIndex;

  /// steps | steep | surface | narrow
  final String type;
  final String label;
  final String? detail;

  String get text => detail == null ? label : '$label ($detail)';

  static RouteBarrier? fromJson(Object? j) {
    if (j is! Map) return null;
    final from = (j['fromIndex'] as num?)?.toInt();
    final to = (j['toIndex'] as num?)?.toInt();
    if (from == null || to == null) return null;
    final type = j['type'] as String? ?? 'steps';
    return RouteBarrier(
      fromIndex: from,
      toIndex: to,
      type: type,
      label: j['label'] as String? ?? barrierLabels[type] ?? 'Bariera',
      detail: j['detail'] as String?,
    );
  }
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
    this.profile = 'foot-walking',
    this.barriers = const [],
    this.accessible = true,
    this.alternative,
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

  /// ORS profile: foot-walking (default route) or wheelchair (alternative).
  final String profile;

  /// Spans not passable for the user's profile (drawn red on the map).
  final List<RouteBarrier> barriers;

  /// false = some parts are not passable for the user's profile.
  final bool accessible;

  /// Wheelchair-accessible alternative (when [accessible] is false).
  final PlannedRoute? alternative;

  bool get isWheelchair => profile == 'wheelchair';

  String get kindLabel => isWheelchair ? 'Trasa dostępna' : 'Trasa piesza';

  String get sourceLabel => isDemo
      ? 'Trasa przykładowa'
      : isWheelchair
          ? 'OpenRouteService · profil wózka'
          : 'OpenRouteService · trasa piesza';

  PlannedRoute withAlternative(PlannedRoute? alt) => PlannedRoute(
        destination: destination,
        startLabel: startLabel,
        points: points,
        distanceM: distanceM,
        durationS: durationS,
        segments: segments,
        isDemo: isDemo,
        fallbackReason: fallbackReason ??
            (alt == null
                ? 'Nie udało się wyznaczyć trasy dostępnej (OpenRouteService)'
                : null),
        relaxed: relaxed,
        profile: profile,
        barriers: barriers,
        accessible: accessible,
        alternative: alt,
      );
}

String formatDistance(double m) => m >= 1000
    ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
    : '${m.round()} m';

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
            'maxSteps': profile.preset == ProfilePreset.stroller ? 2 : 0,
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
    final PlannedRoute walking;
    try {
      walking = await _ors(from, startLabel, to, profile,
          orsProfile: 'foot-walking', strict: false);
    } catch (e) {
      return demoRoute(from, startLabel, to,
          reason:
              'OpenRouteService niedostępny (${_msg(e)}) — pokazano trasę przykładową');
    }
    if (walking.accessible) return walking;
    PlannedRoute? alt;
    try {
      alt = await _wheelchair(from, startLabel, to, profile);
    } catch (_) {
      alt = null;
    }
    return walking.withAlternative(alt);
  }

  /// Wheelchair route: strict thresholds, relaxed retry when ORS finds none.
  Future<PlannedRoute> _wheelchair(
      LatLng from, String startLabel, Place to, NeedsProfile profile) async {
    try {
      return await _ors(from, startLabel, to, profile, strict: true);
    } on OrsException catch (e) {
      if (e.retryable) {
        return _ors(from, startLabel, to, profile, strict: false);
      }
      rethrow;
    }
  }

  static String _msg(Object e) => e is OrsException ? e.message : '$e';

  /// ORS codes meaning "no route found / point not routable".
  static const retryCodes = {2004, 2009, 2010, 2099};

  /// Builds the ORS request body; [strict] includes wheelchair restrictions.
  static Map<String, dynamic> orsBody(
      LatLng from, Place to, NeedsProfile profile,
      {bool strict = true, String orsProfile = 'wheelchair'}) {
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
      if (orsProfile == 'foot-walking')
        'extra_info': ['steepness', 'surface', 'waytype'],
      if (strict && orsProfile == 'wheelchair')
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
      {required bool strict, String orsProfile = 'wheelchair'}) async {
    final body =
        orsBody(from, to, profile, strict: strict, orsProfile: orsProfile);

    final res = await _client
        .post(
          Uri.parse(
              'https://api.openrouteservice.org/v2/directions/$orsProfile/geojson'),
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
        to: to,
        startLabel: startLabel,
        relaxed: orsProfile == 'wheelchair' && !strict,
        orsProfile: orsProfile,
        needs: orsProfile == 'foot-walking' ? profile : null);
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

  /// Parses an ORS geojson response. With [needs], barriers are computed
  /// from the `extras` (walking route).
  static PlannedRoute parseOrs(Map<String, dynamic> json,
      {required Place to,
      required String startLabel,
      bool relaxed = false,
      String orsProfile = 'wheelchair',
      NeedsProfile? needs}) {
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
    final barriers =
        needs == null ? const <RouteBarrier>[] : computeBarriers(props, needs);
    return PlannedRoute(
      destination: to,
      startLabel: startLabel,
      points: coords,
      profile: orsProfile,
      barriers: barriers,
      accessible: barriers.isEmpty,
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

  /// ORS surface codes not suitable for a wheelchair.
  static const badSurfaces = {
    2: 'nieutwardzona',
    10: 'żwir',
    11: 'ziemia',
    12: 'grunt',
    13: 'lód',
    15: 'piasek',
    16: 'zrębki',
    17: 'trawa',
    18: 'płyty ażurowe',
  };

  /// Lower bound (%) of an ORS steepness class (±1..±5).
  static int steepnessLowerBound(int cls) =>
      const [0, 1, 4, 7, 10, 16][cls.abs().clamp(0, 5)];

  static String _steepnessRange(int cls) =>
      const ['0%', '1–3%', '4–6%', '7–9%', '10–15%', '≥16%'][cls.abs().clamp(0, 5)];

  /// Barriers from ORS `extras` (steepness / surface / waytypes) for [needs].
  static List<RouteBarrier> computeBarriers(
      Map<String, dynamic> props, NeedsProfile needs) {
    final extras = props['extras'] as Map<String, dynamic>? ?? const {};
    List<List<int>> values(String key) => [
          for (final v in (extras[key] as Map?)?['values'] as List? ?? const [])
            [for (final n in v as List) (n as num).toInt()],
        ];
    final raw = <RouteBarrier>[];
    for (final v in values('waytypes')) {
      // ORS waytype 8 = steps (7 = footway).
      if (v.length == 3 && v[2] == 8) {
        raw.add(RouteBarrier(
            fromIndex: v[0], toIndex: v[1], type: 'steps', label: 'Schody'));
      }
    }
    for (final v in values('steepness')) {
      if (v.length == 3 && steepnessLowerBound(v[2]) > needs.maxInclinePct) {
        raw.add(RouteBarrier(
            fromIndex: v[0],
            toIndex: v[1],
            type: 'steep',
            label: 'Stromy odcinek',
            detail: 'ok. ${_steepnessRange(v[2])}'));
      }
    }
    if (needs.preset == ProfilePreset.wheelchair) {
      for (final v in values('surface')) {
        final name = v.length == 3 ? badSurfaces[v[2]] : null;
        if (name != null) {
          raw.add(RouteBarrier(
              fromIndex: v[0],
              toIndex: v[1],
              type: 'surface',
              label: 'Nieodpowiednia nawierzchnia',
              detail: name));
        }
      }
    }
    raw.sort((a, b) => a.fromIndex.compareTo(b.fromIndex));
    // Merge touching spans of the same type and detail.
    final out = <RouteBarrier>[];
    for (final b in raw) {
      final last = out.isEmpty ? null : out.last;
      if (last != null &&
          last.type == b.type &&
          last.detail == b.detail &&
          b.fromIndex <= last.toIndex) {
        out[out.length - 1] = RouteBarrier(
            fromIndex: last.fromIndex,
            toIndex: max(last.toIndex, b.toIndex),
            type: last.type,
            label: last.label,
            detail: last.detail);
      } else {
        out.add(b);
      }
    }
    return out;
  }

  /// Maps the backend `/routes` response (contract v3, with barriers).
  static PlannedRoute parseApi(Map<String, dynamic> json,
      {required Place to, required String startLabel}) {
    final fallback = json['fallback'] as bool? ?? false;
    final barriers = <RouteBarrier>[
      for (final b in json['barriers'] as List? ?? const [])
        if (RouteBarrier.fromJson(b) case final RouteBarrier r) r,
    ];
    final alt = json['alternative'];
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
      profile: json['profile'] as String? ?? 'foot-walking',
      barriers: barriers,
      accessible: json['accessible'] as bool? ?? barriers.isEmpty,
      alternative: alt is Map<String, dynamic>
          ? parseApi(alt, to: to, startLabel: startLabel)
          : null,
    );
  }

  /// Sample route used without a key or network. Clearly marked as demo:
  /// a walking route with one sample barrier + a sample accessible detour.
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

    final altMid = LatLng(
      (from.latitude + end.latitude) / 2 - 0.0009,
      (from.longitude + end.longitude) / 2 + 0.0011,
    );
    final altDistance = distance(from, altMid) + distance(altMid, end);
    final alternative = PlannedRoute(
      destination: to,
      startLabel: startLabel,
      points: [from, altMid, end],
      distanceM: altDistance,
      durationS: altDistance / 1.0, // ~3.6 km/h wheelchair pace
      profile: 'wheelchair',
      segments: [
        RouteSegment(
          instruction: 'Ruszaj: $startLabel — objazd bez schodów',
          distanceM: altDistance * 0.5,
          warning: 'DANE PRZYKŁADOWE',
        ),
        RouteSegment(
          instruction: 'Cel: ${to.name}',
          distanceM: altDistance * 0.5,
        ),
      ],
      isDemo: true,
    );

    return PlannedRoute(
      destination: to,
      startLabel: startLabel,
      points: points,
      distanceM: total,
      durationS: total / 1.3, // ~4.7 km/h walking pace
      profile: 'foot-walking',
      barriers: const [
        RouteBarrier(
          fromIndex: 0,
          toIndex: 1,
          type: 'steps',
          label: 'Schody (przykład)',
          detail: 'DANE PRZYKŁADOWE',
        ),
      ],
      accessible: false,
      alternative: alternative,
      segments: [
        RouteSegment(
          instruction: 'Ruszaj: $startLabel',
          distanceM: first * 0.4,
        ),
        RouteSegment(
          instruction: 'Zejdź schodami',
          distanceM: 15,
          warning: 'Schody — DANE PRZYKŁADOWE',
        ),
        RouteSegment(
          instruction: 'Prosto, deptak',
          distanceM: max(0, first * 0.6 - 15),
          warning: 'Nawierzchnia: kostka brukowa',
        ),
        RouteSegment(
          instruction: 'Skręć w lewo',
          distanceM: second * 0.7,
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

/// true = map and panel show [PlannedRoute.alternative] instead of the
/// walking route. Reset on every new plan / clear.
final showAlternativeProvider = StateProvider<bool>((ref) => false);

/// The route currently displayed (walking or its accessible alternative).
PlannedRoute? displayedRoute(PlannedRoute? route, bool showAlternative) =>
    showAlternative && route?.alternative != null ? route!.alternative : route;

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

    ref.read(showAlternativeProvider.notifier).state = false;
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

  void clear() {
    ref.read(showAlternativeProvider.notifier).state = false;
    state = const AsyncData(null);
  }
}

final routeProvider =
    NotifierProvider<RouteNotifier, AsyncValue<PlannedRoute?>>(RouteNotifier.new);
