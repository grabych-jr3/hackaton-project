import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../features/game/game_models.dart';

/// Repository for submitting photos to the backend and polling for results.
class CatchRepository {
  CatchRepository({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// Submits a photo as multipart to POST /api/v1/catches,
  /// then polls GET /api/v1/catches/{id} until status != PENDING.
  Future<CatchPhotoResponse> submitPhoto({
    required List<int> jpegBytes,
    required double lat,
    required double lng,
    String? spawnId,
    String? placeId,
  }) async {
    // 1. POST multipart
    final uri = Uri.parse('$baseUrl/api/v1/catches');
    final request = http.MultipartRequest('POST', uri)
      ..fields['lat'] = lat.toString()
      ..fields['lng'] = lng.toString()
      ..fields['takenAt'] = DateTime.now().toUtc().toIso8601String()
      ..files.add(http.MultipartFile.fromBytes(
        'photo',
        jpegBytes,
        filename: 'catch.jpg',
      ));
    if (spawnId != null) request.fields['spawnId'] = spawnId;
    if (placeId != null) request.fields['placeId'] = placeId;

    final streamedResponse = await request.send();
    final postBody = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 202 && streamedResponse.statusCode != 200) {
      return CatchPhotoResponse(
        catchId: '',
        status: 'FAILED',
        reason: 'HTTP ${streamedResponse.statusCode}: $postBody',
      );
    }

    final postJson = jsonDecode(postBody) as Map<String, dynamic>;
    final catchId = postJson['catchId'] as String;

    // 2. Poll until not PENDING (max ~30 seconds)
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 1500));
      final pollUri = Uri.parse('$baseUrl/api/v1/catches/$catchId');
      final pollResp = await _client.get(pollUri);
      if (pollResp.statusCode != 200) continue;
      final pollJson = jsonDecode(pollResp.body) as Map<String, dynamic>;
      final resp = CatchPhotoResponse.fromJson(pollJson);
      if (!resp.isPending) return resp;
    }

    // Timeout
    return CatchPhotoResponse(
      catchId: catchId,
      status: 'PENDING',
      reason: 'Analiza trwa dłużej niż zwykle. Sprawdź później.',
    );
  }

  void dispose() => _client.close();
}
