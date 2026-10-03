import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
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
  _MapStyle _style = _MapStyle.streets;
  LatLng? _myLocation;
  bool _locating = false;

  Future<void> _locate() async {
    final messenger = ScaffoldMessenger.of(context);
    void fail(String msg) =>
        messenger.showSnackBar(SnackBar(content: Text(msg)));

    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return fail('Włącz lokalizację w urządzeniu.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return fail('Brak zgody na lokalizację.');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final here = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() => _myLocation = here);
      _mapController.move(here, 16);
    } catch (_) {
      fail('Nie udało się ustalić lokalizacji.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

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
                        style: _style,
                        myLocation: _myLocation,
                        selected: _selected,
                        onSelect: _select,
                        onTapMap: () => setState(() => _selected = null),
                      ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Column(
                          children: [
                            FloatingActionButton.small(
                              heroTag: 'layers',
                              backgroundColor: AppColors.background,
                              foregroundColor: AppColors.primary,
                              tooltip: _style == _MapStyle.streets
                                  ? 'Widok satelitarny'
                                  : 'Widok mapy',
                              onPressed: () => setState(() => _style =
                                  _style == _MapStyle.streets
                                      ? _MapStyle.satellite
                                      : _MapStyle.streets),
                              child: Icon(_style == _MapStyle.streets
                                  ? Icons.satellite_alt_outlined
                                  : Icons.map_outlined),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: 'locate',
                              backgroundColor: AppColors.background,
                              foregroundColor: AppColors.primary,
                              tooltip: 'Moja lokalizacja',
                              onPressed: _locating ? null : _locate,
                              child: _locating
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.my_location),
                            ),
                          ],
                        ),
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
    required this.style,
    required this.myLocation,
    required this.selected,
    required this.onSelect,
    required this.onTapMap,
  });

  final MapController controller;
  final _MapStyle style;
  final LatLng? myLocation;
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
          key: ValueKey(style),
          urlTemplate: style.urlTemplate,
          retinaMode: style.retina && RetinaMode.isHighDensity(context),
          maxNativeZoom: style.maxNativeZoom,
          userAgentPackageName: 'pl.krakowbezbarier.app',
          tileProvider: kIsWeb ? _PlainWebTileProvider() : NetworkTileProvider(),
        ),
        if (myLocation != null)
          MarkerLayer(markers: [
            Marker(
              point: myLocation!,
              width: 28,
              height: 28,
              child: Semantics(
                label: 'Twoja lokalizacja',
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A73E8),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    boxShadow: const [
                      BoxShadow(color: Color(0x551A73E8), blurRadius: 12, spreadRadius: 4),
                    ],
                  ),
                ),
              ),
            ),
          ]),
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
        RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [
            for (final a in style.attributions) TextSourceAttribution(a),
          ],
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

/// On web, custom headers (User-Agent) trigger a CORS preflight that the
/// OSM tile server rejects, so tiles are loaded as plain images.
class _PlainWebTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      NetworkImage(getTileUrl(coordinates, options));
}

/// Base layers. Streets: Stadia OSM Bright (colored, free on localhost; a
/// deployed web domain must be registered at stadiamaps.com). Satellite: Esri
/// World Imagery (attribution required).
enum _MapStyle {
  streets(
    'https://tiles.stadiamaps.com/tiles/osm_bright/{z}/{x}/{y}{r}.png',
    ['OpenStreetMap contributors', 'Stadia Maps', 'OpenMapTiles'],
    retina: true,
    maxNativeZoom: 20,
  ),
  satellite(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    ['Esri, Maxar, Earthstar Geographics'],
    retina: false,
    maxNativeZoom: 19,
  );

  const _MapStyle(this.urlTemplate, this.attributions,
      {required this.retina, required this.maxNativeZoom});

  final String urlTemplate;
  final List<String> attributions;
  final bool retina;
  final int maxNativeZoom;
}
