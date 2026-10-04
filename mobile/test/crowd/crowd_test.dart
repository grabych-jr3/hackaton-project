import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/features/map/crowd_cloud_layer.dart';
import 'package:hackaton_project/data/api/api_client.dart';
import 'package:hackaton_project/data/models/crowd.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/data/repositories/crowd_repository.dart';
import 'package:hackaton_project/features/route/route_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const base = 'http://test/api/v1';

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

const _cell = {
  'id': 'krakow:41:17',
  'polygon': [
    [50.06, 19.93],
    [50.06, 19.94],
    [50.07, 19.94],
    [50.07, 19.93],
    [50.06, 19.93],
  ],
  'crowd': 0.82,
  'label': 'tłoczno',
  'source': 'live',
  'reports': 12,
  'updatedAt': '2026-10-03T14:05:00Z',
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('CrowdCell parses JSON, skips invalid cells, label fallback', () {
    final cells = CrowdCell.listFromJson({
      'cells': [
        _cell,
        {'id': 'bad', 'polygon': []},
        {..._cell, 'id': 'x', 'label': null, 'crowd': 0.1},
      ],
    });
    expect(cells, hasLength(2));
    final c = cells.first;
    expect(c.id, 'krakow:41:17');
    expect(c.polygon.first, const LatLng(50.06, 19.93));
    expect(c.polygon, hasLength(5));
    expect(c.crowd, 0.82);
    expect(c.label, CrowdLabel.high);
    expect(c.source, 'live');
    expect(c.reports, 12);
    expect(c.updatedAt, DateTime.utc(2026, 10, 3, 14, 5));
    expect(cells[1].label, CrowdLabel.low);
  });

  test('CrowdReportResult parses nullable crowd/label', () {
    final r = CrowdReportResult.fromJson(
        {'cellId': 'krakow:3:4', 'crowd': null, 'label': null, 'awarded': 5});
    expect(r.cellId, 'krakow:3:4');
    expect(r.crowd, isNull);
    expect(r.label, isNull);
    expect(r.awarded, 5);
    expect(CrowdReportResult.fromJson(
            {'cellId': 'a', 'crowd': 0.5, 'label': 'średnio', 'awarded': 0})
        .label, CrowdLabel.medium);
  });

  test('getCells sends bbox (lng,lat order) without auth', () async {
    late http.Request seen;
    final repo = CrowdRepository(ApiClient(
        baseUrl: base,
        client: MockClient((req) async {
          seen = req;
          return _json({'cells': [_cell]});
        })));
    final cells = await repo.getCells(
        minLat: 50.0, minLng: 19.9, maxLat: 50.1, maxLng: 20.0,
        at: DateTime.utc(2026, 10, 4, 12));
    expect(cells.single.id, 'krakow:41:17');
    expect(seen.url.path, '/api/v1/crowd');
    expect(seen.url.queryParameters['bbox'],
        '19.90000,50.00000,20.00000,50.10000');
    expect(seen.url.queryParameters['at'], '2026-10-04T12:00:00.000Z');
    expect(seen.headers['Authorization'], isNull);
  });

  test('report posts level with Bearer token; 429 / 400 -> Polish errors',
      () async {
    var status = 200;
    Map<String, dynamic>? body;
    String? auth;
    final repo = CrowdRepository(ApiClient(
        baseUrl: base,
        client: MockClient((req) async {
          if (req.url.path.endsWith('/auth/anonymous')) {
            return _json({'token': 'tok', 'userId': 'u1', 'points': 0});
          }
          body = jsonDecode(req.body) as Map<String, dynamic>;
          auth = req.headers['Authorization'];
          if (status == 429) return _json({'code': 'RATE_LIMIT'}, 429);
          if (status == 400) return _json({'code': 'OUTSIDE_CITY'}, 400);
          return _json({
            'cellId': 'krakow:3:4',
            'crowd': 0.5,
            'label': 'średnio',
            'awarded': 5,
          });
        })));
    final res = await repo.report(const LatLng(50.06, 19.93), 1);
    expect(res.awarded, 5);
    expect(body, {'lat': 50.06, 'lng': 19.93, 'level': 1});
    expect(auth, 'Bearer tok');

    status = 429;
    await expectLater(
        repo.report(const LatLng(50.06, 19.93), 2),
        throwsA(isA<CrowdReportException>()
            .having((e) => e.message, 'message', contains('30 minut'))));
    status = 400;
    await expectLater(
        repo.report(const LatLng(50.06, 19.93), 2),
        throwsA(isA<CrowdReportException>()
            .having((e) => e.message, 'message', contains('Krakowa'))));
  });

  test('route request sends avoidCrowds', () async {
    Map<String, dynamic>? sent;
    final api = ApiClient(
        baseUrl: base,
        client: MockClient((req) async {
          sent = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({
            'geometry': [
              [50.06, 19.93],
              [50.07, 19.94],
            ],
            'distanceM': 100,
            'durationS': 80,
            'note': 'Omija zatłoczony Rynek',
          });
        }));
    final to = Place(
        id: 'p', name: 'Cel', category: PlaceCategory.values.first, lat: 50.07, lng: 19.94, facts: []);
    final r = await RouteService(api: api).plan(
        from: const LatLng(50.06, 19.93),
        startLabel: 'Start',
        to: to,
        profile: NeedsProfile.wheelchair,
        avoidCrowds: true);
    expect(sent!['avoidCrowds'], true);
    expect(r.note, 'Omija zatłoczony Rynek');
  });

  test('crowd cloud: quiet is nearly invisible, busy is stronger and redder',
      () {
    expect(crowdCloudAlpha(0), lessThan(0.07));
    expect(crowdCloudAlpha(1), closeTo(0.53312, 1e-9));
    expect(crowdCloudAlpha(1), greaterThan(crowdCloudAlpha(0.5)));
    expect(crowdCloudAlpha(1), lessThanOrEqualTo(0.55)); // never solid
    final busy = crowdCloudColor(1), calm = crowdCloudColor(0);
    expect(busy.r, greaterThan(calm.r));
    expect(calm.g, greaterThan(busy.g));
  });
}
