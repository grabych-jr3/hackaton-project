import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/place.dart';
import '../place/place_labels.dart';
import '../place/place_providers.dart';
import '../place/places_list.dart';
import '../place/status_chip.dart';
import 'place_filters.dart';

const _krakowCenter = LatLng(50.0590, 19.9390);

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _mapController = MapController();
  bool _showList = false;
  Place? _selected;

  void _select(Place place) {
    setState(() => _selected = place);
    _mapController.move(LatLng(place.lat, place.lng), 16);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mapa'),
        actions: [
          TextButton.icon(
            onPressed: () => setState(() {
              _showList = !_showList;
              _selected = null;
            }),
            icon: Icon(_showList ? Icons.map_outlined : Icons.list),
            label: Text(_showList ? 'Mapa' : 'Lista'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _SearchAndFilters(onSubmitted: _showList ? null : _select),
          Expanded(
            child: _showList
                ? const PlacesList()
                : Stack(
                    children: [
                      _PlacesMap(
                        controller: _mapController,
                        selected: _selected,
                        onSelect: _select,
                        onTapMap: () => setState(() => _selected = null),
                      ),
                      if (_selected != null)
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 12,
                          child: _PlacePreview(
                            place: _selected!,
                            onClose: () => setState(() => _selected = null),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SearchAndFilters extends ConsumerWidget {
  const _SearchAndFilters({required this.onSubmitted});

  /// On the map view, submitting the search jumps to the first result.
  final ValueChanged<Place>? onSubmitted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(placeFiltersProvider);
    final notifier = ref.read(placeFiltersProvider.notifier);

    Widget chip(String label, IconData icon, bool value,
            PlaceFilters Function(PlaceFilters, bool) change) =>
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilterChip(
            avatar: Icon(icon, size: 18),
            label: Text(label),
            selected: value,
            showCheckmark: false,
            onSelected: (v) => notifier.update((f) => change(f, v)),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        children: [
          TextField(
            decoration: InputDecoration(
              hintText: 'Szukaj miejsca w Krakowie',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: AppColors.surface,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: AppColors.border),
              ),
            ),
            textInputAction: TextInputAction.search,
            onChanged: (q) => notifier.update((f) => f.copyWith(query: q)),
            onSubmitted: (_) {
              final first = ref.read(filteredPlacesProvider).value?.firstOrNull;
              if (first != null) onSubmitted?.call(first);
            },
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                chip('Pasujące do mnie', Icons.accessible, filters.onlyMatching,
                    (f, v) => f.copyWith(onlyMatching: v)),
                chip('Toaleta', Icons.wc, filters.toilet,
                    (f, v) => f.copyWith(toilet: v)),
                chip('Ławki', Icons.chair_outlined, filters.benches,
                    (f, v) => f.copyWith(benches: v)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlacesMap extends ConsumerWidget {
  const _PlacesMap({
    required this.controller,
    required this.selected,
    required this.onSelect,
    required this.onTapMap,
  });

  final MapController controller;
  final Place? selected;
  final ValueChanged<Place> onSelect;
  final VoidCallback onTapMap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(filteredPlacesProvider).value ?? const [];

    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: _krakowCenter,
        initialZoom: 14.5,
        minZoom: 11,
        maxZoom: 19,
        onTap: (_, _) => onTapMap(),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'pl.krakowbezbarier.app',
        ),
        MarkerLayer(
          markers: [
            for (final place in places)
              Marker(
                point: LatLng(place.lat, place.lng),
                width: 48,
                height: 48,
                child: _PlaceMarker(
                  place: place,
                  selected: place.id == selected?.id,
                  onTap: () => onSelect(place),
                ),
              ),
          ],
        ),
        const RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [TextSourceAttribution('OpenStreetMap contributors')],
        ),
      ],
    );
  }
}

class _PlaceMarker extends ConsumerWidget {
  const _PlaceMarker({
    required this.place,
    required this.selected,
    required this.onTap,
  });

  final Place place;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verdict = ref.watch(placeMatchProvider(place))?.verdict;
    final style = verdict?.style;
    final color = style?.color ?? AppColors.unknown;

    return Semantics(
      button: true,
      label: '${place.name}: ${style?.label ?? 'brak oceny'}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: EdgeInsets.all(selected ? 0 : 4),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: selected ? 4 : 3),
                boxShadow: const [
                  BoxShadow(color: Color(0x330F1F1A), blurRadius: 6, offset: Offset(0, 2)),
                ],
              ),
              child: Center(
                child: Icon(place.category.icon, size: 20, color: AppColors.text),
              ),
            ),
            if (style != null)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Icon(style.icon, size: 12, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlacePreview extends ConsumerWidget {
  const _PlacePreview({required this.place, required this.onClose});

  final Place place;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final match = ref.watch(placeMatchProvider(place));
    final text = Theme.of(context).textTheme;

    return Material(
      color: AppColors.background,
      elevation: 6,
      shadowColor: const Color(0x330E7A5A),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(place.category.icon, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(place.name,
                      style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                ),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                  tooltip: 'Zamknij',
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (match != null) StatusChip(match.verdict.style, dense: true),
                if (place.isDemo) const DemoBadge(),
              ],
            ),
            if (match != null && match.problems.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                match.problems
                    .map((c) => '${c.feature.label}: ${c.status.style.label.toLowerCase()}')
                    .join(' · '),
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
            ],
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: () => context.push('/place/${place.id}'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('Szczegóły dostępności'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
