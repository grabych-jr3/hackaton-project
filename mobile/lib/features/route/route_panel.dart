import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../place/place_labels.dart';
import '../place/status_chip.dart';
import 'route_service.dart';

/// Bottom panel with the route summary and a text list of segments —
/// the accessible alternative to the line drawn on the map.
class RoutePanel extends StatelessWidget {
  const RoutePanel({
    super.key,
    required this.route,
    required this.onClose,
    this.onCycleStart,
    this.onClearManualStart,
  });

  final PlannedRoute route;
  final VoidCallback onClose;

  /// Cycles start options (Rynek / GPS / chosen point) — keyboard-friendly
  /// alternative to long-pressing the map.
  final VoidCallback? onCycleStart;

  /// Set when a manual start point exists; clears it.
  final VoidCallback? onClearManualStart;

  static const relaxedNote =
      'Nie znaleziono trasy spełniającej wszystkie progi — pokazano najbliższą możliwą';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 340),
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceGlass,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.border, width: 1.2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.accessible_forward_rounded,
                      color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Trasa do: ${route.destination.name}',
                        style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800, color: AppColors.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    tooltip: 'Zwiń listę kroków (trasa zostaje na mapie)',
                    icon: const Icon(Icons.expand_more_rounded, color: AppColors.textMuted),
                  ),
                ],
              ),
              Text(
                'Start: ${route.startLabel} · ${formatDistance(route.distanceM)} · ${formatDuration(route.durationS)}',
                style: text.bodyMedium?.copyWith(color: AppColors.text),
              ),
              if (onCycleStart != null || onClearManualStart != null)
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (onCycleStart != null)
                      TextButton.icon(
                        onPressed: onCycleStart,
                        icon: const Icon(Icons.flag_rounded, size: 18),
                        label: Text('Start: ${route.startLabel}'),
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero),
                      ),
                    if (onClearManualStart != null)
                      TextButton(
                        onPressed: onClearManualStart,
                        child: const Text('Usuń wybrany start'),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (route.isDemo)
                    const DemoBadge()
                  else
                    StatusChip(
                      StatusStyle(route.sourceLabel, Icons.route_rounded,
                          AppColors.primary, AppColors.mint100),
                      dense: true,
                    ),
                ],
              ),
              if (route.relaxed) ...[
                const SizedBox(height: 6),
                Semantics(
                  liveRegion: true,
                  child: Text(relaxedNote,
                      style: text.bodySmall?.copyWith(
                          color: AppColors.warn, fontWeight: FontWeight.w700)),
                ),
              ],
              if (route.fallbackReason != null) ...[
                const SizedBox(height: 6),
                Text(route.fallbackReason!,
                    style: text.bodySmall?.copyWith(color: AppColors.warn)),
              ],
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(right: 8),
                  itemCount: route.segments.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.border),
                  itemBuilder: (context, i) {
                    final s = route.segments[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text('${i + 1}.',
                                style: text.labelLarge
                                    ?.copyWith(color: AppColors.textMuted)),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.instruction,
                                    style: text.bodyMedium
                                        ?.copyWith(color: AppColors.text)),
                                if (s.warning != null)
                                  Text('⚠ ${s.warning}',
                                      style: text.bodySmall
                                          ?.copyWith(color: AppColors.warn)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(formatDistance(s.distanceM),
                              style: text.labelMedium
                                  ?.copyWith(color: AppColors.textMuted)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapsed route bar: the line stays on the map, steps are hidden.
class RouteCollapsedBar extends StatelessWidget {
  const RouteCollapsedBar({
    super.key,
    required this.route,
    required this.onExpand,
    required this.onClear,
  });

  final PlannedRoute route;
  final VoidCallback onExpand;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: AppColors.surfaceGlass,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            const Icon(Icons.route_rounded, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${route.destination.name} · ${formatDistance(route.distanceM)}'
                '${route.isDemo ? ' · przykładowa' : ''}',
                style: text.bodyMedium?.copyWith(
                    color: AppColors.text, fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onExpand,
              child: const Text('Pokaż kroki'),
            ),
            IconButton(
              onPressed: onClear,
              tooltip: 'Usuń trasę',
              icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
