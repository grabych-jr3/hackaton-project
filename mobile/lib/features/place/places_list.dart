import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/place.dart';
import '../../data/repositories/places_repository.dart';
import 'place_labels.dart';
import 'place_providers.dart';
import 'status_chip.dart';

/// Text alternative to the map (WCAG): every place with its verdict.
class PlacesList extends ConsumerWidget {
  const PlacesList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(placesProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              const Center(child: Text('Nie udało się wczytać miejsc.')),
          data: (places) => ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: places.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              if (i == 0) {
                return places.any((p) => p.isDemo)
                    ? const Align(alignment: Alignment.centerLeft, child: DemoBadge())
                    : const SizedBox.shrink();
              }
              return _PlaceTile(place: places[i - 1]);
            },
          ),
        );
  }
}

class _PlaceTile extends ConsumerWidget {
  const _PlaceTile({required this.place});

  final Place place;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final match = ref.watch(placeMatchProvider(place));
    final text = Theme.of(context).textTheme;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push('/place/${place.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.mint100,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(place.category.icon, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(place.name,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text(place.category.label,
                        style: text.bodySmall?.copyWith(color: AppColors.textMuted)),
                    if (match != null) ...[
                      const SizedBox(height: 6),
                      StatusChip(match.verdict.style, dense: true),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
