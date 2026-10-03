import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    this.showAlternative,
    this.onToggleAlternative,
    this.showBarriers = false,
  });

  /// false ('Pasujące do mnie' off) = plain walking route: no barriers,
  /// no alternative toggle, no accessibility notes.
  final bool showBarriers;

  /// The planned (walking) route; its [PlannedRoute.alternative] may be shown.
  final PlannedRoute route;

  /// When null, read from [showAlternativeProvider] (needs a ProviderScope
  /// only if the route has an alternative).
  final bool? showAlternative;
  final VoidCallback? onToggleAlternative;
  final VoidCallback onClose;

  /// Cycles start options (Rynek / GPS / chosen point) — keyboard-friendly
  /// alternative to long-pressing the map.
  final VoidCallback? onCycleStart;

  /// Set when a manual start point exists; clears it.
  final VoidCallback? onClearManualStart;

  static const relaxedNote =
      'Nie znaleziono trasy spełniającej wszystkie progi — pokazano najbliższą możliwą';

  static const accessibleNote = 'Trasa bez barier dla Twojego profilu';
  static const noDataNote = 'Brak danych o dostępności trasy';

  static String barriersNote(List<RouteBarrier> b) =>
      'Na trasie są bariery (${b.length}): '
      '${b.map((e) => e.label).toSet().join(', ')}';

  static String _delta(double v, String Function(double) fmt) =>
      '${v < 0 ? '−' : '+'}${fmt(v.abs())}';

  static String alternativeButton(PlannedRoute walking, PlannedRoute alt) =>
      'Pokaż trasę dostępną (${_delta(alt.distanceM - walking.distanceM, formatDistance)}, '
      '${_delta(alt.durationS - walking.durationS, formatDuration)})';

  static const walkingButton = 'Pokaż trasę pieszą';

  @override
  Widget build(BuildContext context) {
    if (!showBarriers) return _panel(context, false, null, plain: true);
    if (route.alternative != null &&
        (showAlternative == null || onToggleAlternative == null)) {
      return Consumer(builder: (context, ref, _) {
        final bool show =
            showAlternative ?? ref.watch<bool>(showAlternativeProvider);
        return _panel(
            context,
            show,
            onToggleAlternative ??
                () => ref.read(showAlternativeProvider.notifier).state = !show);
      });
    }
    return _panel(context, showAlternative ?? false, onToggleAlternative);
  }

  Widget _panel(BuildContext context, bool showAlt, VoidCallback? onToggle,
      {bool plain = false}) {
    final text = Theme.of(context).textTheme;
    final route = plain ? this.route.plain() : this.route;
    final alt = route.alternative;
    final shown = showAlt && alt != null ? alt : route;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 440),
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
                '${shown.kindLabel} · ${formatDistance(shown.distanceM)} · ${formatDuration(shown.durationS)}',
                style: text.bodyMedium?.copyWith(
                    color: AppColors.text, fontWeight: FontWeight.w700),
              ),
              if (onCycleStart == null)
                Text('Start: ${route.startLabel}',
                    style: text.bodySmall?.copyWith(color: AppColors.textMuted)),
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
                  if (shown.isDemo)
                    const DemoBadge()
                  else
                    StatusChip(
                      StatusStyle(shown.sourceLabel, Icons.route_rounded,
                          AppColors.primary, AppColors.mint100),
                      dense: true,
                    ),
                ],
              ),
              if (shown.relaxed) ...[
                const SizedBox(height: 6),
                Semantics(
                  liveRegion: true,
                  child: Text(relaxedNote,
                      style: text.bodySmall?.copyWith(
                          color: AppColors.warn, fontWeight: FontWeight.w700)),
                ),
              ],
              if (shown.fallbackReason != null) ...[
                const SizedBox(height: 6),
                Text(shown.fallbackReason!,
                    style: text.bodySmall?.copyWith(color: AppColors.warn)),
              ],
              if (!plain) ...[
                const SizedBox(height: 6),
                _AccessNote(route: shown),
              ],
              if (shown.note != null) ...[
                const SizedBox(height: 6),
                Semantics(
                  liveRegion: true,
                  child: Text(shown.note!,
                      style: text.bodySmall?.copyWith(
                          color: AppColors.warn, fontWeight: FontWeight.w700)),
                ),
              ],
              if (alt != null && onToggle != null) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: showAlt
                      ? OutlinedButton.icon(
                          onPressed: onToggle,
                          icon: const Icon(Icons.directions_walk_rounded),
                          label: const Text(walkingButton),
                        )
                      : FilledButton.icon(
                          onPressed: onToggle,
                          icon: const Icon(Icons.accessible_forward_rounded),
                          label: Text(alternativeButton(route, alt)),
                        ),
                ),
              ],
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(right: 8),
                  itemCount: shown.barriers.length + shown.segments.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.border),
                  itemBuilder: (context, i) {
                    if (i < shown.barriers.length) {
                      final b = shown.barriers[i];
                      return Semantics(
                        label: 'Bariera: ${b.text}',
                        excludeSemantics: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const Icon(Icons.block_rounded,
                                  color: AppColors.bad, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(b.text,
                                    style: text.bodyMedium?.copyWith(
                                        color: AppColors.bad,
                                        fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    final s = shown.segments[i - shown.barriers.length];
                    final n = i - shown.barriers.length;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text('${n + 1}.',
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

/// Accessibility verdict of the shown route (barriers / ok / no data).
class _AccessNote extends StatelessWidget {
  const _AccessNote({required this.route});

  final PlannedRoute route;

  @override
  Widget build(BuildContext context) {
    // Relaxed alternative (accessible = !relaxed): the orange relaxed note
    // below says it all.
    if (route.barriers.isEmpty && !route.accessible && route.relaxed) {
      return const SizedBox.shrink();
    }
    final (String msg, Color fg, Color bg, IconData icon) =
        route.barriers.isNotEmpty
            ? (
                RoutePanel.barriersNote(route.barriers),
                AppColors.bad,
                AppColors.badBg,
                Icons.warning_amber_rounded,
              )
            : (route.isDemo && route.fallbackReason != null) ||
                    !route.accessible
                ? (
                    RoutePanel.noDataNote,
                    AppColors.warn,
                    AppColors.warnBg,
                    Icons.help_outline_rounded,
                  )
                : (
                    RoutePanel.accessibleNote,
                    AppColors.ok,
                    AppColors.okBg,
                    Icons.check_circle_rounded,
                  );
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fg.withValues(alpha: 0.6)),
        ),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(msg,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: fg, fontWeight: FontWeight.w700)),
            ),
          ],
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
    this.showBarriers = false,
    this.showAlternative = false,
    this.onToggleAlternative,
  });

  /// The planned (walking) route; its alternative may be the shown one.
  final PlannedRoute route;
  final VoidCallback onExpand;
  final VoidCallback onClear;

  /// 'Pasujące do mnie' on: barrier count + alternative toggle are shown.
  final bool showBarriers;
  final bool showAlternative;
  final VoidCallback? onToggleAlternative;

  /// Collapsed-bar toggle label, e.g. "Trasa dostępna: +300 m".
  static String alternativeLabel(PlannedRoute walking, PlannedRoute alt) =>
      'Trasa dostępna: ${RoutePanel._delta(alt.distanceM - walking.distanceM, formatDistance)}';

  static const walkingLabel = 'Trasa piesza';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final alt = showBarriers ? route.alternative : null;
    final showAlt = showAlternative && alt != null;
    final shown = showAlt ? alt : route;
    final barrierCount =
        showBarriers ? groupBarriers(shown).length : 0;
    return Material(
      color: AppColors.surfaceGlass,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    showAlt
                        ? Icons.accessible_forward_rounded
                        : Icons.route_rounded,
                    color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${route.destination.name} · ${formatDistance(shown.distanceM)}'
                    '${barrierCount > 0 ? ' · bariery: $barrierCount' : ''}'
                    '${shown.isDemo ? ' · przykładowa' : ''}',
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
                  icon: const Icon(Icons.close_rounded,
                      color: AppColors.textMuted),
                ),
              ],
            ),
            if (alt != null && onToggleAlternative != null)
              TextButton.icon(
                onPressed: onToggleAlternative,
                icon: Icon(
                    showAlt
                        ? Icons.directions_walk_rounded
                        : Icons.accessible_forward_rounded,
                    size: 18),
                label: Text(
                    showAlt ? walkingLabel : alternativeLabel(route, alt)),
              ),
          ],
        ),
      ),
    );
  }
}
