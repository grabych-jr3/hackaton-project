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
        home: Scaffold(body: RoutePanel(route: route, onClose: () {}))));
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
    expect(red.length, 2);
    expect(red.first.points.length, 2);

    final alt = RouteLayers.polylines(route, true);
    expect(alt.where((l) => l.color == AppColors.bad), isEmpty);
    expect(alt.last.points, route.alternative!.points);

    await tester.pumpWidget(MaterialApp(
      home: FlutterMap(
        options: const MapOptions(
            initialCenter: rynekGlowny, initialZoom: 15),
        children: [RouteLayers(route: route)],
      ),
    ));
    await tester.pump();
    expect(
        find.byWidgetPredicate((w) =>
            w is Semantics && w.properties.label == 'Bariera: Schody'),
        findsOneWidget);
  });
}
