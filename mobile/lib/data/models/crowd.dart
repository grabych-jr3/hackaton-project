import 'package:latlong2/latlong.dart';

/// Crowd level of one grid cell (`GET /crowd`).
enum CrowdLabel {
  low('luźno'),
  medium('średnio'),
  high('tłoczno');

  const CrowdLabel(this.text);

  /// Polish label as sent by the backend.
  final String text;

  static CrowdLabel? parse(Object? s) {
    for (final l in values) {
      if (l.text == s) return l;
    }
    return null;
  }

  /// Fallback when the label is missing: thresholds on the 0..1 score.
  static CrowdLabel fromScore(double crowd) => crowd < 0.34
      ? low
      : crowd < 0.67
          ? medium
          : high;
}

class CrowdCell {
  const CrowdCell({
    required this.id,
    required this.polygon,
    required this.crowd,
    required this.label,
    required this.source,
    this.reports = 0,
    this.updatedAt,
  });

  final String id;

  /// Closed ring of [lat, lng] points.
  final List<LatLng> polygon;

  /// 0..1
  final double crowd;
  final CrowdLabel label;

  /// base | survey | live | forecast
  final String source;
  final int reports;
  final DateTime? updatedAt;

  static CrowdCell? fromJson(Object? j) {
    if (j is! Map) return null;
    final ring = <LatLng>[
      for (final p in j['polygon'] as List? ?? const [])
        if (p is List && p.length >= 2)
          LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
    if (ring.length < 3) return null;
    final crowd = (j['crowd'] as num?)?.toDouble() ?? 0;
    return CrowdCell(
      id: j['id']?.toString() ?? '',
      polygon: ring,
      crowd: crowd,
      label: CrowdLabel.parse(j['label']) ?? CrowdLabel.fromScore(crowd),
      source: j['source'] as String? ?? 'base',
      reports: (j['reports'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse(j['updatedAt']?.toString() ?? ''),
    );
  }

  static List<CrowdCell> listFromJson(Object? json) => [
        for (final c in (json is Map ? json['cells'] as List? : null) ?? const [])
          if (CrowdCell.fromJson(c) case final CrowdCell cell) cell,
      ];
}

/// Response of `POST /crowd/reports`.
class CrowdReportResult {
  const CrowdReportResult({
    required this.cellId,
    required this.awarded,
    this.crowd,
    this.label,
  });

  final String cellId;
  final double? crowd;
  final CrowdLabel? label;
  final int awarded;

  factory CrowdReportResult.fromJson(Map<String, dynamic> j) => CrowdReportResult(
        cellId: j['cellId']?.toString() ?? '',
        crowd: (j['crowd'] as num?)?.toDouble(),
        label: CrowdLabel.parse(j['label']),
        awarded: (j['awarded'] as num?)?.toInt() ?? 0,
      );
}
