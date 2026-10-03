import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/accessibility_fact.dart';
import '../../data/models/place.dart';
import '../../domain/profile_match.dart';
import 'place_labels.dart';
import 'place_providers.dart';
import 'status_chip.dart';

class PlaceDetailScreen extends ConsumerWidget {
  const PlaceDetailScreen({super.key, required this.placeId});

  final String placeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeAsync = ref.watch(placeByIdProvider(placeId));

    return Scaffold(
      appBar: AppBar(title: const Text('Szczegóły miejsca')),
      body: placeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(child: Text('Nie udało się wczytać danych.')),
        data: (place) => place == null
            ? const Center(child: Text('Nie znaleziono miejsca.'))
            : _PlaceDetail(place: place),
      ),
    );
  }
}

class _PlaceDetail extends ConsumerWidget {
  const _PlaceDetail({required this.place});

  final Place place;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider)();
    final match = ref.watch(placeMatchProvider(place));
    final text = Theme.of(context).textTheme;
    final conflicts =
        Feature.values.where((f) => place.hasConflict(f, now)).toList();

    final presentFeatures =
        Feature.values.where((f) => f.isBarrier || place.factsFor(f).isNotEmpty);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Row(
          children: [
            Icon(place.category.icon, size: 18, color: AppColors.textMuted),
            const SizedBox(width: 6),
            Text(place.category.label,
                style: text.labelLarge?.copyWith(color: AppColors.textMuted)),
            const Spacer(),
            if (place.isDemo) const DemoBadge(),
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          header: true,
          child: Text(place.name,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        ),
        if (place.address != null)
          Text(place.address!,
              style: text.bodyMedium?.copyWith(color: AppColors.textMuted)),
        const SizedBox(height: 16),
        if (match != null) _VerdictCard(match: match),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ConflictBanner(features: conflicts),
        ],
        const SizedBox(height: 20),
        const _SectionTitle('Bariery'),
        for (final f in presentFeatures.where((f) => f.isBarrier))
          _FeatureCard(place: place, feature: f, match: match, now: now),
        const SizedBox(height: 12),
        const _SectionTitle('Udogodnienia'),
        if (presentFeatures.every((f) => f.isBarrier))
          const _EmptyNote('Brak informacji o udogodnieniach.')
        else
          for (final f in presentFeatures.where((f) => !f.isBarrier))
            _FeatureCard(place: place, feature: f, match: match, now: now),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _soon(context),
                icon: const Icon(Icons.thumb_up_outlined),
                label: const Text('Potwierdź'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _soon(context),
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Zgłoś błąd'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Informacje niepotwierdzone nie stanowią formalnego zapewnienia dostępności. '
          'Mapa i część danych: © OpenStreetMap contributors (ODbL).',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }

  void _soon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Zgłoszenia będą dostępne w pełnej wersji.')),
    );
  }
}

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.match});

  final PlaceMatch match;

  @override
  Widget build(BuildContext context) {
    final style = match.verdict.style;
    final text = Theme.of(context).textTheme;

    final reasons = <String>[
      for (final c in match.problems)
        '${c.feature.label}: ${c.fact == null ? '' : c.feature.formatValue(c.fact!.value)} — ${c.status.style.label.toLowerCase()}',
      for (final c in match.missing) 'Brak danych: ${c.feature.label.toLowerCase()}',
    ];

    return Semantics(
      container: true,
      label: 'Ocena dla Twojego profilu: ${style.label}. ${reasons.join('. ')}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: style.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: style.color.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Dla Twojego profilu',
                style: text.labelMedium?.copyWith(color: AppColors.textMuted)),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(style.icon, color: style.color, size: 28),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(style.label,
                      style: text.titleLarge?.copyWith(
                          color: style.color, fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            for (final r in reasons) ...[
              const SizedBox(height: 6),
              Text('• $r', style: text.bodyMedium),
            ],
            if (match.verdict == Verdict.insufficientData) ...[
              const SizedBox(height: 8),
              Text('Brak danych nie oznacza, że miejsce jest dostępne.',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner({required this.features});

  final List<Feature> features;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.badBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber, color: AppColors.bad),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Dane sprzeczne (${features.map((f) => f.label.toLowerCase()).join(', ')}) — sprawdź przed wizytą.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.bad, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.place,
    required this.feature,
    required this.match,
    required this.now,
  });

  final Place place;
  final Feature feature;
  final PlaceMatch? match;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final facts = place.factsFor(feature);
    final check = match?.checks.where((c) => c.feature == feature).firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(feature.icon, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(feature.label,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (check != null) StatusChip(check.status.style, dense: true),
                ],
              ),
              if (check?.note != null) ...[
                const SizedBox(height: 6),
                Text(check!.note!, style: text.bodySmall),
              ],
              const SizedBox(height: 8),
              if (facts.isEmpty)
                Text('Brak danych', style: text.bodyMedium?.copyWith(color: AppColors.unknown))
              else
                for (final fact in facts) _FactRow(feature: feature, fact: fact, now: now),
            ],
          ),
        ),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.feature, required this.fact, required this.now});

  final Feature feature;
  final AccessibilityFact fact;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dateLabel = fact.confirmedAt != null ? 'potwierdzono' : 'pobrano';
    final confirmations =
        fact.confirmations > 0 ? ' · potwierdzeń: ${fact.confirmations}' : '';

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(feature.formatValue(fact.value),
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fact.source.label, style: text.bodyMedium),
                Text('$dateLabel ${formatDate(fact.lastVerified)}$confirmations',
                    style: text.bodySmall?.copyWith(color: AppColors.textMuted)),
                const SizedBox(height: 4),
                StatusChip(fact.trustAt(now).style, dense: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        header: true,
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: Theme.of(context)
          .textTheme
          .bodyMedium
          ?.copyWith(color: AppColors.unknown));
}
