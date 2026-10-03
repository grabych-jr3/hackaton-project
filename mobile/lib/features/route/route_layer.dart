import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_colors.dart';
import 'route_service.dart';

/// Map layers of the planned route: walking line with red barrier spans
/// and warning markers, or the accessible alternative when selected.
class RouteLayer extends ConsumerWidget {
  const RouteLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref.watch(routeProvider).value;
    final showAlt = ref.watch(showAlternativeProvider);
    if (route == null || route.points.length < 2) {
      return const SizedBox.shrink();
    }
    return RouteLayers(route: route, showAlternative: showAlt);
  }
}

/// Pure version of [RouteLayer] (testable without providers).
class RouteLayers extends StatelessWidget {
  const RouteLayers(
      {super.key, required this.route, this.showAlternative = false});

  final PlannedRoute route;
  final bool showAlternative;

  /// Barrier span points (indices clamped to the geometry).
  static List<LatLng> spanPoints(PlannedRoute r, RouteBarrier b) {
    final last = r.points.length - 1;
    final from = b.fromIndex.clamp(0, last);
    final to = b.toIndex.clamp(from, last);
    final pts = r.points.sublist(from, to + 1);
    return pts.length >= 2 ? pts : const [];
  }

  static List<Polyline> polylines(PlannedRoute route, bool showAlternative) {
    final alt = route.alternative;
    if (showAlternative && alt != null && alt.points.length > 1) {
      return [
        // Walking route dimmed in the background.
        Polyline(
          points: route.points,
          strokeWidth: 3,
          color: AppColors.textDim.withValues(alpha: 0.5),
        ),
        ..._main(alt.points),
      ];
    }
    return [
      ..._main(route.points),
      for (final b in route.barriers)
        if (spanPoints(route, b).isNotEmpty)
          Polyline(
            points: spanPoints(route, b),
            strokeWidth: 7,
            color: AppColors.bad,
            strokeCap: StrokeCap.round,
            strokeJoin: StrokeJoin.round,
          ),
    ];
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

  @override
  Widget build(BuildContext context) {
    final showMarkers = !(showAlternative && route.alternative != null);
    return Stack(
      children: [
        PolylineLayer(polylines: polylines(route, showAlternative)),
        if (showMarkers && route.barriers.isNotEmpty)
          MarkerLayer(markers: [
            for (final b in route.barriers)
              Marker(
                point: route.points[b.fromIndex.clamp(0, route.points.length - 1)],
                width: 26,
                height: 26,
                child: Semantics(
                  label: 'Bariera: ${b.label}',
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
