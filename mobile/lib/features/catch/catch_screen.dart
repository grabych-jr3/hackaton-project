import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/places_repository.dart';
import '../game/game_models.dart';
import '../game/game_providers.dart';
import '../place/status_chip.dart';

const currentLocationLabel = 'Obecna lokalizacja';

/// Stage 8: manual barrier survey instead of the camera.
class CatchScreen extends ConsumerStatefulWidget {
  const CatchScreen({super.key});

  @override
  ConsumerState<CatchScreen> createState() => _CatchScreenState();
}

class _CatchScreenState extends ConsumerState<CatchScreen> {
  String? _placeId; // null = current location
  bool _hasSteps = false;
  int _steps = 1;
  CurbRange _curb = CurbRange.none;
  PassageWidth _passage = PassageWidth.none;
  bool _noRamp = false;
  bool _uneven = false;
  bool _obstacles = false;
  bool _sending = false;

  BarrierReport get _report => BarrierReport(
        placeId: _placeId,
        steps: _hasSteps ? _steps : 0,
        curb: _curb,
        passage: _passage,
        noRamp: _noRamp,
        uneven: _uneven,
        obstacles: _obstacles,
      );

  void _reset() => setState(() {
        _hasSteps = false;
        _steps = 1;
        _curb = CurbRange.none;
        _passage = PassageWidth.none;
        _noRamp = _uneven = _obstacles = false;
      });

  Future<void> _submit() async {
    setState(() => _sending = true);
    final result = await ref.read(gameProvider.notifier).submitReport(_report);
    if (!mounted) return;
    setState(() => _sending = false);
    if (result == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Złapano: ${result.species.name} (${result.species.rarity.label}) +${result.points} pkt',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Text(result.species.emoji, style: const TextStyle(fontSize: 56)),
            ),
            const SizedBox(height: 12),
            const Text(
              'Zgłoszenie niezweryfikowane — trafi na mapę po potwierdzeniu.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Super!'),
          ),
        ],
      ),
    );
    if (mounted) _reset();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final places = ref.watch(placesProvider).value ?? const [];
    final points = ref.watch(gameProvider).value?.points;

    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
        );

    Widget choices<T>(List<(T, String)> options, T value, ValueChanged<T> onChanged) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (v, label) in options)
              ChoiceChip(
                label: Text(label),
                selected: v == value,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => setState(() => onChanged(v)),
              ),
          ],
        );

    Widget check(String label, bool value, ValueChanged<bool> onChanged) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(label),
          value: value,
          onChanged: (v) => setState(() => onChanged(v ?? false)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Złap')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8,
            children: [
              const DemoBadge(),
              if (points != null)
                Text('Saldo: $points pkt',
                    style: theme.textTheme.labelLarge?.copyWith(color: AppColors.primary)),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.mint100,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: const Row(
              children: [
                Icon(Icons.fact_check_outlined, color: AppColors.primary),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Zgłoś barierę w ankiecie i złap stworka. Im więcej barier, '
                    'tym rzadszy stworek. Kamera pojawi się wkrótce.',
                  ),
                ),
              ],
            ),
          ),
          section('Miejsce'),
          DropdownButtonFormField<String?>(
            initialValue: _placeId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Gdzie jest bariera?'),
            items: [
              const DropdownMenuItem(value: null, child: Text(currentLocationLabel)),
              for (final p in places)
                DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _placeId = v),
          ),
          section('Bariery'),
          check('Schody', _hasSteps, (v) => _hasSteps = v),
          if (_hasSteps)
            Row(
              children: [
                const SizedBox(width: 16),
                const Text('Liczba stopni:'),
                IconButton(
                  tooltip: 'Mniej stopni',
                  onPressed: _steps > 1 ? () => setState(() => _steps--) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Semantics(
                  liveRegion: true,
                  label: 'Liczba stopni $_steps',
                  child: ExcludeSemantics(
                    child: Text('$_steps', style: theme.textTheme.titleMedium),
                  ),
                ),
                IconButton(
                  tooltip: 'Więcej stopni',
                  onPressed: () => setState(() => _steps++),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
          check('Brak podjazdu', _noRamp, (v) => _noRamp = v),
          check('Nierówna nawierzchnia', _uneven, (v) => _uneven = v),
          check('Przeszkody na drodze', _obstacles, (v) => _obstacles = v),
          section('Krawężnik'),
          choices<CurbRange>(
            const [
              (CurbRange.none, 'Brak'),
              (CurbRange.low, '0–3 cm'),
              (CurbRange.mid, '3–7 cm'),
              (CurbRange.high, '> 7 cm'),
            ],
            _curb,
            (v) => _curb = v,
          ),
          section('Wąskie przejście'),
          choices<PassageWidth>(
            const [
              (PassageWidth.none, 'Brak'),
              (PassageWidth.wide, '> 90 cm'),
              (PassageWidth.medium, '70–90 cm'),
              (PassageWidth.narrow, '< 70 cm'),
            ],
            _passage,
            (v) => _passage = v,
          ),
          const SizedBox(height: 24),
          if (_report.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Zaznacz co najmniej jedną barierę.',
                  style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted)),
            ),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _report.isEmpty || _sending || points == null ? null : _submit,
            icon: const Icon(Icons.send),
            label: const Text('Wyślij zgłoszenie'),
          ),
        ],
      ),
    );
  }
}
