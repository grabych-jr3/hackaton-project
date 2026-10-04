import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hackaton_project/core/theme/app_theme.dart';
import 'package:hackaton_project/data/api/api_client.dart';
import 'package:hackaton_project/data/repositories/catch_repository.dart';
import 'package:hackaton_project/features/catch/ar_catch_screen.dart';
import 'package:hackaton_project/features/catch/catch_screen.dart';
import 'package:hackaton_project/features/game/game_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../game/game_screens_test.dart' show pumpScreen;

const base = 'http://test/api/v1';

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

/// Backend fake: auth + POST /catches + GET /catches/c1 returning [polls] in order
/// (the last one repeats).
MockClient _backend(List<Map<String, dynamic>> polls,
    {List<http.BaseRequest>? seen, int unauthorizedUploads = 0}) {
  var auth = 0;
  var poll = 0;
  var uploads = 0;
  return MockClient((req) async {
    seen?.add(req);
    final path = req.url.path;
    if (path.endsWith('/auth/anonymous')) {
      auth++;
      return _json({'token': 't$auth'});
    }
    if (req.method == 'POST' && path == '/api/v1/catches') {
      uploads++;
      if (uploads <= unauthorizedUploads) return _json({'code': 'UNAUTHORIZED'}, 401);
      return _json({'catchId': 'c1', 'status': 'PENDING'}, 202);
    }
    if (req.method == 'GET' && path == '/api/v1/catches/c1') {
      expect(req.headers['Authorization'], startsWith('Bearer t'));
      final body = polls[poll < polls.length ? poll : polls.length - 1];
      poll++;
      return _json(body);
    }
    return http.Response('not found', 404);
  });
}

CatchRepository _repo(http.Client client, List<Duration> sleeps) => CatchRepository(
      ApiClient(baseUrl: base, client: client),
      sleep: (d) async => sleeps.add(d),
      clock: () => DateTime.utc(2026, 10, 4, 12),
    );

const _pending = {'catchId': 'c1', 'status': 'PENDING'};
final _ok = {
  'catchId': 'c1',
  'status': 'OK',
  'reason': null,
  'result': {
    'steps': 3,
    'kerbRange': '3-7cm',
    'ramp': false,
    'handrail': true,
    'confidence': 0.8,
  },
  'species': {'id': 'smok', 'name': 'Smok Wawelski', 'emoji': '🐉', 'rarity': 'rare'},
  'points': 25,
  'awarded': 0,
  'state': {
    'points': 120,
    'caught': {'smok': 1},
    'vouchers': [],
  },
  'createdFacts': [],
};

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('ApiClient multipart: fields, jpeg part, Bearer, one re-auth on 401', () async {
    final seen = <http.BaseRequest>[];
    final api = ApiClient(
        baseUrl: base, client: _backend(const [], seen: seen, unauthorizedUploads: 1));
    final json = await api.postMultipart('/catches',
        fields: {'lat': '50.06', 'lng': '19.93'},
        files: [MultipartPart('photo', [1, 2, 3], filename: 'catch.jpg')]);
    expect(json['catchId'], 'c1');

    final uploads = seen.where((r) => r.url.path == '/api/v1/catches').toList();
    expect(uploads, hasLength(2));
    expect(uploads[0].headers['Authorization'], 'Bearer t1');
    expect(uploads[1].headers['Authorization'], 'Bearer t2');
    expect(uploads[1].headers['content-type'], startsWith('multipart/form-data'));
    final body = utf8.decode((uploads[1] as http.Request).bodyBytes, allowMalformed: true);
    expect(body, contains('name="lat"'));
    expect(body, contains('name="photo"; filename="catch.jpg"'));
    expect(body, contains('content-type: image/jpeg'));
  });

  test('ApiClient multipart: second 401 surfaces as ApiException', () async {
    final api = ApiClient(baseUrl: base, client: _backend(const [], unauthorizedUploads: 5));
    expect(
      () => api.postMultipart('/catches', files: [MultipartPart('photo', [1], filename: 'a.jpg')]),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );
  });

  test('catch flow: polls every 1.5 s until OK, sends contract fields', () async {
    final seen = <http.BaseRequest>[];
    final sleeps = <Duration>[];
    final res = await _repo(_backend([_pending, _pending, _ok], seen: seen), sleeps)
        .submitPhoto(jpegBytes: [9], lat: 50.06, lng: 19.93, placeId: 'p1');

    expect(res.status, CatchStatus.ok);
    expect(res.species!.name, 'Smok Wawelski');
    expect(res.points, 25);
    expect(res.state!.caught['smok'], 1);
    expect(res.result!.lines, contains('Schody: 3'));
    expect(sleeps, List.filled(3, const Duration(milliseconds: 1500)));

    final upload = seen.firstWhere((r) => r.method == 'POST' && r.url.path == '/api/v1/catches')
        as http.Request;
    final body = utf8.decode(upload.bodyBytes, allowMalformed: true);
    expect(body, contains('2026-10-04T12:00:00.000Z'));
    expect(body, contains('name="placeId"'));
    expect(body, isNot(contains('name="spawnId"')));
  });

  test('catch flow: REJECTED and FAILED are returned as-is', () async {
    final rejected = await _repo(
            _backend([
              {'catchId': 'c1', 'status': 'REJECTED', 'reason': 'BLURRY'}
            ]),
            [])
        .submitPhoto(jpegBytes: [9], lat: 1, lng: 2);
    expect(rejected.status, CatchStatus.rejected);
    expect(rejectReasonText(rejected.reason), 'Zdjęcie jest nieostre.');

    final failed = await _repo(
            _backend([
              {'catchId': 'c1', 'status': 'FAILED', 'reason': 'vision timeout'}
            ]),
            [])
        .submitPhoto(jpegBytes: [9], lat: 1, lng: 2);
    expect(failed.status, CatchStatus.failed);
  });

  test('catch flow: gives up after 30 s of PENDING', () async {
    final sleeps = <Duration>[];
    final res = await _repo(_backend([_pending]), sleeps)
        .submitPhoto(jpegBytes: [9], lat: 1, lng: 2);
    expect(res.timedOut, isTrue);
    expect(res.status, CatchStatus.pending);
    expect(sleeps, hasLength(20)); // 20 × 1.5 s = 30 s
  });

  Future<CatchExit?> showOutcome(WidgetTester tester, CatchPhotoResponse? r,
      {required String tap}) async {
    CatchExit? exit;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => exit = await showCatchOutcomeDialog(ctx, r),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
    return exit;
  }

  testWidgets('outcome OK: species, sell value, AI badge, no "+N pkt"', (tester) async {
    CatchExit? exit;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async =>
              exit = await showCatchOutcomeDialog(ctx, CatchPhotoResponse.fromJson(_ok)),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Złapano: Smok Wawelski (rzadki)'), findsOneWidget);
    expect(find.text('Wartość: 25 pkt — sprzedaj w Kolekcji'), findsOneWidget);
    expect(find.text('AI · niezweryfikowane'), findsOneWidget);
    expect(find.text('• Schody: 3'), findsOneWidget);
    expect(find.textContaining('+25'), findsNothing);
    await tester.tap(find.text('Do kolekcji'));
    await tester.pumpAndSettle();
    expect(exit, CatchExit.collection);
  });

  testWidgets('outcome REJECTED: Polish reason, retake keeps the camera', (tester) async {
    final exit = await showOutcome(
        tester,
        const CatchPhotoResponse(
            catchId: 'c1', status: CatchStatus.rejected, reason: 'NO_BARRIER'),
        tap: 'Zrób zdjęcie ponownie');
    expect(exit, isNull);
  });

  testWidgets('outcome FAILED / timeout / upload error → survey', (tester) async {
    for (final r in [
      const CatchPhotoResponse(catchId: 'c1', status: CatchStatus.failed),
      const CatchPhotoResponse(catchId: 'c1', status: CatchStatus.pending, timedOut: true),
      null,
    ]) {
      final exit = await showOutcome(tester, r, tap: 'Przejdź do ankiety');
      expect(exit, CatchExit.survey);
    }
  });

  testWidgets('demo mode: survey screen explains why there is no camera', (tester) async {
    await pumpScreen(tester, const CatchScreen());
    expect(find.text('Gdzie jest bariera?'), findsOneWidget);
    expect(find.text(demoCameraMessage), findsOneWidget);
    expect(find.text('Kamera'), findsNothing); // no fake camera tab
    expect(find.text('Otwórz aparat'), findsNothing);
  });
}
