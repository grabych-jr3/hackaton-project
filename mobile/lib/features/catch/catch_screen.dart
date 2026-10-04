import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/catch_repository.dart';
import '../../data/repositories/places_repository.dart';
import '../game/game_models.dart';
import '../game/game_providers.dart';
import '../place/status_chip.dart';
import 'open_camera.dart';
import 'pending_catches.dart';

export 'open_camera.dart' show demoCameraMessage;

const currentLocationLabel = 'Obecna lokalizacja';

/// "Zgłoszenia i ankieta": camera shortcut, barrier survey and the
/// pending photo catches. The nav "Złap" button opens the camera directly;
/// long-press opens this screen.
class CatchScreen extends ConsumerStatefulWidget {
  const CatchScreen({super.key});

  @override
  ConsumerState<CatchScreen> createState() => _CatchScreenState();
}

class _CatchScreenState extends ConsumerState<CatchScreen> {
  String? _placeId;
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
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: const BorderSide(color: AppColors.borderHighlight),
        ),
        title: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.mint100,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary),
              ),
              child: Text(result.species.emoji, style: const TextStyle(fontSize: 48)),
            ),
            const SizedBox(height: 12),
            Text(
              'Złapano: ${result.species.name}!',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                '${result.species.rarity.label} · Wartość: ${result.points} pkt — sprzedaj w Kolekcji',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Zgłoszenie niezweryfikowane — trafi na mapę po potwierdzeniu przez innych użytkowników.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(160, 46),
              backgroundColor: AppColors.primary,
              foregroundColor: const Color(0xFF090D12),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Do kolekcji'),
          ),
        ],
      ),
    );

    if (mounted) _reset();
  }

  @override
  Widget build(BuildContext context) {
    final points = ref.watch(gameProvider).value?.points;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Zgłoszenia i ankieta')),
      body: Column(
        children: [
          Expanded(child: _buildManualSurveyView(points)),
          const PendingCatchesSection(),
        ],
      ),
    );
  }

  /// Detailed Manual Survey Fallback
  Widget _buildManualSurveyView(int? points) {
    final theme = Theme.of(context);
    final places = ref.watch(placesProvider).value ?? const [];

    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
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
                selectedColor: AppColors.mint100,
                backgroundColor: AppColors.surfaceElevated,
                side: BorderSide(color: v == value ? AppColors.primary : AppColors.border),
                labelStyle: TextStyle(
                  color: v == value ? AppColors.primary : AppColors.text,
                  fontWeight: FontWeight.w600,
                ),
                onSelected: (_) => setState(() => onChanged(v)),
              ),
          ],
        );

    Widget check(String label, bool value, ValueChanged<bool> onChanged) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(label, style: const TextStyle(color: AppColors.text)),
          value: value,
          activeColor: AppColors.primary,
          checkColor: const Color(0xFF090D12),
          onChanged: (v) => setState(() => onChanged(v ?? false)),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            const DemoBadge(),
            if (points != null)
              Text(
                'Saldo: $points pkt',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
          ],
        ),
        if (ref.watch(catchRepositoryProvider) == null) ...[
          const SizedBox(height: 12),
          const Row(
            children: [
              Icon(Icons.no_photography_outlined, color: AppColors.warn, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text(demoCameraMessage,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 12),
          Semantics(
            label: 'Otwórz kamerę AR i złap stworka',
            button: true,
            excludeSemantics: true,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: AppColors.primary,
                foregroundColor: const Color(0xFF090D12),
              ),
              onPressed: () => openCatchCamera(context, ref, placeId: _placeId),
              icon: const Icon(Icons.camera_alt_rounded),
              label: const Text('Otwórz aparat'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
          ),
          child: const Row(
            children: [
              Icon(Icons.fact_check_outlined, color: AppColors.primary),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Zgłoś barierę w ankiecie i złap stworka. Im dokładniejsze zgłoszenie, tym rzadszy stworek.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        section('Miejsce'),
        DropdownButtonFormField<String?>(
          initialValue: _placeId,
          isExpanded: true,
          dropdownColor: AppColors.surfaceElevated,
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
              const Text('Liczba stopni:', style: TextStyle(color: AppColors.textMuted)),
              IconButton(
                tooltip: 'Mniej stopni',
                onPressed: _steps > 1 ? () => setState(() => _steps--) : null,
                icon: const Icon(Icons.remove_circle_outline, color: AppColors.primary),
              ),
              Text('$_steps',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              IconButton(
                tooltip: 'Więcej stopni',
                onPressed: () => setState(() => _steps++),
                icon: const Icon(Icons.add_circle_outline, color: AppColors.primary),
              ),
            ],
          ),
        check('Brak podjazdu / rampy', _noRamp, (v) => _noRamp = v),
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
        section('Szerokość przejścia'),
        choices<PassageWidth>(
          const [
            (PassageWidth.none, 'Brak danych'),
            (PassageWidth.wide, '> 90 cm'),
            (PassageWidth.medium, '70–90 cm'),
            (PassageWidth.narrow, '< 70 cm'),
          ],
          _passage,
          (v) => _passage = v,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: AppColors.primary,
            foregroundColor: const Color(0xFF090D12),
          ),
          onPressed: _report.isEmpty || _sending || points == null ? null : _submit,
          icon: const Icon(Icons.send_rounded),
          label: const Text('Wyślij zgłoszenie i złap'),
        ),
      ],
    );
  }
}

