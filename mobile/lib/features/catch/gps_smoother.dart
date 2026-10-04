import 'dart:math';

/// GPS smoothing for the geo-anchored AR sprite (pure, unit-tested).
///
/// Consumer GPS wanders 3–10 m outdoors, which makes an AR creature anchored
/// to a coordinate "float". [GpsSmoother] runs a small accuracy-weighted
/// Kalman filter (random-walk model, independent N/E axes in metres) and
/// rejects outliers; [BearingFreeze] stops bearing/distance updates while the
/// user stands still.

const _mPerDegLat = 111320.0;

/// Great-circle distance (m) — haversine, mean Earth radius.
double geoDistanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dp = p2 - p1, dl = (lng2 - lng1) * pi / 180;
  final a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
  return 2 * r * atan2(sqrt(a), sqrt(1 - a));
}

/// Initial bearing (degrees clockwise from north, 0..360).
double geoBearingDeg(double lat1, double lng1, double lat2, double lng2) {
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dl = (lng2 - lng1) * pi / 180;
  final y = sin(dl) * cos(p2);
  final x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl);
  final d = atan2(y, x) * 180 / pi;
  return (d % 360 + 360) % 360;
}

/// Point [meters] away from ([lat], [lng]) towards [bearingDeg]
/// (flat-earth approximation, fine for tens of metres).
({double lat, double lng}) geoOffset(
    double lat, double lng, double bearingDeg, double meters) {
  final b = bearingDeg * pi / 180;
  return (
    lat: lat + meters * cos(b) / _mPerDegLat,
    lng: lng + meters * sin(b) / (_mPerDegLat * cos(lat * pi / 180)),
  );
}

/// One raw GPS reading.
class GpsFix {
  const GpsFix({
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.time,
  });
  final double lat;
  final double lng;

  /// Reported horizontal accuracy (1σ-ish, metres).
  final double accuracyM;
  final DateTime time;
}

/// Filtered position with its estimated error (metres).
class SmoothedPosition {
  const SmoothedPosition({
    required this.lat,
    required this.lng,
    required this.errorM,
    required this.rawAccuracyM,
  });
  final double lat;
  final double lng;
  final double errorM;

  /// Accuracy reported with the last accepted raw fix.
  final double rawAccuracyM;
}

/// Accuracy-weighted Kalman-like filter on lat/lng with outlier rejection.
///
/// * Update weight K = P / (P + acc²): precise fixes pull hard, sloppy ones
///   barely move the estimate (≈ weighting by 1/accuracy²).
/// * Prediction grows the variance by [walkVariance]·dt (walking user).
/// * Rejected: a jump > 3× accuracy within 1 s, or an implied speed above
///   [maxSpeedMps] (beyond what accuracy can explain). The last good fix is
///   held; after [maxConsecutiveRejects] rejects in a row the filter resets
///   to the new fix (the user really moved / the old fix was the bad one).
class GpsSmoother {
  GpsSmoother({
    this.maxSpeedMps = 7,
    this.walkVariance = 1.5,
    this.maxConsecutiveRejects = 3,
    this.minAccuracyM = 1,
  });

  final double maxSpeedMps;
  final double walkVariance; // m²/s
  final int maxConsecutiveRejects;
  final double minAccuracyM;

  double? _lat, _lng;
  double _var = 0; // m² (per axis)
  double _rawAcc = 0;
  DateTime? _time;
  int _rejectRun = 0;

  /// Total rejected fixes (debug overlay).
  int rejectedCount = 0;

  SmoothedPosition? get position => _lat == null
      ? null
      : SmoothedPosition(lat: _lat!, lng: _lng!, errorM: sqrt(_var), rawAccuracyM: _rawAcc);

  /// Feeds a fix; returns false when it was rejected as an outlier.
  bool add(GpsFix f) {
    final acc = max(f.accuracyM.isFinite ? f.accuracyM : 50.0, minAccuracyM);
    if (_lat == null) {
      _reset(f, acc);
      return true;
    }
    final dt = max(0.0, f.time.difference(_time!).inMicroseconds / 1e6);
    final d = geoDistanceM(_lat!, _lng!, f.lat, f.lng);
    final err = sqrt(_var);
    final jump = dt <= 1 && d > 3 * max(acc, err);
    final tooFast = dt > 0 && max(0.0, d - acc - err) / dt > maxSpeedMps;
    if (jump || tooFast) {
      rejectedCount++;
      if (++_rejectRun >= maxConsecutiveRejects) {
        _reset(f, acc);
        return true;
      }
      return false;
    }
    _rejectRun = 0;
    // Predict.
    final p = _var + walkVariance * dt;
    // Update (per axis, same gain).
    final k = p / (p + acc * acc);
    final cosLat = cos(_lat! * pi / 180);
    final dn = (f.lat - _lat!) * _mPerDegLat;
    final de = (f.lng - _lng!) * _mPerDegLat * cosLat;
    _lat = _lat! + k * dn / _mPerDegLat;
    _lng = _lng! + k * de / (_mPerDegLat * cosLat);
    _var = (1 - k) * p;
    _rawAcc = acc;
    _time = f.time;
    return true;
  }

  void _reset(GpsFix f, double acc) {
    _lat = f.lat;
    _lng = f.lng;
    _var = acc * acc;
    _rawAcc = acc;
    _time = f.time;
    _rejectRun = 0;
  }
}

/// Bearing + distance to a target, recomputed only when the smoothed
/// position moved at least [minMoveM] — prevents jitter while standing.
class BearingFreeze {
  BearingFreeze({required this.targetLat, required this.targetLng, this.minMoveM = 1});

  final double targetLat, targetLng;
  final double minMoveM;
  double? _aLat, _aLng;
  double? bearingDeg;
  double? distanceM;

  /// True when the last [update] was ignored (moved < [minMoveM]).
  bool frozen = false;

  void update(SmoothedPosition p) {
    if (_aLat != null && geoDistanceM(_aLat!, _aLng!, p.lat, p.lng) < minMoveM) {
      frozen = true;
      return;
    }
    frozen = false;
    _aLat = p.lat;
    _aLng = p.lng;
    bearingDeg = geoBearingDeg(p.lat, p.lng, targetLat, targetLng);
    distanceM = geoDistanceM(p.lat, p.lng, targetLat, targetLng);
  }
}
