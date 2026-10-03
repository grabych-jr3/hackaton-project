import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_colors.dart';
import 'route_service.dart';

/// Map layers of the planned route. With the 'Pasujące do mnie' chip off:
/// a plain walking line. With it on: red barrier spans + one "!" marker per
/// merged span, or the accessible alternative over the dimmed walking route.
class RouteLayer extends ConsumerWidget {
  const RouteLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref.watch(routeProvider).value;
    final showAlt = ref.watch(showAlternativeProvider);
    final barriers = ref.watch(routeBarriersEnabledProvider);
    if (route == null || route.points.length < 2) {
      return const SizedBox.shrink();
    }
    return RouteLayers(
        route: route, showAlternative: showAlt, showBarriers: barriers);
  }
}

/// Pure version of [RouteLayer] (testable without providers).
class RouteLayers extends StatelessWidget {
  const RouteLayers({
    super.key,
    required this.route,
    this.showAlternative = false,
    this.showBarriers = false,
  });

  final PlannedRoute route;
  final bool showAlternative;

  /// false = plain walking route, no accessibility info at all.
  final bool showBarriers;

  /// Points of geometry indices [from, to] (clamped).
  static List<LatLng> spanPoints(PlannedRoute r, int fromIndex, int toIndex) {
    final last = r.points.length - 1;
    final from = fromIndex.clamp(0, last);
    final to = toIndex.clamp(from, last);
    final pts = r.points.sublist(from, to + 1);
    return pts.length >= 2 ? pts : const [];
  }

  static List<Polyline> _spans(PlannedRoute r, {double alpha = 1}) => [
        for (final g in groupBarriers(r))
          if (spanPoints(r, g.fromIndex, g.toIndex) case final pts
              when pts.isNotEmpty)
            Polyline(
              points: pts,
              strokeWidth: alpha < 1 ? 5 : 7,
              color: AppColors.bad.withValues(alpha: alpha),
              strokeCap: StrokeCap.round,
              strokeJoin: StrokeJoin.round,
            ),
      ];

  static List<Polyline> polylines(PlannedRoute route, bool showAlternative,
      {bool showBarriers = true}) {
    if (!showBarriers) return _main(route.points);
    final alt = route.alternative;
    if (showAlternative && alt != null && alt.points.length > 1) {
      return [
        // Walking route dimmed in the background, its barriers still visible.
        Polyline(
          points: route.points,
          strokeWidth: 3,
          color: AppColors.textDim.withValues(alpha: 0.5),
        ),
        ..._spans(route, alpha: 0.45),
        ..._main(alt.points),
        ..._spans(alt),
      ];
    }
    return [..._main(route.points), ..._spans(route)];
  }

  static List<Polyline> _main(List<LatLng> points) => [
        // Outer glow line
        Polyline(
          points: points,
          strokeWidth: 8.0,
          color: AppColors.primary.withValues(alpha: 0.35),
          strokeCap: StrokeCap.round,
          strokeJoin: StrokeJoin.round,
        ),
        // Inner crisp core line
        Polyline(
          points: points,
          strokeWidth: 3.5,
          color: AppColors.primaryBright,
          strokeCap: StrokeCap.round,
          strokeJoin: StrokeJoin.round,
        ),
      ];

  /// The route whose barrier markers are shown (none when barriers are off).
  PlannedRoute? get markerRoute {
    if (!showBarriers) return null;
    final alt = route.alternative;
    return showAlternative && alt != null ? alt : route;
  }

  @override
  Widget build(BuildContext context) {
    final r = markerRoute;
    final groups = r == null ? const <BarrierGroup>[] : groupBarriers(r);
    return Stack(
      children: [
        PolylineLayer(
            polylines:
                polylines(route, showAlternative, showBarriers: showBarriers)),
        if (r != null && groups.isNotEmpty)
          MarkerLayer(markers: [
            for (final g in groups)
              Marker(
                point: r.points[g.fromIndex],
                width: 26,
                height: 26,
                child: Semantics(
                  label: 'Bariera: ${g.label}',
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.bad,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.priority_high_rounded,
                        size: 16, color: Colors.white),
                  ),
                ),
              ),
          ]),
      ],
    );
  }
}
