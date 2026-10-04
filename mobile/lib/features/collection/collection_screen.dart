import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../game/creature_image.dart';
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
                  _PointsBadge(g.points),
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
                childAspectRatio: 0.6,
                children: [
                  for (final s in c.species)
                    _SpeciesTile(s, g.caught[s.id] ?? 0,
                        discovered: g.caught.containsKey(s.id)),
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

Color _rarityColor(Rarity rarity) => switch (rarity) {
      Rarity.legendary => AppColors.gold,
      Rarity.epic => AppColors.accentPurple,
      Rarity.rare => AppColors.accentCyan,
      Rarity.common => AppColors.primary,
    };

/// Luminance (BT.709) grayscale matrix used for sold-out species.
const List<double> kGrayscaleMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0,
];

/// Renders [child] in black-and-white.
class Grayscale extends StatelessWidget {
  const Grayscale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColorFiltered(
        colorFilter: const ColorFilter.matrix(kGrayscaleMatrix),
        child: child,
      );
}

class _PointsBadge extends StatelessWidget {
  const _PointsBadge(this.points);

  final int points;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Twoje saldo: $points punktów',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.gold),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.stars_rounded, size: 16, color: AppColors.gold),
              const SizedBox(width: 6),
              Text(
                'Saldo: $points pkt',
                style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      );
}

class _SpeciesTile extends StatelessWidget {
  const _SpeciesTile(this.species, this.count, {required this.discovered});

  final Species species;
  final int count;

  /// Caught at least once — stays unlocked after selling every piece.
  final bool discovered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caught = discovered;
    final canSell = count > 0;
    final soldOut = caught && !canSell;
    final vivid = caught && canSell;
    final name = caught ? species.name : '???';
    final rarityColor = _rarityColor(species.rarity);

    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        caught
            ? (soldOut
                ? Grayscale(
                    child: CreatureImage(speciesId: species.id, emoji: species.emoji, size: 56))
                : CreatureImage(speciesId: species.id, emoji: species.emoji, size: 56))
            : const Icon(Icons.lock_outline_rounded, size: 34, color: AppColors.textDim),
        const SizedBox(height: 4),
        Text(
          name,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: vivid ? AppColors.text : AppColors.textMuted,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        Text(
          species.rarity.label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: vivid ? rarityColor : AppColors.textDim,
            fontWeight: FontWeight.w600,
            fontSize: 10,
          ),
        ),
        if (caught)
          Text(
            canSell ? '×$count' : 'sprzedane',
            style: theme.textTheme.labelMedium?.copyWith(
              color: canSell ? AppColors.primary : AppColors.textMuted,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: vivid ? AppColors.surfaceElevated : AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: vivid ? rarityColor.withValues(alpha: 0.8) : AppColors.border,
          width: vivid ? 1.5 : 1.0,
        ),
        boxShadow: [
          if (vivid)
            BoxShadow(
              color: rarityColor.withValues(alpha: 0.18),
              blurRadius: 10,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            Expanded(
              child: Semantics(
                button: caught,
                label: soldOut
                    ? '${species.name}, ${species.rarity.label}, sprzedany, brak w kolekcji'
                    : caught
                    ? '${species.name}, ${species.rarity.label}, posiadasz $count, '
                        'wartość ${species.sellValue} punktów'
                    : 'Nieodkryty stworek, ${species.rarity.label}',
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: caught ? () => showSellSheet(context, species) : null,
                  child: Padding(padding: const EdgeInsets.all(6), child: content),
                ),
              ),
            ),
            if (canSell)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                child: Semantics(
                  label: 'Sprzedaj ${species.name}, ${species.sellValue} punktów za sztukę',
                  excludeSemantics: true,
                  button: true,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      foregroundColor: AppColors.primary,
                      backgroundColor: AppColors.mint100,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () => showSellSheet(context, species),
                    child: FittedBox(
                      child: Text(
                        'Sprzedaj · ${species.sellValue} pkt',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Opens the detail / sell sheet for a caught [species].
Future<void> showSellSheet(BuildContext context, Species species) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SpeciesSellSheet(species: species),
    );

class SpeciesSellSheet extends ConsumerStatefulWidget {
  const SpeciesSellSheet({super.key, required this.species});

  final Species species;

  @override
  ConsumerState<SpeciesSellSheet> createState() => _SpeciesSellSheetState();
}

class _SpeciesSellSheetState extends ConsumerState<SpeciesSellSheet> {
  int _qty = 1;
  bool _selling = false;

  Species get s => widget.species;

  String _failureText(SellFailure f) => switch (f) {
        SellFailure.invalidCount => 'Nieprawidłowa liczba stworków.',
        SellFailure.notEnoughCreatures => 'Nie masz tylu stworków.',
        SellFailure.unknownSpecies => 'Nieznany gatunek.',
      };

  Future<void> _sell(int qty) async {
    final total = qty * s.sellValue;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('Potwierdź sprzedaż'),
        content: Text('Sprzedać $qty × ${s.name} za $total pkt?'),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(64, 48),
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.background,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Potwierdź'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _selling = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final view = View.of(context);
    final dir = Directionality.of(context);
    try {
      final earned = await ref.read(gameProvider.notifier).sell(s.id, qty);
      final msg = 'Sprzedano $qty × ${s.name} za $earned pkt';
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(msg)));
      SemanticsService.sendAnnouncement(
          view, msg, dir);
    } on SellException catch (e) {
      if (!mounted) return;
      setState(() => _selling = false);
      messenger.showSnackBar(SnackBar(content: Text(_failureText(e.failure))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _selling = false);
      messenger.showSnackBar(SnackBar(content: Text('Nie udało się sprzedać: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owned = ref.watch(gameProvider).value?.caught[s.id] ?? 0;
    final qty = _qty.clamp(1, owned < 1 ? 1 : owned);
    final total = qty * s.sellValue;
    final color = owned > 0 ? _rarityColor(s.rarity) : AppColors.textMuted;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(
              child: owned > 0
                  ? Center(child: CreatureImage(speciesId: s.id, emoji: s.emoji, size: 140))
                  : Grayscale(
                      child: Center(
                          child: CreatureImage(speciesId: s.id, emoji: s.emoji, size: 140)),
                    ),
            ),
            const SizedBox(height: 8),
            Semantics(
              header: true,
              child: Text(
                s.name,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Rzadkość: ${s.rarity.label}',
              textAlign: TextAlign.center,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Posiadasz: $owned · Wartość: ${s.sellValue} pkt / szt.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted),
            ),
            if (s.description != null) ...[
              const SizedBox(height: 12),
              Text(s.description!, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 16),
            if (owned > 0) ...[
              Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Zmniejsz liczbę',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: qty > 1 && !_selling ? () => setState(() => _qty = qty - 1) : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        'Liczba: $qty',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Zwiększ liczbę',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed:
                        qty < owned && !_selling ? () => setState(() => _qty = qty + 1) : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              if (owned > 1)
                Slider(
                  value: qty.toDouble(),
                  min: 1,
                  max: owned.toDouble(),
                  divisions: owned - 1,
                  label: '$qty',
                  semanticFormatterCallback: (v) => 'Liczba do sprzedaży: ${v.round()}',
                  activeColor: AppColors.primary,
                  onChanged: _selling ? null : (v) => setState(() => _qty = v.round()),
                ),
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.background,
                ),
                onPressed: _selling ? null : () => _sell(qty),
                child: Text('Sprzedaj ($qty) za $total pkt'),
              ),
            ] else
              const Text(
                'Nie masz już tego stworka — złap go ponownie',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted),
              ),
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
