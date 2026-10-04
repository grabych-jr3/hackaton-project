import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/core/theme/app_colors.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/features/route/route_layer.dart';
import 'package:hackaton_project/features/route/route_panel.dart';
import 'package:hackaton_project/features/route/route_service.dart';

const wawel = Place(
  id: 'wawel',
  name: 'Zamek Królewski na Wawelu',
  category: PlaceCategory.attraction,
  lat: 50.0541,
  lng: 19.9354,
  facts: [],
);

Map<String, dynamic> apiJson() => {
      'profile': 'foot-walking',
      'distanceM': 1500,
      'durationS': 1080,
      'geometry': [
        [50.061, 19.937],
        [50.059, 19.937],
        [50.057, 19.936],
        [50.054, 19.935],
      ],
      'segments': [
        {'instruction': 'Prosto', 'distanceM': 1500, 'warning': null},
      ],
      'source': 'ors',
      'fallback': false,
      'relaxed': false,
      'barriers': [
        {'fromIndex': 1, 'toIndex': 2, 'type': 'steps', 'label': 'Schody'},
        {
          'fromIndex': 2,
          'toIndex': 3,
          'type': 'steep',
          'label': 'Stromy odcinek',
          'detail': 'ok. 12%'
        },
        {'type': 'steps'}, // malformed -> skipped
      ],
      'accessible': false,
      'alternative': {
        'profile': 'wheelchair',
        'distanceM': 1800,
        'durationS': 1320,
        'geometry': [
          [50.061, 19.937],
          [50.058, 19.939],
          [50.054, 19.935],
        ],
        'segments': [],
        'barriers': [],
        'accessible': true,
        'alternative': null,
      },
    };

void main() {
  test('parseApi reads barriers and alternative, tolerates missing fields', () {
    final r = RouteService.parseApi(apiJson(), to: wawel, startLabel: 'Rynek');
    expect(r.profile, 'foot-walking');
    expect(r.accessible, isFalse);
    expect(r.barriers.length, 2);
    expect(r.barriers[1].detail, 'ok. 12%');
    expect(r.alternative!.isWheelchair, isTrue);
    expect(r.alternative!.accessible, isTrue);
    expect(r.alternative!.alternative, isNull);

    final old = RouteService.parseApi(
        {'distanceM': 10, 'geometry': []}, to: wawel, startLabel: 'Rynek');
    expect(old.barriers, isEmpty);
    expect(old.accessible, isTrue);
    expect(old.alternative, isNull);
  });

  test('computeBarriers: steps waytype + steep class above profile max', () {
    final props = <String, dynamic>{
      'extras': {
        'waytypes': {
          'values': [
            [0, 3, 3],
            [3, 5, 8], // steps
            [5, 9, 4],
          ],
        },
        'steepness': {
          'values': [
            [0, 6, 1],
            [6, 8, -3], // 7–9% > 6%
            [8, 9, 2], // 4–6% ok
          ],
        },
        'surface': {
          'values': [
            [0, 8, 3],
            [8, 9, 10], // gravel
          ],
        },
      },
    };
    final w = RouteService.computeBarriers(props, NeedsProfile.wheelchair);
    expect(w.map((b) => b.type), ['steps', 'steep', 'surface']);
    expect(w[0].fromIndex, 3);
    expect(w[0].toIndex, 5);
    expect(w[1].detail, 'ok. 7–9%');

    // Stroller: max 10%, surface not checked -> only steps.
    final s = RouteService.computeBarriers(props, NeedsProfile.stroller);
    expect(s.map((b) => b.type), ['steps']);
  });

  test('demo route has a labelled sample barrier and an alternative', () {
    final r = RouteService.demoRoute(rynekGlowny, 'Rynek', wawel);
    expect(r.accessible, isFalse);
    expect(r.barriers.single.detail, 'DANE PRZYKŁADOWE');
    expect(r.alternative?.isWheelchair, isTrue);
  });

  testWidgets('panel lists barriers and toggles the alternative',
      (tester) async {
    final route =
        RouteService.parseApi(apiJson(), to: wawel, startLabel: 'Rynek');
    var showAlt = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => RoutePanel(
            route: route,
            onClose: () {},
            showAlternative: showAlt,
            showBarriers: true,
            onToggleAlternative: () => setState(() => showAlt = !showAlt),
          ),
        ),
      ),
    ));
    expect(find.text('Trasa piesza · 1,5 km · 18 min'), findsOneWidget);
    expect(find.text('Na trasie są bariery (2): Schody, Stromy odcinek'),
        findsOneWidget);
    expect(find.text('Stromy odcinek (ok. 12%)'), findsOneWidget);
    final btn = find.text('Pokaż trasę dostępną (+300 m, +4 min)');
    expect(btn, findsOneWidget);

    await tester.tap(btn);
    await tester.pump();
    expect(showAlt, isTrue);
    expect(find.text('Trasa dostępna · 1,8 km · 22 min'), findsOneWidget);
    expect(find.text(RoutePanel.accessibleNote), findsOneWidget);
    await tester.tap(find.text(RoutePanel.walkingButton));
    await tester.pump();
    expect(showAlt, isFalse);
  });

  testWidgets('fallback shows "no data" note, not barriers', (tester) async {
    final route = RouteService.parseApi({
      'distanceM': 900,
      'geometry': [
        [50.06, 19.93],
        [50.05, 19.93],
      ],
      'fallback': true,
      'barriers': [],
      'accessible': false,
      'fallbackReason': 'ORS timeout',
      'alternative': null,
    }, to: wawel, startLabel: 'Rynek');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RoutePanel(
                route: route, onClose: () {}, showBarriers: true))));
    expect(find.text(RoutePanel.noDataNote), findsOneWidget);
    expect(find.text('ORS timeout'), findsOneWidget);
    expect(find.textContaining('bariery'), findsNothing);
  });

  testWidgets('layer draws barrier spans in red with warning markers',
      (tester) async {
    final route =
        RouteService.parseApi(apiJson(), to: wawel, startLabel: 'Rynek');
    final lines = RouteLayers.polylines(route, false);
    final red = lines.where((l) => l.color == AppColors.bad).toList();
    // Touching spans [1-2] + [2-3] are drawn as one merged span.
    expect(red.length, 1);
    expect(red.first.points.length, 3);

    // Alternative on top; walking route dimmed with its red spans dimmed.
    final alt = RouteLayers.polylines(route, true);
    expect(alt.where((l) => l.color == AppColors.bad), isEmpty);
    expect(alt.where((l) => l.color.r == AppColors.bad.r && l.color.a < 1),
        isNotEmpty);
    expect(alt.last.points, route.alternative!.points);

    await tester.pumpWidget(MaterialApp(
      home: FlutterMap(
        options: const MapOptions(
            initialCenter: rynekGlowny, initialZoom: 15),
        children: [RouteLayers(route: route, showBarriers: true)],
      ),
    ));
    await tester.pump();
    // Touching steps + steep spans merged into one marker.
    expect(
        find.byWidgetPredicate((w) =>
            w is Semantics &&
            w.properties.label == 'Bariera: Schody, Stromy odcinek'),
        findsOneWidget);
  });

  test('groupBarriers merges spans closer than 15 m, keeps distant ones', () {
    final r = RouteService.parseApi({
      'geometry': [
        [50.0500, 19.9400],
        [50.0501, 19.9400], // ~11 m
        [50.0502, 19.9400], // ~11 m
        [50.0503, 19.9400],
        [50.0520, 19.9400], // ~190 m
        [50.0521, 19.9400],
      ],
      'barriers': [
        {'fromIndex': 0, 'toIndex': 1, 'type': 'steps', 'label': 'Schody'},
        {'fromIndex': 2, 'toIndex': 3, 'type': 'steps', 'label': 'Schody'},
        {'fromIndex': 4, 'toIndex': 5, 'type': 'surface', 'label': 'Bruk'},
      ],
      'accessible': false,
    }, to: wawel, startLabel: 'Rynek');
    final g = groupBarriers(r);
    expect(g.length, 2);
    expect([g[0].fromIndex, g[0].toIndex], [0, 3]);
    expect(g[0].barriers.length, 2);
    expect(g[1].label, 'Bruk');
  });

  testWidgets('chip off: layer is a plain walking line, no markers',
      (tester) async {
    final route =
        RouteService.parseApi(apiJson(), to: wawel, startLabel: 'Rynek');
    final lines = RouteLayers.polylines(route, true, showBarriers: false);
    expect(lines.where((l) => l.color == AppColors.bad), isEmpty);
    expect(lines.last.points, route.points, reason: 'walking, not alternative');
    await tester.pumpWidget(MaterialApp(
      home: FlutterMap(
        options: const MapOptions(initialCenter: rynekGlowny, initialZoom: 15),
        children: [RouteLayers(route: route, showAlternative: true)],
      ),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.priority_high_rounded), findsNothing);
  });

  testWidgets('chip off: panel shows no barrier info and no toggle',
      (tester) async {
    final json = apiJson()..['note'] = 'Brak trasy bez barier';
    json['segments'] = [
      {'instruction': 'Schodami', 'distanceM': 20, 'warning': 'Schody'},
    ];
    final route = RouteService.parseApi(json, to: wawel, startLabel: 'Rynek');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: RoutePanel(route: route, onClose: () {}))));
    expect(find.text('Trasa piesza · 1,5 km · 18 min'), findsOneWidget);
    expect(find.textContaining('bariery'), findsNothing);
    expect(find.textContaining('Pokaż trasę dostępną'), findsNothing);
    expect(find.text('Stromy odcinek (ok. 12%)'), findsNothing);
    expect(find.text(RoutePanel.accessibleNote), findsNothing);
    expect(find.text('Brak trasy bez barier'), findsNothing);
    expect(find.textContaining('⚠'), findsNothing);
    expect(find.text('Schodami'), findsOneWidget);
  });

  testWidgets('chip on: panel shows the alternative note', (tester) async {
    final json = apiJson();
    (json['alternative'] as Map<String, dynamic>)['note'] =
        'Brak trasy bez barier do samego celu — ostatnie 40 m może wymagać pomocy';
    final route = RouteService.parseApi(json, to: wawel, startLabel: 'Rynek');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RoutePanel(
                route: route,
                onClose: () {},
                showBarriers: true,
                showAlternative: true,
                onToggleAlternative: () {}))));
    expect(find.textContaining('ostatnie 40 m może wymagać pomocy'),
        findsOneWidget);
    expect(find.text(RoutePanel.walkingButton), findsOneWidget);
  });

  testWidgets('collapsed bar exposes the alternative toggle only with chip on',
      (tester) async {
    final route =
        RouteService.parseApi(apiJson(), to: wawel, startLabel: 'Rynek');
    var showAlt = false;
    var barriers = true;
    late StateSetter set;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          set = setState;
          return RouteCollapsedBar(
            route: route,
            onExpand: () {},
            onClear: () {},
            showBarriers: barriers,
            showAlternative: showAlt,
            onToggleAlternative: () => setState(() => showAlt = !showAlt),
          );
        }),
      ),
    ));
    expect(find.textContaining('1,5 km · bariery: 1'), findsOneWidget);
    await tester.tap(find.text('Trasa dostępna: +300 m'));
    await tester.pump();
    expect(showAlt, isTrue);
    expect(find.textContaining('1,8 km'), findsOneWidget);
    expect(find.text(RouteCollapsedBar.walkingLabel), findsOneWidget);

    set(() => barriers = false);
    await tester.pump();
    expect(find.textContaining('Trasa dostępna'), findsNothing);
    expect(find.text(RouteCollapsedBar.walkingLabel), findsNothing);
    expect(find.textContaining('1,5 km'), findsOneWidget);
    expect(find.textContaining('bariery'), findsNothing);
  });
}
