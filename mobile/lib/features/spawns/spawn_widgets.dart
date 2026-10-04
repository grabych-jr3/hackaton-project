import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../game/game_models.dart';
import 'spawn.dart';
import 'spawn_providers.dart';

Color rarityColor(Rarity r) => switch (r) {
      Rarity.common => AppColors.textMuted,
      Rarity.rare => AppColors.accentCyan,
      Rarity.epic => AppColors.accentPurple,
      Rarity.legendary => AppColors.gold,
    };

/// "Stworek: Smok, legendarny, 120 m od Ciebie[, już złapany]".
String spawnSemanticLabel(SpawnDistance d) =>
    'Stworek: ${d.spawn.name}, ${d.spawn.rarity.label}, ${d.label}'
    '${d.spawn.caughtByMe ? ', już złapany' : ''}';

/// Opens the AR camera for [spawn].
void openSpawnCamera(BuildContext context, Spawn spawn) {
  context.push(Uri(path: '/catch/camera', queryParameters: {
    'spawnId': spawn.id,
    'emoji': spawn.emoji,
    'name': spawn.name,
    'spawnLat': spawn.lat.toString(),
    'spawnLng': spawn.lng.toString(),
  }).toString());
}

/// Creature markers for the map ([onTap] opens the sheet).
class SpawnMarkerLayer extends ConsumerWidget {
  const SpawnMarkerLayer({super.key, required this.onTap});

  final ValueChanged<SpawnDistance> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spawns = ref.watch(nearbySpawnsProvider);
    return MarkerLayer(markers: [
      // Farthest first so the nearest are drawn on top.
      for (final d in spawns.reversed)
        Marker(
          key: ValueKey('spawn-${d.spawn.id}'),
          point: d.spawn.point,
          width: 48,
          height: 48,
          child: SpawnMarker(distance: d, onTap: () => onTap(d)),
        ),
    ]);
  }
}

class SpawnMarker extends StatelessWidget {
  const SpawnMarker({super.key, required this.distance, required this.onTap});

  final SpawnDistance distance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final spawn = distance.spawn;
    final color = rarityColor(spawn.rarity);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final marker = Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surface,
        border: Border.all(color: color, width: 2.5),
        boxShadow: spawn.caughtByMe
            ? null
            : [
                BoxShadow(
                    color: color.withValues(alpha: 0.55),
                    blurRadius: 12,
                    spreadRadius: 2),
              ],
      ),
      alignment: Alignment.center,
      child: Text(spawn.emoji, style: const TextStyle(fontSize: 22)),
    );
    return Semantics(
      button: true,
      label: spawnSemanticLabel(distance),
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        // One-shot pop-in (no looping pulse); skipped with reduce motion.
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: reduceMotion ? 1 : 0.6, end: 1),
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 350),
          curve: Curves.easeOutBack,
          builder: (_, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Opacity(opacity: spawn.caughtByMe ? 0.4 : 1, child: marker),
        ),
      ),
    );
  }
}

/// Small sheet: emoji, name, rarity, distance, "Złap aparatem".
Future<void> showSpawnSheet(BuildContext context, SpawnDistance d) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheetContext) => SpawnSheet(
        distance: d,
        onCatch: () {
          Navigator.of(sheetContext).pop();
          openSpawnCamera(context, d.spawn);
        },
      ),
    );

class SpawnSheet extends StatelessWidget {
  const SpawnSheet({super.key, required this.distance, required this.onCatch});

  final SpawnDistance distance;
  final VoidCallback onCatch;

  @override
  Widget build(BuildContext context) {
    final spawn = distance.spawn;
    final text = Theme.of(context).textTheme;
    final color = rarityColor(spawn.rarity);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              ExcludeSemantics(
                  child: Text(spawn.emoji, style: const TextStyle(fontSize: 44))),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(spawn.name,
                          style: text.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800)),
                    ),
                    Text(spawn.rarity.label,
                        style: text.bodyMedium?.copyWith(
                            color: color, fontWeight: FontWeight.w700)),
                    Text(distance.label, style: text.bodyMedium),
                    if (spawn.caughtByMe)
                      Text('Już złapany', style: text.bodySmall),
                    if (spawn.isDemo)
                      Text('DANE PRZYKŁADOWE', style: text.labelSmall),
                  ],
                ),
              ),
            ]),
            if (!distance.inRange) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  distance.fromGps
                      ? 'Podejdź bliżej (≤ ${catchRadiusM.round()} m), aby złapać'
                      : 'Włącz lokalizację, aby złapać stworka',
                  style: text.bodyMedium?.copyWith(color: AppColors.warn),
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              // Too far (or no GPS): catching is blocked right here, not only by the server.
              onPressed: distance.inRange ? onCatch : null,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(distance.inRange ? 'Złap aparatem' : 'Za daleko'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Text alternative to the creature markers (list mode).
class NearbySpawnsSection extends ConsumerStatefulWidget {
  const NearbySpawnsSection({super.key, this.collapsedItems = 2});

  /// Shown before "Pokaż więcej", so places stay visible below.
  final int collapsedItems;

  @override
  ConsumerState<NearbySpawnsSection> createState() =>
      _NearbySpawnsSectionState();
}

class _NearbySpawnsSectionState extends ConsumerState<NearbySpawnsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(nearbySpawnsProvider);
    final spawns =
        _expanded ? all : all.take(widget.collapsedItems).toList();
    final hidden = all.length - spawns.length;
    final text = Theme.of(context).textTheme;
    if (all.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text('Stworki w pobliżu',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 6),
        for (final d in spawns)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                child: Row(children: [
                  ExcludeSemantics(
                      child: Opacity(
                    opacity: d.spawn.caughtByMe ? 0.4 : 1,
                    child: Text(d.spawn.emoji,
                        style: const TextStyle(fontSize: 26)),
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MergeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(d.spawn.name,
                              style: text.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(
                            '${d.spawn.rarity.label} · ${d.label}'
                            '${d.spawn.caughtByMe ? ' · złapany' : ''}',
                            style: text.bodySmall?.copyWith(
                                color: rarityColor(d.spawn.rarity)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Semantics(
                    label: 'Złap: ${d.spawn.name}',
                    button: true,
                    excludeSemantics: true,
                    onTap: d.inRange
                        ? () => openSpawnCamera(context, d.spawn)
                        : null,
                    child: TextButton(
                      onPressed: d.inRange
                          ? () => openSpawnCamera(context, d.spawn)
                          : null,
                      child: Text(d.inRange ? 'Złap' : 'Za daleko'),
                    ),
                  ),
                ]),
              ),
            ),
        if (hidden > 0 || _expanded && all.length > widget.collapsedItems)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded
                  ? 'Pokaż mniej stworków'
                  : 'Pokaż więcej stworków ($hidden)'),
            ),
          ),
      ],
    );
  }
}
