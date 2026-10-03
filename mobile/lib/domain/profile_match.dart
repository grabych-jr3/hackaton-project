import '../data/models/accessibility_fact.dart';
import '../data/models/needs_profile.dart';
import '../data/models/place.dart';

/// Overall result for a place (TZ, section 4.4.1).
enum Verdict { suitable, partial, notSuitable, insufficientData }

enum CheckStatus { pass, borderline, fail, unknown }

/// Result of checking one parameter of a place against the profile.
class ParamCheck {
  const ParamCheck({
    required this.feature,
    required this.status,
    required this.critical,
    required this.trust,
    this.fact,
    this.note,
  });

  final Feature feature;
  final CheckStatus status;

  /// Critical parameters decide between "Nie pasuje" and "Za mało danych".
  final bool critical;
  final TrustLevel trust;

  /// The fact the decision is based on (the worst trustworthy one).
  final AccessibilityFact? fact;

  /// Extra explanation, e.g. "schody, ale jest winda".
  final String? note;
}

class PlaceMatch {
  const PlaceMatch({required this.verdict, required this.checks});

  final Verdict verdict;
  final List<ParamCheck> checks;

  List<ParamCheck> get problems => checks
      .where((c) => c.status == CheckStatus.fail || c.status == CheckStatus.borderline)
      .toList();

  List<ParamCheck> get missing =>
      checks.where((c) => c.critical && c.status == CheckStatus.unknown).toList();
}

/// Borderline zone around a threshold: ±20%, at least 1 unit.
const _tolerance = 0.2;

PlaceMatch matchPlace(Place place, NeedsProfile profile, DateTime now) {
  final checks = <ParamCheck>[
    _checkSteps(place, profile, now),
    // Kerbs matter mostly on routes; at a place they are not decisive.
    _checkMax(place, Feature.kerbHeight, profile.maxKerbCm, now, critical: false),
    _checkMin(place, Feature.doorWidth, profile.minWidthCm, now),
    _checkMax(place, Feature.incline, profile.maxInclinePct, now, critical: false),
    if (profile.needsToilet) _checkFlag(place, Feature.toilet, now),
    if (profile.needsBenches) _checkFlag(place, Feature.bench, now),
  ];

  bool any(bool Function(ParamCheck c) test) => checks.any(test);

  final Verdict verdict;
  if (any((c) => c.critical && c.status == CheckStatus.fail)) {
    verdict = Verdict.notSuitable;
  } else if (any((c) => c.critical && c.status == CheckStatus.unknown)) {
    verdict = Verdict.insufficientData;
  } else if (any((c) =>
      c.status == CheckStatus.borderline || c.status == CheckStatus.fail)) {
    verdict = Verdict.partial;
  } else {
    verdict = Verdict.suitable;
  }
  return PlaceMatch(verdict: verdict, checks: checks);
}

/// Outdated facts are shown but never used to decide.
List<AccessibilityFact> _usable(Place place, Feature feature, DateTime now) =>
    place
        .factsFor(feature)
        .where((f) => f.trustAt(now) != TrustLevel.outdated)
        .toList();

/// Numeric value; ranges like "3-7", "<70", ">7" become (low, high).
(num, num)? _bounds(Object value) {
  if (value is num) return (value, value);
  if (value is! String) return null;
  final s = value.replaceAll(' ', '');
  if (s.startsWith('<')) {
    final v = num.tryParse(s.substring(1));
    return v == null ? null : (0, v);
  }
  if (s.startsWith('>')) {
    final v = num.tryParse(s.substring(1));
    return v == null ? null : (v, double.infinity);
  }
  final parts = s.split('-');
  if (parts.length == 2) {
    final lo = num.tryParse(parts[0]);
    final hi = num.tryParse(parts[1]);
    if (lo != null && hi != null) return (lo, hi);
  }
  return null;
}

ParamCheck _unknown(Place place, Feature feature, DateTime now,
        {required bool critical}) =>
    ParamCheck(
      feature: feature,
      status: CheckStatus.unknown,
      critical: critical,
      trust: place.trustFor(feature, now),
    );

/// Value must be <= max (kerb, incline). Worst = highest upper bound.
ParamCheck _checkMax(Place place, Feature feature, int max, DateTime now,
    {required bool critical}) {
  AccessibilityFact? worst;
  (num, num)? worstBounds;
  for (final fact in _usable(place, feature, now)) {
    final b = _bounds(fact.value);
    if (b == null) continue;
    if (worstBounds == null || b.$2 > worstBounds.$2) {
      worst = fact;
      worstBounds = b;
    }
  }
  if (worst == null || worstBounds == null) {
    return _unknown(place, feature, now, critical: critical);
  }

  final (lo, hi) = worstBounds;
  final margin = (max * _tolerance).clamp(1, double.infinity);
  final CheckStatus status;
  if (hi <= max) {
    status = CheckStatus.pass;
  } else if (lo <= max || hi <= max + margin) {
    status = CheckStatus.borderline;
  } else {
    status = CheckStatus.fail;
  }
  return ParamCheck(
    feature: feature,
    status: status,
    critical: critical,
    trust: place.trustFor(feature, now),
    fact: worst,
  );
}

/// Value must be >= min (door width). Worst = lowest lower bound.
ParamCheck _checkMin(Place place, Feature feature, int min, DateTime now) {
  AccessibilityFact? worst;
  (num, num)? worstBounds;
  for (final fact in _usable(place, feature, now)) {
    final b = _bounds(fact.value);
    if (b == null) continue;
    if (worstBounds == null || b.$1 < worstBounds.$1) {
      worst = fact;
      worstBounds = b;
    }
  }
  if (worst == null || worstBounds == null) {
    return _unknown(place, feature, now, critical: true);
  }

  final (lo, hi) = worstBounds;
  final CheckStatus status;
  if (lo >= min) {
    status = CheckStatus.pass;
  } else if (hi >= min || lo >= min * (1 - _tolerance)) {
    status = CheckStatus.borderline;
  } else {
    status = CheckStatus.fail;
  }
  return ParamCheck(
    feature: feature,
    status: status,
    critical: true,
    trust: place.trustFor(feature, now),
    fact: worst,
  );
}

/// Steps are passable when a trusted ramp or elevator exists.
ParamCheck _checkSteps(Place place, NeedsProfile profile, DateTime now) {
  final base =
      _checkMax(place, Feature.steps, profile.maxSteps, now, critical: true);
  if (base.status == CheckStatus.pass || base.status == CheckStatus.unknown) {
    return base;
  }

  for (final alt in [Feature.elevator, Feature.ramp]) {
    final usable = _usable(place, alt, now);
    final available = usable.isNotEmpty &&
        usable.every((f) => f.flag == true) &&
        !place.hasConflict(alt, now);
    if (available) {
      return ParamCheck(
        feature: Feature.steps,
        status: CheckStatus.pass,
        critical: true,
        trust: base.trust,
        fact: base.fact,
        note: alt == Feature.elevator
            ? 'Schody, ale jest winda'
            : 'Schody, ale jest podjazd',
      );
    }
  }
  return base;
}

/// Amenity required by the profile (toilet, benches). Not critical.
ParamCheck _checkFlag(Place place, Feature feature, DateTime now) {
  final usable = _usable(place, feature, now);
  if (usable.isEmpty) return _unknown(place, feature, now, critical: false);
  final worst = usable.firstWhere((f) => f.flag == false, orElse: () => usable.first);
  return ParamCheck(
    feature: feature,
    status: worst.flag == true ? CheckStatus.pass : CheckStatus.fail,
    critical: false,
    trust: place.trustFor(feature, now),
    fact: worst,
  );
}
