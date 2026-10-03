import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/offline_banner.dart';
import '../../data/models/place.dart';
import '../place/place_labels.dart';
import '../place/place_providers.dart';
import '../place/places_list.dart';
import '../place/status_chip.dart';
import '../route/route_panel.dart';
import '../route/route_service.dart';
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
  _MapStyle _style = _MapStyle.dark;
  LatLng? _myLocation;
  bool _locating = false;
  bool _routeCollapsed = false;

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

  Future<void> _planRoute(Place place) async {
    setState(() => _routeCollapsed = false);
    await ref.read(routeProvider.notifier).plan(place, myLocation: _myLocation);
    final points = ref.read(routeProvider).value?.points;
    if (!mounted || points == null || points.length < 2) return;
    _mapController.fitCamera(CameraFit.coordinates(
      coordinates: points,
      padding: const EdgeInsets.fromLTRB(40, 160, 40, 380),
    ));
  }

  void _select(Place place) {
    setState(() => _selected = place);
    _mapController.move(LatLng(place.lat, place.lng), 16);
  }

  @override
  Widget build(BuildContext context) {
    final route = ref.watch(routeProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.mint100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.mint300),
              ),
              child: const Icon(Icons.explore_rounded, color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'Kraków bez barier',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              backgroundColor: AppColors.surfaceElevated,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppColors.border),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onPressed: () => setState(() {
              _showList = !_showList;
              _selected = null;
            }),
            icon: Icon(_showList ? Icons.map_rounded : Icons.view_list_rounded, size: 18),
            label: Text(_showList ? 'Mapa' : 'Lista'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _showList
          ? Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: _FloatingSearchIsland(onSubmitted: null),
                ),
                const OfflineBanner(),
                const Expanded(child: PlacesList()),
              ],
            )
          : Stack(
              children: [
                // 1. Interactive Map
                Positioned.fill(
                  child: _PlacesMap(
                    controller: _mapController,
                    style: _style,
                    myLocation: _myLocation,
                    selected: _selected,
                    onSelect: _select,
                    onTapMap: () => setState(() => _selected = null),
                  ),
                ),

                // 2. Floating Top Search & Filter Island
                Positioned(
                  top: 12,
                  left: 16,
                  right: 16,
                  child: _FloatingSearchIsland(onSubmitted: _select),
                ),

                // Offline notice (API mode, server unreachable).
                const Positioned(
                  top: 112,
                  left: 16,
                  right: 72,
                  child: Align(alignment: Alignment.topLeft, child: OfflineBanner()),
                ),

                // 3. Floating Map Controls (Right Side)
                Positioned(
                  top: 150,
                  right: 16,
                  child: Column(
                    children: [
                      _GlassMapButton(
                        tooltip: _style == _MapStyle.dark
                            ? 'Widok uliczny'
                            : (_style == _MapStyle.streets
                                ? 'Widok satelitarny'
                                : 'Tryb ciemny'),
                        icon: _style == _MapStyle.dark
                            ? Icons.dark_mode_rounded
                            : (_style == _MapStyle.streets
                                ? Icons.map_rounded
                                : Icons.satellite_alt_rounded),
                        onPressed: () => setState(() {
                          if (_style == _MapStyle.dark) {
                            _style = _MapStyle.streets;
                          } else if (_style == _MapStyle.streets) {
                            _style = _MapStyle.satellite;
                          } else {
                            _style = _MapStyle.dark;
                          }
                        }),
                      ),
                      const SizedBox(height: 10),
                      _GlassMapButton(
                        tooltip: 'Moja lokalizacja',
                        icon: Icons.my_location_rounded,
                        isLoading: _locating,
                        onPressed: _locating ? null : _locate,
                      ),
                    ],
                  ),
                ),

                // 4. Route panel (text list of segments) or place preview
                if (route.isLoading)
                  const Positioned(
                    left: 16,
                    right: 16,
                    bottom: 96,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (route.value != null &&
                    (!_routeCollapsed || _selected == null))
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 96,
                    child: _routeCollapsed
                        ? RouteCollapsedBar(
                            route: route.value!,
                            onExpand: () => setState(() => _routeCollapsed = false),
                            onClear: () => ref.read(routeProvider.notifier).clear(),
                          )
                        : RoutePanel(
                            route: route.value!,
                            onClose: () => setState(() {
                              _routeCollapsed = true;
                              _selected = null;
                            }),
                          ),
                  )
                else if (_selected != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 96, // Above floating bottom nav
                    child: _PlacePreview(
                      place: _selected!,
                      onClose: () => setState(() => _selected = null),
                      onRoute: () => _planRoute(_selected!),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _FloatingSearchIsland extends ConsumerWidget {
  const _FloatingSearchIsland({required this.onSubmitted});

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
            avatar: Icon(icon, size: 16, color: value ? AppColors.primary : AppColors.textMuted),
            label: Text(label),
            selected: value,
            showCheckmark: false,
            backgroundColor: AppColors.surfaceElevated,
            selectedColor: AppColors.mint100,
            side: BorderSide(color: value ? AppColors.primary : AppColors.border),
            labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: value ? AppColors.primary : AppColors.text,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            onSelected: (v) => notifier.update((f) => change(f, v)),
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceGlass,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.border, width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search input
              Row(
                children: [
                  const Icon(Icons.search_rounded, color: AppColors.primary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Gdzie chcesz iść? Szukaj w Krakowie...',
                        hintStyle: TextStyle(color: AppColors.textDim, fontSize: 14),
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                      style: const TextStyle(fontSize: 14, color: AppColors.text),
                      textInputAction: TextInputAction.search,
                      onChanged: (q) => notifier.update((f) => f.copyWith(query: q)),
                      onSubmitted: (_) {
                        final first = ref.read(filteredPlacesProvider).value?.firstOrNull;
                        if (first != null) onSubmitted?.call(first);
                      },
                    ),
                  ),
                  // Crowd status indicator (Live crowd HUD)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.mint100,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.mint300),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(color: AppColors.primary, blurRadius: 6),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Ruch: Mały',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Filter chips row
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    chip('Pasujące do mnie', Icons.accessible_rounded, filters.onlyMatching,
                        (f, v) => f.copyWith(onlyMatching: v)),
                    chip('Toaleta', Icons.wc_rounded, filters.toilet,
                        (f, v) => f.copyWith(toilet: v)),
                    chip('Ławki', Icons.chair_rounded, filters.benches,
                        (f, v) => f.copyWith(benches: v)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassMapButton extends StatelessWidget {
  const _GlassMapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isLoading = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: AppColors.surfaceGlass,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.border, width: 1.2),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onPressed,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Tooltip(
                message: tooltip,
                child: Center(
                  child: isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        )
                      : Icon(icon, color: AppColors.primary, size: 22),
                ),
              ),
            ),
          ),
        ),
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
    final routePoints =
        ref.watch(routeProvider).value?.points ?? const <LatLng>[];

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
        // 1. Map Tiles
        TileLayer(
          key: ValueKey(style),
          urlTemplate: style.urlTemplate,
          retinaMode: style.retina && RetinaMode.isHighDensity(context),
          maxNativeZoom: style.maxNativeZoom,
          userAgentPackageName: 'pl.krakowbezbarier.app',
          tileProvider: kIsWeb ? _PlainWebTileProvider() : NetworkTileProvider(),
        ),
        if (style.labelsUrl != null)
          TileLayer(
            key: ValueKey('${style.name}-labels'),
            urlTemplate: style.labelsUrl,
            maxNativeZoom: style.maxNativeZoom,
            userAgentPackageName: 'pl.krakowbezbarier.app',
            tileProvider: kIsWeb ? _PlainWebTileProvider() : NetworkTileProvider(),
          ),

        // 2. Planned accessible route (ORS or labelled demo)
        if (routePoints.length > 1)
        PolylineLayer(
          polylines: [
            // Outer glow line
            Polyline(
              points: routePoints,
              strokeWidth: 8.0,
              color: AppColors.primary.withValues(alpha: 0.35),
              strokeCap: StrokeCap.round,
              strokeJoin: StrokeJoin.round,
            ),
            // Inner crisp core line
            Polyline(
              points: routePoints,
              strokeWidth: 3.5,
              color: AppColors.primaryBright,
              strokeCap: StrokeCap.round,
              strokeJoin: StrokeJoin.round,
            ),
          ],
        ),

        // 3. User Location Marker
        if (myLocation != null)
          MarkerLayer(markers: [
            Marker(
              point: myLocation!,
              width: 32,
              height: 32,
              child: Semantics(
                label: 'Twoja lokalizacja',
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.accentCyan,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3.5),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accentCyan.withValues(alpha: 0.6),
                        blurRadius: 14,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(Icons.navigation_rounded, color: Colors.black, size: 14),
                  ),
                ),
              ),
            ),
          ]),

        // 4. Place Markers with Accessibility Badges
        MarkerLayer(
          markers: [
            for (final place in places)
              Marker(
                point: LatLng(place.lat, place.lng),
                width: 52,
                height: 52,
                child: _PlaceMarker(
                  place: place,
                  selected: place.id == selected?.id,
                  onTap: () => onSelect(place),
                ),
              ),
          ],
        ),

        // 5. Attribution
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
          alignment: Alignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: selected ? 46 : 38,
              height: selected ? 46 : 38,
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.primaryBright : color,
                  width: selected ? 3.0 : 2.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: (selected ? AppColors.primary : color).withValues(alpha: 0.4),
                    blurRadius: selected ? 12 : 6,
                    spreadRadius: selected ? 2 : 0,
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  place.category.icon,
                  size: selected ? 22 : 18,
                  color: selected ? AppColors.primary : AppColors.text,
                ),
              ),
            ),
            if (style != null)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.background, width: 1.5),
                    boxShadow: [
                      BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4),
                    ],
                  ),
                  child: Icon(style.icon, size: 10, color: Colors.black),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlacePreview extends ConsumerWidget {
  const _PlacePreview({
    required this.place,
    required this.onClose,
    required this.onRoute,
  });

  final Place place;
  final VoidCallback onClose;
  final VoidCallback onRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final match = ref.watch(placeMatchProvider(place));
    final text = Theme.of(context).textTheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 16),
          decoration: BoxDecoration(
            color: AppColors.surfaceGlass,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.border, width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x77000000),
                blurRadius: 30,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.mint100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(place.category.icon, color: AppColors.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.text,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (place.address != null)
                          Text(
                            place.address!,
                            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
                    tooltip: 'Zamknij',
                  ),
                ],
              ),
              const SizedBox(height: 10),
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
                  style: text.bodySmall?.copyWith(color: AppColors.bad),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onRoute,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        foregroundColor: AppColors.primary,
                        side: const BorderSide(color: AppColors.primary),
                      ),
                      icon: const Icon(Icons.route_rounded, size: 18),
                      label: const Text('Trasa'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: () => context.push('/place/${place.id}'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: AppColors.primary,
                        foregroundColor: const Color(0xFF090D12),
                      ),
                      icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                      label: const Text('Szczegóły dostępności',
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlainWebTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      NetworkImage(getTileUrl(coordinates, options));
}

/// Base map tile styles
enum _MapStyle {
  dark(
    'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
    ['Esri, HERE, Garmin, OpenStreetMap contributors'],
    retina: false,
    maxNativeZoom: 16,
    labelsUrl:
        'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}',
  ),
  streets(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
    ['Esri, HERE, Garmin, OpenStreetMap contributors'],
    retina: false,
    maxNativeZoom: 19,
  ),
  satellite(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    ['Esri, Maxar, Earthstar Geographics'],
    retina: false,
    maxNativeZoom: 19,
  );

  const _MapStyle(this.urlTemplate, this.attributions,
      {required this.retina, required this.maxNativeZoom, this.labelsUrl});

  /// Optional transparent labels layer drawn over the base tiles.
  final String? labelsUrl;

  final String urlTemplate;
  final List<String> attributions;
  final bool retina;
  final int maxNativeZoom;
}
