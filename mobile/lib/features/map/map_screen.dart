import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/offline_banner.dart';
import '../../data/models/accessibility_fact.dart';
import '../../data/models/crowd.dart';
import '../../data/repositories/crowd_repository.dart';
import '../game/game_providers.dart';
import '../../data/models/place.dart';
import '../place/place_labels.dart';
import '../place/place_providers.dart';
import '../place/places_list.dart';
import '../place/status_chip.dart';
import '../route/route_layer.dart';
import '../route/route_panel.dart';
import '../route/route_service.dart';
import '../route/route_start.dart';
import '../spawns/spawn.dart';
import '../spawns/spawn_providers.dart';
import '../spawns/spawn_widgets.dart';
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
  bool _locating = false;
  bool _routeCollapsed = false;
  StreamSubscription<Position>? _posSub;
<<<<<<< Updated upstream
  bool _spawning = false;
  Timer? _bboxDebounce;
=======
  List<CrowdCell> _crowd = const [];
  Timer? _crowdDebounce;
  Timer? _crowdRefresh;
  bool _reporting = false;

  @override
  void initState() {
    super.initState();
    _crowdRefresh = Timer.periodic(
        const Duration(minutes: 5), (_) => _loadCrowd());
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCrowd());
  }
>>>>>>> Stashed changes

  @override
  void dispose() {
    _posSub?.cancel();
<<<<<<< Updated upstream
    _bboxDebounce?.cancel();
=======
    _crowdDebounce?.cancel();
    _crowdRefresh?.cancel();
>>>>>>> Stashed changes
    super.dispose();
  }

  /// Fetches crowd cells for the visible area (the layer is always shown).
  Future<void> _loadCrowd() async {
    final repo = ref.read(crowdRepositoryProvider);
    if (repo == null || !mounted) return;
    final LatLngBounds b;
    try {
      b = _mapController.camera.visibleBounds;
    } catch (_) {
      return; // map not rendered yet
    }
    try {
      final cells = await repo.getCells(
          minLat: b.south, minLng: b.west, maxLat: b.north, maxLng: b.east);
      if (mounted) setState(() => _crowd = cells);
    } catch (_) {
      // Keep the previous layer on network/API errors.
    }
  }

  void _onMapMoved() {
    _crowdDebounce?.cancel();
    _crowdDebounce = Timer(const Duration(milliseconds: 600), _loadCrowd);
  }

  /// "Jak tłoczno?" — rates the crowd at the user's location.
  Future<void> _askCrowd() async {
    final repo = ref.read(crowdRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    void say(String msg) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
    if (repo == null) {
      return say('Ocena tłoku wymaga połączenia z serwerem.');
    }
    final level = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surfaceElevated,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Jak tłoczno tutaj?',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final (i, label, color) in const [
              (0, 'Luźno', Color(0xFF2E7D32)),
              (1, 'Średnio', Color(0xFFFFA000)),
              (2, 'Tłoczno', Color(0xFFD32F2F)),
            ])
              ListTile(
                leading: Icon(Icons.circle, color: color),
                title: Text(label),
                onTap: () => Navigator.of(context).pop(i),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (level == null || !mounted) return;
    var loc = ref.read(userLocationProvider);
    if (loc == null) {
      await _locate();
      if (!mounted) return;
      loc = ref.read(userLocationProvider);
    }
    // Outside Kraków (e.g. testing from home): rate the place in the middle of the map instead.
    final point = loc == null || loc.isFarFromKrakow
        ? _mapController.camera.center
        : loc.point;
    setState(() => _reporting = true);
    try {
      final res = await repo.report(point, level);
      if (!mounted) return;
      if (res.awarded > 0) ref.invalidate(gameProvider);
      say(res.awarded > 0
          ? 'Dzięki za ocenę! +${res.awarded} pkt'
          : 'Dzięki za ocenę!');
      _loadCrowd();
    } on CrowdReportException catch (e) {
      say(e.message);
    } catch (_) {
      say('Nie udało się wysłać oceny. Spróbuj ponownie.');
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  /// High-accuracy settings per platform (desktop browsers may still
  /// geolocate by Wi-Fi/IP — accuracy is shown and checked).
  static LocationSettings _settings({int distanceFilter = 0}) {
    if (kIsWeb) {
      return WebSettings(
        accuracy: LocationAccuracy.high,
        maximumAge: Duration.zero,
        timeLimit: const Duration(seconds: 15),
        distanceFilter: distanceFilter,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        forceLocationManager: false,
        distanceFilter: distanceFilter,
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: distanceFilter,
    );
  }

  void _announce(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Semantics(liveRegion: true, child: Text(msg)),
        duration: const Duration(seconds: 6),
      ));
    SemanticsService.sendAnnouncement(
        View.of(context), msg, Directionality.of(context));
  }

  void _setPosition(Position pos) {
    ref.read(userLocationProvider.notifier).set(UserLocation(
        LatLng(pos.latitude, pos.longitude),
        accuracyM: pos.accuracy));
  }

  /// Warns about an inaccurate or far-away fix (Polish, announced).
  void _warnAboutLocation(UserLocation loc) {
    if (loc.isFarFromKrakow) {
      _announce('Jesteś poza Krakowem — trasa zacznie się od Rynku Głównego. '
          'Przytrzymaj mapę, aby wybrać start.');
    } else if (loc.accuracyM > warnAccuracyM) {
      _announce('Lokalizacja niedokładna (${formatAccuracy(loc.accuracyM)}). '
          'Przytrzymaj mapę, aby ustawić start.');
    }
  }

  void _setManualStart(LatLng point) {
    ref.read(manualStartProvider.notifier).set(point);
    ref.read(startPreferenceProvider.notifier).set(StartPreference.auto);
    _announce('Start ustawiony');
    ref.read(routeProvider.notifier).replan();
  }

  void _clearManualStart() {
    ref.read(manualStartProvider.notifier).clear();
    ref.read(startPreferenceProvider.notifier).set(StartPreference.auto);
    ref.read(routeProvider.notifier).replan();
  }

  /// Cycles Rynek → GPS → chosen point (only options that are available).
  void _cycleStart() {
    final manual = ref.read(manualStartProvider);
    final gps = ref.read(userLocationProvider);
    final options = availableStarts(manual: manual, gps: gps);
    final current = selectStart(
            manual: manual,
            gps: gps,
            preference: ref.read(startPreferenceProvider))
        .kind;
    final next = options[(options.indexOf(current) + 1) % options.length];
    ref.read(startPreferenceProvider.notifier).set(switch (next) {
      StartKind.manual => StartPreference.manual,
      StartKind.gps => StartPreference.gps,
      StartKind.rynek => StartPreference.rynek,
    });
    ref.read(routeProvider.notifier).replan();
  }

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
      final pos =
          await Geolocator.getCurrentPosition(locationSettings: _settings());
      final here = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      _setPosition(pos);
      _mapController.move(here, 16);
      _warnAboutLocation(ref.read(userLocationProvider)!);
      // Follow the user while the map is open.
      _posSub ??= Geolocator.getPositionStream(
              locationSettings: _settings(distanceFilter: 10))
          .listen((p) {
        if (mounted) _setPosition(p);
      }, onError: (_) {});
    } catch (_) {
      fail('Nie udało się ustalić lokalizacji.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// Debounced: the visible area drives which spawns are fetched.
  void _onCameraChanged(MapCamera camera) {
    _bboxDebounce?.cancel();
    _bboxDebounce = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      final b = camera.visibleBounds;
      ref.read(spawnBboxProvider.notifier).set(
          SpawnBbox(b.west, b.south, b.east, b.north));
    });
  }

  /// Test helper: places a creature next to the user's GPS position.
  Future<void> _spawnHere() async {
    if (ref.read(userLocationProvider) == null) await _locate();
    final here = ref.read(userLocationProvider)?.point;
    if (!mounted || here == null) return;
    setState(() => _spawning = true);
    try {
      final spawn =
          await ref.read(spawnsProvider.notifier).spawnHere(here);
      if (!mounted) return;
      _mapController.move(spawn.point, 17);
      _announce('Stworek pojawił się obok Ciebie — otwórz aparat');
    } catch (_) {
      if (mounted) _announce('Nie udało się postawić stworka.');
    } finally {
      if (mounted) setState(() => _spawning = false);
    }
  }

  Future<void> _planRoute(Place place) async {
    setState(() => _routeCollapsed = false);
    await ref.read(routeProvider.notifier).plan(place);
    final points = ref.read(routeProvider).value?.points;
    if (!mounted || points == null || points.length < 2) return;
    _mapController.fitCamera(CameraFit.coordinates(
      coordinates: points,
      padding: const EdgeInsets.fromLTRB(40, 160, 40, 380),
    ));
  }

  void _toggleList() => setState(() {
        _showList = !_showList;
        _selected = null;
      });

  void _select(Place place) {
    setState(() => _selected = place);
    _mapController.move(LatLng(place.lat, place.lng), 16);
  }

  @override
  Widget build(BuildContext context) {
    final route = ref.watch(routeProvider);
    final hasManualStart = ref.watch(manualStartProvider) != null;
    ref.listen(placeFiltersProvider.select((f) => f.avoidCrowds), (_, on) {
      ref.read(routeProvider.notifier).replan();
    });
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: _showList
          ? Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _FloatingSearchIsland(onSubmitted: null)),
                      const SizedBox(width: 8),
                      _GlassMapButton(
                        tooltip: 'Pokaż mapę',
                        icon: Icons.map_outlined,
                        onPressed: _toggleList,
                      ),
                    ],
                  ),
                ),
                const OfflineBanner(),
                const Expanded(
                    child: PlacesList(leading: NearbySpawnsSection())),
              ],
            )
          : Stack(
              children: [
                // 1. Interactive Map
                Positioned.fill(
                  child: _PlacesMap(
                    controller: _mapController,
                    style: _style,
                    selected: _selected,
                    onSelect: _select,
                    onTapMap: () => setState(() => _selected = null),
                    onLongPressMap: _setManualStart,
<<<<<<< Updated upstream
                    onCameraChanged: _onCameraChanged,
                    onSpawnTap: (d) => showSpawnSheet(context, d),
=======
                    crowd: _crowd,
                    onMoved: _onMapMoved,
>>>>>>> Stashed changes
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
                    crossAxisAlignment: CrossAxisAlignment.end,
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
                      const SizedBox(height: 12),
                      _GlassMapButton(
                        tooltip: 'Lista miejsc',
                        icon: Icons.castle_outlined,
                        onPressed: _toggleList,
                      ),
                      const SizedBox(height: 12),
                      _GlassMapButton(
                        tooltip: 'Moja lokalizacja',
                        icon: Icons.my_location_rounded,
                        isLoading: _locating,
                        onPressed: _locating ? null : _locate,
                      ),
                      const SizedBox(height: 12),
                      _GlassMapButton(
<<<<<<< Updated upstream
                        tooltip: 'Postaw stworka tutaj (test)',
                        icon: Icons.add_location_alt_outlined,
                        isLoading: _spawning,
                        onPressed:
                            (_spawning || _locating) ? null : _spawnHere,
=======
                        tooltip: 'Jak tłoczno?',
                        icon: Icons.groups_rounded,
                        isLoading: _reporting,
                        onPressed: _reporting ? null : _askCrowd,
>>>>>>> Stashed changes
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
                            // Shows the route the user is looking at (walking or accessible).
                            route: route.value!,
                            showBarriers: ref.watch(routeBarriersEnabledProvider),
                            showAlternative: ref.watch(showAlternativeProvider),
                            onToggleAlternative: () => ref
                                .read(alternativeChoiceProvider.notifier)
                                .state = !ref.read(showAlternativeProvider),
                            onExpand: () => setState(() => _routeCollapsed = false),
                            onClear: () => ref.read(routeProvider.notifier).clear(),
                          )
                        : RoutePanel(
                            route: route.value!,
                            showBarriers: ref.watch(routeBarriersEnabledProvider),
                            onClose: () => setState(() {
                              _routeCollapsed = true;
                              _selected = null;
                            }),
                            onCycleStart: _cycleStart,
                            onClearManualStart:
                                hasManualStart ? _clearManualStart : null,
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
                      onClearStart: _clearManualStart,
                    ),
                  ),
              ],
            ),
      ),
    );
  }
}

class _FloatingSearchIsland extends ConsumerStatefulWidget {
  const _FloatingSearchIsland({required this.onSubmitted});

  final ValueChanged<Place>? onSubmitted;

  @override
  ConsumerState<_FloatingSearchIsland> createState() =>
      _FloatingSearchIslandState();
}

class _FloatingSearchIslandState extends ConsumerState<_FloatingSearchIsland> {
  final _controller = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  int _highlight = -1;
  bool _dismissed = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _open =>
      !_dismissed && _controller.text.trim().isNotEmpty && _focus.hasFocus;

  void _sync() {
    if (_open) {
      _portal.show();
    } else {
      _portal.hide();
    }
  }

  void _choose(Place place) {
    _controller.text = place.name;
    _controller.selection =
        TextSelection.collapsed(offset: place.name.length);
    ref
        .read(placeFiltersProvider.notifier)
        .update((f) => f.copyWith(query: place.name));
    setState(() {
      _dismissed = true;
      _highlight = -1;
    });
    _sync();
    widget.onSubmitted?.call(place);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_open) return KeyEventResult.ignored;
    final items = ref.read(searchSuggestionsProvider);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _dismissed = true);
      _sync();
      return KeyEventResult.handled;
    }
    if (items.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1) % items.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight =
          _highlight <= 0 ? items.length - 1 : _highlight - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _choose(items[_highlight.clamp(0, items.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _dropdown(BuildContext context, double width) {
    final items = ref.watch(searchSuggestionsProvider);
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomLeft,
      offset: const Offset(0, 6),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: items.isEmpty
                ? 'Podpowiedzi wyszukiwania: brak wyników'
                : 'Podpowiedzi wyszukiwania: ${items.length}',
            child: Material(
              color: AppColors.surfaceElevated,
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Brak wyników',
                          style: TextStyle(color: AppColors.textMuted)),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < items.length; i++)
                          _SuggestionRow(
                            place: items[i],
                            highlighted: i == _highlight,
                            onTap: () => _choose(items[i]),
                          ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onSubmitted = widget.onSubmitted;
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

    return CompositedTransformTarget(
      link: _link,
      child: LayoutBuilder(
        builder: (context, box) => OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => _dropdown(context, box.maxWidth),
          child: _island(filters, chip, notifier, onSubmitted),
        ),
      ),
    );
  }

  Widget _island(
    PlaceFilters filters,
    Widget Function(String, IconData, bool, PlaceFilters Function(PlaceFilters, bool)) chip,
    PlaceFiltersNotifier notifier,
    ValueChanged<Place>? onSubmitted,
  ) {
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
                      controller: _controller,
                      focusNode: _focus,
                      onTapOutside: (_) {
                        _focus.unfocus();
                        _sync();
                      },
                      onTap: () {
                        setState(() => _dismissed = false);
                        _sync();
                      },
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
                      onChanged: (q) {
                        notifier.update((f) => f.copyWith(query: q));
                        setState(() {
                          _dismissed = false;
                          _highlight = -1;
                        });
                        _sync();
                      },
                      onSubmitted: (_) {
                        final items = ref.read(searchSuggestionsProvider);
                        if (items.isNotEmpty) {
                          _choose(items[_highlight.clamp(0, items.length - 1)]);
                          return;
                        }
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
                    chip('Unikaj tłumów', Icons.groups_rounded, filters.avoidCrowds,
                        (f, v) => f.copyWith(avoidCrowds: v)),
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

class _SuggestionRow extends ConsumerWidget {
  const _SuggestionRow({
    required this.place,
    required this.highlighted,
    required this.onTap,
  });

  final Place place;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final match = ref.watch(placeMatchProvider(place));
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: highlighted,
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: highlighted ? AppColors.mint100 : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(place.category.icon, color: AppColors.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(place.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.text)),
                    if (place.address != null)
                      Text(place.address!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall
                              ?.copyWith(color: AppColors.textMuted)),
                  ],
                ),
              ),
              if (match != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: StatusChip(match.verdict.style, dense: true),
                  ),
                ),
              ],
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

  static const double size = 52;
  static const double radius = 16;

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      excludeSemantics: true,
      onTap: onPressed,
      child: SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Material(
              color: AppColors.surfaceGlass,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
                side: const BorderSide(color: AppColors.border, width: 1.2),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: onPressed,
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
                        : Icon(icon, color: AppColors.primary, size: 24),
                  ),
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
    required this.selected,
    required this.onSelect,
    required this.onTapMap,
    required this.onLongPressMap,
<<<<<<< Updated upstream
    this.onCameraChanged,
    this.onSpawnTap,
  });

  final ValueChanged<MapCamera>? onCameraChanged;
  final ValueChanged<SpawnDistance>? onSpawnTap;
=======
    this.crowd = const [],
    this.onMoved,
  });

  final List<CrowdCell> crowd;
  final VoidCallback? onMoved;
>>>>>>> Stashed changes
  final MapController controller;
  final _MapStyle style;
  final Place? selected;
  final ValueChanged<Place> onSelect;
  final VoidCallback onTapMap;
  final ValueChanged<LatLng> onLongPressMap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(filteredPlacesProvider).value ?? const [];
    final location = ref.watch(userLocationProvider);
    final myLocation = location?.point;
    final manualStart = ref.watch(manualStartProvider);

    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: _krakowCenter,
        initialZoom: 14.5,
        minZoom: 11,
        maxZoom: 19,
        onTap: (_, _) => onTapMap(),
        onLongPress: (_, point) => onLongPressMap(point),
<<<<<<< Updated upstream
        onPositionChanged: onCameraChanged == null
            ? null
            : (camera, _) => onCameraChanged!(camera),
=======
        onPositionChanged: (_, _) => onMoved?.call(),
>>>>>>> Stashed changes
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

        // Crowd layer ('Unikaj tłumów'): semi-transparent squares.
        if (crowd.isNotEmpty)
          PolygonLayer(polygons: [
            for (final c in crowd)
              Polygon(
                points: c.polygon,
                color: crowdColor(c.label).withValues(alpha: 0.3),
                borderColor: crowdColor(c.label).withValues(alpha: 0.5),
                borderStrokeWidth: 0.5,
              ),
          ]),

        // 2. Planned accessible route (ORS or labelled demo)
        //    walking line, barrier spans in red, or accessible alternative
        const RouteLayer(),

        // 3. User location: accuracy circle + dot
        if (location != null && location.accuracyM > 0)
          CircleLayer(circles: [
            CircleMarker(
              point: location.point,
              radius: location.accuracyM,
              useRadiusInMeter: true,
              color: AppColors.accentCyan.withValues(alpha: 0.12),
              borderColor: AppColors.accentCyan.withValues(alpha: 0.5),
              borderStrokeWidth: 1.5,
            ),
          ]),
        if (myLocation != null)
          MarkerLayer(markers: [
            Marker(
              point: myLocation,
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

        if (location != null && location.accuracyM > warnAccuracyM)
          MarkerLayer(markers: [
            Marker(
              point: location.point,
              width: 200,
              height: 28,
              alignment: const Alignment(0, -3),
              child: Semantics(
                label: 'Lokalizacja niedokładna '
                    '(${formatAccuracy(location.accuracyM)})',
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceGlass,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.warn),
                    ),
                    child: ExcludeSemantics(
                      child: Text(
                        'Niedokładna ${formatAccuracy(location.accuracyM)}',
                        style: const TextStyle(
                            color: AppColors.warn,
                            fontSize: 11,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        if (manualStart != null)
          MarkerLayer(markers: [
            Marker(
              point: manualStart,
              width: 64,
              height: 48,
              alignment: Alignment.topCenter,
              child: Semantics(
                label: 'Punkt startowy trasy',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const ExcludeSemantics(
                        child: Text('Start',
                            style: TextStyle(
                                color: Color(0xFF090D12),
                                fontSize: 11,
                                fontWeight: FontWeight.w800)),
                      ),
                    ),
                    const Icon(Icons.flag_rounded,
                        color: AppColors.primary, size: 24),
                  ],
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

        // 5. Creatures to catch (spawns)
        SpawnMarkerLayer(onTap: (d) => onSpawnTap?.call(d)),

        // 6. Attribution
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
    required this.onClearStart,
  });

  final Place place;
  final VoidCallback onClose;
  final VoidCallback onRoute;
  final VoidCallback onClearStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final match = ref.watch(placeMatchProvider(place));
    final filters = ref.watch(placeFiltersProvider);
    final hasManualStart = ref.watch(manualStartProvider) != null;
    final text = Theme.of(context).textTheme;
    // Toilet / bench info appears in the preview only when its chip is on
    // (the full detail screen always shows everything).
    bool amenityVisible(Feature f) => switch (f) {
          Feature.toilet => filters.toilet,
          Feature.bench => filters.benches,
          _ => true,
        };
    final problems = match?.problems
            .where((c) => amenityVisible(c.feature))
            .toList() ??
        const [];
    bool hasFlag(Feature f) => place.factsFor(f).any((x) => x.flag == true);
    final amenities = [
      if (filters.toilet)
        (Icons.wc_rounded,
            hasFlag(Feature.toilet) ? 'Toaleta dostępna' : 'Brak danych o toalecie'),
      if (filters.benches)
        (Icons.chair_rounded,
            hasFlag(Feature.bench) ? 'Ławki w pobliżu' : 'Brak danych o ławkach'),
    ];

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
              for (final (icon, label) in amenities) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(icon, size: 16, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Text(label,
                        style: text.bodySmall?.copyWith(color: AppColors.text)),
                  ],
                ),
              ],
              if (problems.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  problems
                      .map((c) => '${c.feature.label}: ${c.status.style.label.toLowerCase()}')
                      .join(' · '),
                  style: text.bodySmall?.copyWith(color: AppColors.bad),
                ),
              ],
              if (hasManualStart) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.flag_rounded,
                        size: 16, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Text('Start: wybrany punkt',
                        style: text.bodySmall?.copyWith(color: AppColors.text)),
                    const Text(' · '),
                    TextButton(
                      onPressed: onClearStart,
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(48, 32)),
                      child: const Text('Usuń'),
                    ),
                  ],
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
                        padding: const EdgeInsets.symmetric(horizontal: 8),
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

/// Green / amber / red by crowd label.
Color crowdColor(CrowdLabel label) => switch (label) {
      CrowdLabel.low => const Color(0xFF2E7D32),
      CrowdLabel.medium => const Color(0xFFFFA000),
      CrowdLabel.high => const Color(0xFFD32F2F),
    };
