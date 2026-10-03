/// Accessibility parameter a fact describes (TZ, section 4.4.1).
enum Feature {
  steps,
  kerbHeight,
  doorWidth,
  incline,
  ramp,
  elevator,
  toilet,
  bench,
  disabledParking;

  static Feature fromJson(String value) =>
      Feature.values.firstWhere((f) => f.name == value);
}

/// Where a fact comes from (TZ, section 5).
enum DataSource {
  osm,
  msip,
  otwarteDane,
  owner,
  user,
  ai,
  estimate;

  static DataSource fromJson(String value) =>
      DataSource.values.firstWhere((s) => s.name == value);

  bool get isOpenData =>
      this == osm || this == msip || this == otwarteDane;
}

/// Trust level shown next to every fact (TZ, section 5).
enum TrustLevel {
  confirmed,
  openData,
  reported,
  ai,
  estimate,
  conflicting,
  outdated,
  noData,
}

class AccessibilityFact {
  const AccessibilityFact({
    required this.feature,
    required this.value,
    required this.source,
    required this.fetchedAt,
    this.sourceRef,
    this.confirmedAt,
    this.confirmations = 0,
    this.disputes = 0,
    this.id,
  });

  /// Backend id (null for bundled demo data); needed to confirm/dispute.
  final String? id;

  /// Facts older than this are shown as "Nieaktualne".
  static const outdatedAfter = Duration(days: 365);

  final Feature feature;

  /// int (steps, cm, %), bool (ramp, toilet...) or String range ("3-7").
  final Object value;
  final DataSource source;
  final String? sourceRef;
  final DateTime fetchedAt;
  final DateTime? confirmedAt;
  final int confirmations;
  final int disputes;

  DateTime get lastVerified => confirmedAt ?? fetchedAt;

  num? get number => value is num ? value as num : null;
  bool? get flag => value is bool ? value as bool : null;

  /// Trust of a single fact. Conflicts between facts are detected on [Place].
  TrustLevel trustAt(DateTime now) {
    if (now.difference(lastVerified) > outdatedAfter) return TrustLevel.outdated;
    if (disputes >= 2) return TrustLevel.conflicting;
    if (source == DataSource.owner) return TrustLevel.confirmed;
    if (source.isOpenData && confirmations >= 2) return TrustLevel.confirmed;
    if (confirmations >= 3) return TrustLevel.confirmed;
    if (source.isOpenData) return TrustLevel.openData;
    return switch (source) {
      DataSource.ai => TrustLevel.ai,
      DataSource.estimate => TrustLevel.estimate,
      _ => TrustLevel.reported,
    };
  }

  factory AccessibilityFact.fromJson(Map<String, dynamic> json) {
    return AccessibilityFact(
      id: json['id']?.toString(),
      feature: Feature.fromJson(json['feature'] as String),
      value: json['value'] as Object,
      source: DataSource.fromJson(json['source'] as String),
      sourceRef: json['sourceRef'] as String?,
      fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      confirmedAt: json['confirmedAt'] == null
          ? null
          : DateTime.parse(json['confirmedAt'] as String),
      confirmations: json['confirmations'] as int? ?? 0,
      disputes: json['disputes'] as int? ?? 0,
    );
  }
}
