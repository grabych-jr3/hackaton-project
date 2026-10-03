import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../game/game_models.dart';
import '../game/game_providers.dart';
import '../place/status_chip.dart';

class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(gameCatalogProvider);
    final game = ref.watch(gameProvider);
    final theme = Theme.of(context);
    final error = catalog.error ?? game.error;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Kolekcja stworków')),
      body: switch ((catalog.value, game.value)) {
        _ when error != null =>
          Center(child: Text('Nie udało się wczytać kolekcji: $error')),
        (final c?, final g?) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  const DemoBadge(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.mint100,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.primary),
                    ),
                    child: Text(
                      'Odkryto ${g.caught.keys.where((id) => c.speciesById(id) != null).length}/${c.species.length}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.78,
                children: [
                  for (final s in c.species) _SpeciesTile(s, g.caught[s.id] ?? 0),
                ],
              ),
              const SizedBox(height: 24),
              _CityProgress(c.districts),
            ],
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _SpeciesTile extends StatelessWidget {
  const _SpeciesTile(this.species, this.count);

  final Species species;
  final int count;

  Color _rarityColor(Rarity rarity) => switch (rarity) {
        Rarity.legendary => AppColors.gold,
        Rarity.epic => AppColors.accentPurple,
        Rarity.rare => AppColors.accentCyan,
        Rarity.common => AppColors.primary,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caught = count > 0;
    final name = caught ? species.name : '???';
    final rarityColor = _rarityColor(species.rarity);

    return Semantics(
      label: caught
          ? '${species.name}, ${species.rarity.label}, złapano $count'
          : 'Nieodkryty stworek, ${species.rarity.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: caught ? AppColors.surfaceElevated : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: caught ? rarityColor.withValues(alpha: 0.8) : AppColors.border,
            width: caught ? 1.5 : 1.0,
          ),
          boxShadow: [
            if (caught)
              BoxShadow(
                color: rarityColor.withValues(alpha: 0.18),
                blurRadius: 10,
                spreadRadius: 1,
              ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            caught
                ? Text(species.emoji, style: const TextStyle(fontSize: 36))
                : const Icon(Icons.lock_outline_rounded, size: 36, color: AppColors.textDim),
            const SizedBox(height: 6),
            Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: caught ? AppColors.text : AppColors.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              species.rarity.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: caught ? rarityColor : AppColors.textDim,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
            ),
            if (caught) ...[
              const SizedBox(height: 2),
              Text(
                '×$count',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CityProgress extends StatelessWidget {
  const _CityProgress(this.districts);

  final List<DistrictProgress> districts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.map_outlined, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Odkryte miasto',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Ile ulic w dzielnicy ma już sprawdzone bariery architektoniczne',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          for (final d in districts)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Semantics(
                label: '${d.name}: ${d.percent} procent',
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            d.name,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ),
                        Text(
                          '${d.percent}%',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: d.percent / 100,
                        minHeight: 8,
                        color: AppColors.primary,
                        backgroundColor: AppColors.surfaceElevated,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
