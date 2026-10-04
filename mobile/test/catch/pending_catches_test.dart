import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/data/api/api_client.dart';
import 'package:hackaton_project/data/repositories/catch_repository.dart';
import 'package:hackaton_project/features/catch/pending_catches.dart';
import 'package:hackaton_project/features/game/game_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const base = 'http://test/api/v1';

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

final _okBody = {
  'catchId': 'c1',
  'status': 'OK',
  'species': {'id': 'mis', 'name': 'Niedźwiedź', 'emoji': '🐻', 'rarity': 'epic'},
  'points': 60,
};

/// [statuses]: body returned by GET /catches/c1 in order (last repeats).
/// [uploadFailures]: network failures before the upload succeeds.
MockClient _backend(List<Map<String, dynamic>> statuses,
    {int uploadFailures = 0, bool listEndpoint = false, List<String>? log}) {
  var uploads = 0;
  var polls = 0;
  return MockClient((req) async {
    final path = req.url.path;
    log?.add('${req.method} $path${req.url.hasQuery ? '?' : ''}');
    if (path.endsWith('/auth/anonymous')) return _json({'token': 't'});
    if (req.method == 'POST' && path == '/api/v1/catches') {
      uploads++;
      if (uploads <= uploadFailures) throw http.ClientException('offline');
      return _json({'catchId': 'c1', 'status': 'PENDING'}, 202);
    }
    if (req.method == 'GET' && path == '/api/v1/catches') {
      if (!listEndpoint) return http.Response('', 404);
      final body = statuses[polls < statuses.length ? polls : statuses.length - 1];
      polls++;
      return _json([
        {...body, 'thumbnailUrl': '/catches/c1/photo'}
      ]);
    }
    if (req.method == 'GET' && path == '/api/v1/catches/c1') {
      final body = statuses[polls < statuses.length ? polls : statuses.length - 1];
      polls++;
      return _json(body);
    }
    return http.Response('', 404);
  });
}

ProviderContainer _container(http.Client client, List<PendingCatch> finished) {
  final c = ProviderContainer(overrides: [
    catchRepositoryProvider
        .overrideWithValue(CatchRepository(ApiClient(baseUrl: base, client: client))),
    pendingCatchesConfigProvider.overrideWithValue(const PendingCatchesConfig(
        pollInterval: Duration(hours: 1), retryBase: Duration.zero)),
    catchFinishedSinkProvider.overrideWithValue(finished.add),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('upload → PENDING → OK notifies, persists id', () async {
    final finished = <PendingCatch>[];
    final c = _container(
        _backend([
          {'catchId': 'c1', 'status': 'PENDING'},
          _okBody
        ]),
        finished);
    final n = c.read(pendingCatchesProvider.notifier);
    await n.loaded;
    n.submit(jpeg: Uint8List.fromList([1, 2, 3]), lat: 50, lng: 19.9);
    expect(c.read(pendingCatchesProvider).single.status, PendingStatus.uploading);
    await _settle();
    expect(c.read(pendingCatchesProvider).single.status, PendingStatus.pending);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PendingCatchesNotifier.prefsKey), contains('"c1"'));

    await n.pollOnce();
    expect(finished, isEmpty);
    await n.pollOnce();
    expect(finished.single.status, PendingStatus.ok);
    expect(catchFinishedMessage(finished.single),
        'Złapano: Niedźwiedź (epicki)! Wartość 60 pkt — zobacz w Kolekcji');
  });

  test('list endpoint (bare array) is used with relative thumbnail', () async {
    final finished = <PendingCatch>[];
    final log = <String>[];
    final c = _container(_backend([_okBody], listEndpoint: true, log: log), finished);
    final n = c.read(pendingCatchesProvider.notifier);
    await n.loaded;
    n.submit(jpeg: Uint8List(1), lat: 50, lng: 19.9);
    await _settle();
    await n.pollOnce();
    expect(finished.single.status, PendingStatus.ok);
    expect(finished.single.thumbnailUrl, '/catches/c1/photo');
    expect(log.where((l) => l == 'GET /api/v1/catches?'), hasLength(1));
    expect(log, isNot(contains('GET /api/v1/catches/c1')));
  });

  test('REJECTED gives a reason message', () async {
    final finished = <PendingCatch>[];
    final c = _container(
        _backend([
          {'catchId': 'c1', 'status': 'REJECTED', 'reason': 'Zdjęcie jest zbyt ciemne'}
        ]),
        finished);
    final n = c.read(pendingCatchesProvider.notifier);
    await n.loaded;
    n.submit(jpeg: Uint8List(1), lat: 50, lng: 19.9);
    await _settle();
    await n.pollOnce();
    expect(finished.single.status, PendingStatus.rejected);
    expect(catchFinishedMessage(finished.single),
        'Zdjęcie odrzucone: Zdjęcie jest zbyt ciemne');
  });

  test('network failures are retried (3 attempts), then FAILED', () async {
    final ok = <PendingCatch>[];
    final c1 = _container(_backend([_okBody], uploadFailures: 2), ok);
    final n1 = c1.read(pendingCatchesProvider.notifier);
    await n1.loaded;
    n1.submit(jpeg: Uint8List(1), lat: 50, lng: 19.9);
    await _settle();
    expect(c1.read(pendingCatchesProvider).single.status, PendingStatus.pending);

    final failed = <PendingCatch>[];
    final c2 = _container(_backend([_okBody], uploadFailures: 3), failed);
    final n2 = c2.read(pendingCatchesProvider.notifier);
    await n2.loaded;
    n2.submit(jpeg: Uint8List(1), lat: 50, lng: 19.9);
    await _settle();
    expect(failed.single.status, PendingStatus.failed);
  });

  test('OK without species/state parses as OK (never "AI niedostępne")', () {
    final r = parseCatchResponse({'catchId': 'c1', 'status': 'OK', 'species': {'bad': 1}});
    expect(r.status, CatchStatus.ok);
    expect(r.species, isNull);
    expect(
        catchFinishedMessage(PendingCatch(
            localId: 'x', createdAt: DateTime(2026), status: PendingStatus.ok, response: r)),
        startsWith('Analiza zakończona'));
  });

  test('pending ids are restored from shared_preferences', () async {
    SharedPreferences.setMockInitialValues({
      PendingCatchesNotifier.prefsKey: jsonEncode([
        {'localId': 'a', 'catchId': 'c1', 'createdAt': '2026-10-04T12:00:00Z', 'status': 'pending'}
      ]),
    });
    final finished = <PendingCatch>[];
    final c = _container(_backend([_okBody]), finished);
    final n = c.read(pendingCatchesProvider.notifier);
    await n.loaded;
    expect(c.read(pendingCatchesProvider).single.catchId, 'c1');
    await n.pollOnce();
    expect(finished.single.status, PendingStatus.ok);
  });

  testWidgets('Zgłoszenia list shows status chips', (tester) async {
    SharedPreferences.setMockInitialValues({
      PendingCatchesNotifier.prefsKey: jsonEncode([
        {'localId': 'a', 'catchId': 'c1', 'createdAt': '2026-10-04T12:00:00Z', 'status': 'ok'},
        {'localId': 'b', 'catchId': 'c2', 'createdAt': '2026-10-04T12:00:00Z', 'status': 'rejected'},
        {'localId': 'c', 'catchId': 'c3', 'createdAt': '2026-10-04T12:00:00Z', 'status': 'failed'},
      ]),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [catchRepositoryProvider.overrideWithValue(null)],
      child: const MaterialApp(home: Scaffold(body: PendingCatchesSection())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Zgłoszenia'), findsOneWidget);
    expect(find.text('Złapano'), findsOneWidget);
    expect(find.text('Odrzucone'), findsOneWidget);
    expect(find.text('Błąd'), findsOneWidget);
    await tester.tap(find.text('Złapano'));
    await tester.pumpAndSettle();
    expect(find.text('Analiza zakończona'), findsOneWidget);
  });
}
