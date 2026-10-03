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

    return Scaffold(
      appBar: AppBar(title: const Text('Kolekcja')),
      body: switch ((catalog, game)) {
        (AsyncData(value: final c), AsyncData(value: final g)) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8,
                children: [
                  const DemoBadge(),
                  Text(
                    'Odkryto ${g.caught.keys.where((id) => c.speciesById(id) != null).length}/${c.species.length}',
                    style: theme.textTheme.labelLarge?.copyWith(color: AppColors.primary),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.82,
                children: [
                  for (final s in c.species) _SpeciesTile(s, g.caught[s.id] ?? 0),
                ],
              ),
              const SizedBox(height: 20),
              _CityProgress(c.districts),
            ],
          ),
        (AsyncError(:final error), _) || (_, AsyncError(:final error)) =>
          Center(child: Text('Nie udało się wczytać kolekcji: $error')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _SpeciesTile extends StatelessWidget {
  const _SpeciesTile(this.species, this.count);

  final Species species;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caught = count > 0;
    final name = caught ? species.name : '???';
    return Semantics(
      label: caught
          ? '${species.name}, ${species.rarity.label}, złapano $count'
          : 'Nieodkryty stworek, ${species.rarity.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: caught ? AppColors.mint100 : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: caught ? AppColors.mint300 : AppColors.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            caught
                ? Text(species.emoji, style: const TextStyle(fontSize: 34))
                : const Icon(Icons.lock_outline, size: 34, color: AppColors.unknown),
            const SizedBox(height: 4),
            Text(name,
                style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(species.rarity.label,
                style: theme.textTheme.labelSmall?.copyWith(color: AppColors.textMuted)),
            if (caught)
              Text('×$count',
                  style: theme.textTheme.labelMedium?.copyWith(color: AppColors.primary)),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, child: Text('Odkryte miasto', style: theme.textTheme.titleMedium)),
            const SizedBox(height: 4),
            Text('Ile ulic w dzielnicy ma już sprawdzone bariery',
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted)),
            const SizedBox(height: 12),
            for (final d in districts)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Semantics(
                  label: '${d.name}: ${d.percent} procent',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(child: Text(d.name)),
                        Text('${d.percent}%', style: theme.textTheme.labelLarge),
                      ]),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: d.percent / 100,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(99),
                        color: AppColors.primary,
                        backgroundColor: AppColors.mint100,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
