import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/data/api/api_client.dart';
import 'package:hackaton_project/data/models/needs_profile.dart';
import 'package:hackaton_project/data/models/place.dart';
import 'package:hackaton_project/data/repositories/places_repository.dart';
import 'package:hackaton_project/features/game/game_models.dart';
import 'package:hackaton_project/features/game/game_repository.dart';
import 'package:hackaton_project/features/route/route_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const base = 'http://test/api/v1';

class _FilePlaces implements PlacesRepository {
  @override
  Future<List<Place>> getPlaces() async => DemoPlacesRepository.parsePlaces(
      File('assets/demo/places.json').readAsStringSync());
}

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

final catalog = GameCatalog.parse(File('assets/demo/game.json').readAsStringSync());

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('anonymous auth + places parsing, re-auth once on 401', () async {
    var authCalls = 0;
    final seenAuth = <String?>[];
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/auth/anonymous')) {
        authCalls++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['deviceId'], isNotEmpty);
        return _json({'token': 't$authCalls', 'userId': 'u1', 'points': 0});
      }
      if (req.url.path.endsWith('/places')) {
        return _json({
          'places': [
            {
              'id': 'p1',
              'name': 'Sukiennice',
              'category': 'attraction',
              'lat': 50.06,
              'lng': 19.93,
              'isDemo': false,
              'facts': [
                {
                  'id': 'f1',
                  'feature': 'steps',
                  'value': 0,
                  'source': 'osm',
                  'fetchedAt': '2026-09-01T00:00:00Z',
                },
              ],
            },
          ],
          'sources': [],
        });
      }
      if (req.url.path.endsWith('/facts/f1/confirm')) {
        seenAuth.add(req.headers['Authorization']);
        if (seenAuth.length == 1) return _json({'code': 'UNAUTHORIZED'}, 401);
        return _json({
          'id': 'f1',
          'feature': 'steps',
          'value': 0,
          'source': 'osm',
          'fetchedAt': '2026-09-01T00:00:00Z',
          'confirmations': 1,
        });
      }
      return http.Response('', 404);
    });
    final api = ApiClient(baseUrl: base, client: client);
    final repo = ApiPlacesRepository(api, fallback: _FilePlaces());

    final places = await repo.getPlaces();
    expect(places.single.name, 'Sukiennice');
    expect(places.single.isDemo, isFalse);
    expect(places.single.facts.single.id, 'f1');

    final fact = await repo.vote('f1', confirm: true);
    expect(fact.confirmations, 1);
    expect(seenAuth, ['Bearer t1', 'Bearer t2']);
    expect(authCalls, 2);
  });

  test('409 surfaces as ApiException', () async {
    final api = ApiClient(
        baseUrl: base,
        client: MockClient((req) async => req.url.path.endsWith('/auth/anonymous')
            ? _json({'token': 't', 'userId': 'u', 'points': 0})
            : _json({'code': 'ALREADY_VOTED'}, 409)));
    final repo = ApiPlacesRepository(api, fallback: _FilePlaces());
    expect(
        () => repo.vote('f1', confirm: false),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.code, 'code', 'ALREADY_VOTED')));
  });

  test('offline: falls back to demo places and flags server unavailable', () async {
    bool? offline;
    final api = ApiClient(
        baseUrl: base,
        client: MockClient((_) async => throw const SocketException('down')));
    final repo = ApiPlacesRepository(api,
        fallback: _FilePlaces(), onOffline: (v) => offline = v);
    final places = await repo.getPlaces();
    expect(places, isNotEmpty);
    expect(places.first.isDemo, isTrue);
    expect(offline, isTrue);
  });

  const wawel = Place(
    id: 'wawel',
    name: 'Wawel',
    category: PlaceCategory.attraction,
    lat: 50.0541,
    lng: 19.9354,
    facts: [],
  );

  test('route: backend /routes is mapped to PlannedRoute', () async {
    late Map<String, dynamic> sent;
    final api = ApiClient(
        baseUrl: base,
        client: MockClient((req) async {
          sent = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({
            'distanceM': 1500,
            'durationS': 1400,
            'geometry': [
              [50.0617, 19.9373],
              [50.058, 19.936],
              [50.0541, 19.9354],
            ],
            'segments': [
              {'instruction': 'Prosto', 'distanceM': 1500, 'warning': 'kostka'},
            ],
            'source': 'openrouteservice',
            'fallback': false,
          });
        }));
    final route = await RouteService(apiKey: '', api: api).plan(
        from: rynekGlowny,
        startLabel: 'Rynek Główny',
        to: wawel,
        profile: NeedsProfile.wheelchair);
    expect(route.isDemo, isFalse);
    expect(route.points.length, 3);
    expect(route.points.first.latitude, 50.0617);
    expect(route.distanceM, 1500);
    expect(route.segments.single.warning, 'kostka');
    expect((sent['points'] as List).length, 2);
    expect(sent['profile']['maxKerbCm'], NeedsProfile.wheelchair.maxKerbCm);

    final fb = RouteService.parseApi(
        {'distanceM': 10, 'durationS': 10, 'geometry': [], 'segments': [], 'fallback': true},
        to: wawel,
        startLabel: 'x');
    expect(fb.isDemo, isTrue);
  });

  test('route: unreachable server gives demo route', () async {
    final api = ApiClient(
        baseUrl: base,
        client: MockClient((_) async => throw const SocketException('down')));
    final route = await RouteService(apiKey: '', api: api).plan(
        from: rynekGlowny,
        startLabel: 'Rynek Główny',
        to: wawel,
        profile: NeedsProfile.wheelchair);
    expect(route.isDemo, isTrue);
    expect(route.fallbackReason, contains('Serwer'));
  });

  group('game', () {
    final species = catalog.species.first;
    final offer = catalog.verifiedOffers.first;

    ApiGameRepository repoWith(Future<http.Response> Function(http.Request) h) =>
        ApiGameRepository(
          ApiClient(
              baseUrl: base,
              client: MockClient((req) async => req.url.path.endsWith('/auth/anonymous')
                  ? _json({'token': 't', 'userId': 'u', 'points': 0})
                  : h(req))),
          local: LocalGameRepository(Random(1)),
        );

    test('report returns species, points and server state', () async {
      late Map<String, dynamic> sent;
      final repo = repoWith((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({
          'species': {
            'id': species.id,
            'name': species.name,
            'emoji': species.emoji,
            'rarity': species.rarity.name,
          },
          'points': 25,
          'awarded': 0,
          'state': {
            'points': 100,
            'caught': {species.id: 1},
            'vouchers': [],
          },
        });
      });
      final (state, result) = await repo.submitReport(catalog,
          const GameState(points: 100),
          const BarrierReport(placeId: 'p1', steps: 2, curb: CurbRange.high));
      expect(result.species.id, species.id);
      expect(result.points, 25);
      expect(state.points, 100);
      expect(sent['placeId'], 'p1');
      expect(sent['report']['curb'], 'high');
      expect(sent['report']['steps'], 2);
    });

    test('voucher ok and 402 INSUFFICIENT_POINTS', () async {
      final ok = repoWith((req) async => _json({
            'voucher': {
              'offerId': offer.id,
              'code': 'KBB-ABCD',
              'activatedAt': '2026-10-03T10:00:00Z',
            },
            'state': {
              'points': 0,
              'caught': {},
              'vouchers': [
                {
                  'offerId': offer.id,
                  'code': 'KBB-ABCD',
                  'activatedAt': '2026-10-03T10:00:00Z',
                },
              ],
            },
          }));
      final s = await ok.activate(
          catalog, const GameState(points: 999), offer, DateTime(2026, 10, 3));
      expect(s!.vouchers.single.code, 'KBB-ABCD');

      final poor = repoWith(
          (req) async => _json({'code': 'INSUFFICIENT_POINTS'}, 402));
      expect(
          await poor.activate(
              catalog, const GameState(points: 0), offer, DateTime(2026, 10, 3)),
          isNull);
    });

    test('offline game falls back to local rules', () async {
      final repo = repoWith((_) async => throw const SocketException('down'));
      final (state, result) = await repo.submitReport(
          catalog, const GameState(points: 0), const BarrierReport(steps: 1));
      expect(state.points, 0);
      expect(result.points, result.species.sellValue);
    });

    test('sell success', () async {
      late http.Request sent;
      final repo = repoWith((req) async {
        sent = req;
        return _json({
          'earned': 50,
          'state': {'points': 150, 'caught': {'sowa': 1}, 'vouchers': []},
        });
      });
      final r = await repo.sell(
          catalog, const GameState(points: 100, caught: {'sowa': 3}), 'sowa', 2);
      expect(sent.url.path, endsWith('/game/sell'));
      expect(sent.method, 'POST');
      expect(jsonDecode(sent.body), {'speciesId': 'sowa', 'count': 2});
      expect(r.earned, 50);
      expect(r.state.points, 150);
      expect(r.state.caught['sowa'], 1);
    });

    test('sell 409 NOT_ENOUGH_CREATURES and 400 INVALID_COUNT', () async {
      final short = repoWith((_) async => _json({'code': 'NOT_ENOUGH_CREATURES'}, 409));
      await expectLater(
          short.sell(catalog, const GameState(points: 0), 'sowa', 5),
          throwsA(isA<SellException>()
              .having((e) => e.failure, 'failure', SellFailure.notEnoughCreatures)));
      final bad = repoWith((_) async => _json({'code': 'INVALID_COUNT'}, 400));
      await expectLater(
          bad.sell(catalog, const GameState(points: 0), 'sowa', 0),
          throwsA(isA<SellException>()
              .having((e) => e.failure, 'failure', SellFailure.invalidCount)));
    });
  });
}
