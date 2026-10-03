import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../features/game/game_models.dart';
import '../api/api_client.dart';

/// Photo catches (AR camera): `POST /catches` (multipart) then polls
/// `GET /catches/{id}` until the vision service answers.
///
/// Ported from Bogdan's AR-update branch, now on the shared [ApiClient]
/// (Bearer auth + re-auth on 401, `API_BASE_URL` already ends with `/api/v1`).
class CatchRepository {
  CatchRepository(
    this._api, {
    this.pollInterval = const Duration(milliseconds: 1500),
    this.maxWait = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
  })  : _sleep = sleep ?? Future<void>.delayed,
        _clock = clock ?? DateTime.now;

  final ApiClient _api;
  final Duration pollInterval;
  final Duration maxWait;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;

  /// Uploads the photo and waits for the result. Never returns PENDING
  /// unless [CatchPhotoResponse.timedOut] is set. Network/API errors
  /// while uploading propagate; poll errors are retried until [maxWait].
  Future<CatchPhotoResponse> submitPhoto({
    required List<int> jpegBytes,
    required double lat,
    required double lng,
    String? spawnId,
    String? placeId,
  }) async {
    final json = await _api.postMultipart(
      '/catches',
      fields: {
        'lat': lat.toString(),
        'lng': lng.toString(),
        'takenAt': _clock().toUtc().toIso8601String(),
        'spawnId': ?spawnId,
        'placeId': ?placeId,
      },
      files: [MultipartPart('photo', jpegBytes, filename: 'catch.jpg')],
    ) as Map<String, dynamic>;
    final catchId = json['catchId'].toString();

    final polls = maxWait.inMilliseconds ~/ pollInterval.inMilliseconds;
    for (var i = 0; i < polls; i++) {
      await _sleep(pollInterval);
      try {
        final res = CatchPhotoResponse.fromJson(
            await _api.get('/catches/$catchId', auth: true) as Map<String, dynamic>);
        if (res.status != CatchStatus.pending) return res;
      } on ApiException catch (e) {
        if (e.status != 404 && e.status < 500) rethrow;
      } catch (e) {
        if (!isNetworkError(e)) rethrow;
      }
    }
    return CatchPhotoResponse(
        catchId: catchId, status: CatchStatus.pending, timedOut: true);
  }
}

/// null in demo mode (no backend → no AI analysis, survey only).
final catchRepositoryProvider = Provider<CatchRepository?>(
    (ref) => useApi ? CatchRepository(ref.watch(apiClientProvider)) : null);
