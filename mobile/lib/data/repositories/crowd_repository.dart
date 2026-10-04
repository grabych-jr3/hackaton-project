import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../api/api_client.dart';
import '../models/crowd.dart';

/// Why a crowd report was rejected (Polish message for the UI).
class CrowdReportException implements Exception {
  const CrowdReportException(this.message);
  final String message;
  @override
  String toString() => 'CrowdReportException: $message';
}

/// Crowd ("tłumy") layer: `GET /crowd` and `POST /crowd/reports`.
class CrowdRepository {
  CrowdRepository(this._api);

  final ApiClient _api;

  /// Cells within the bounding box; [at] asks for a forecast.
  Future<List<CrowdCell>> getCells({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
    DateTime? at,
  }) async {
    String f(double v) => v.toStringAsFixed(5);
    final bbox = '${f(minLng)},${f(minLat)},${f(maxLng)},${f(maxLat)}';
    final query = 'bbox=${Uri.encodeQueryComponent(bbox)}'
        '${at == null ? '' : '&at=${Uri.encodeQueryComponent(at.toUtc().toIso8601String())}'}';
    return CrowdCell.listFromJson(await _api.get('/crowd?$query'));
  }

  /// [level]: 0 = luźno, 1 = średnio, 2 = tłoczno. Throws
  /// [CrowdReportException] with a Polish message on 429 / 400.
  Future<CrowdReportResult> report(LatLng at, int level) async {
    try {
      final json = await _api.post('/crowd/reports',
          body: {'lat': at.latitude, 'lng': at.longitude, 'level': level},
          auth: true);
      return CrowdReportResult.fromJson(json as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.status == 429) {
        throw const CrowdReportException(
            'To miejsce już oceniłeś — spróbuj ponownie za 30 minut.');
      }
      if (e.status == 400) {
        throw const CrowdReportException(
            'Ocena możliwa tylko na terenie Krakowa.');
      }
      rethrow;
    }
  }
}

/// null in demo mode (no backend).
final crowdRepositoryProvider = Provider<CrowdRepository?>(
    (ref) => useApi ? CrowdRepository(ref.watch(apiClientProvider)) : null);
