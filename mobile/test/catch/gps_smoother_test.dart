import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/features/catch/gps_smoother.dart';

const lat0 = 52.0, lng0 = 21.0;
final t0 = DateTime(2026);

GpsFix fix(double northM, double eastM, double acc, double sec) {
  final p0 = geoOffset(lat0, lng0, 0, northM);
  final p = geoOffset(p0.lat, p0.lng, 90, eastM);
  return GpsFix(
      lat: p.lat,
      lng: p.lng,
      accuracyM: acc,
      time: t0.add(Duration(milliseconds: (sec * 1000).round())));
}

double northOf(SmoothedPosition p) => (p.lat - lat0) * 111320;

void main() {
  test('geo helpers', () {
    final p = geoOffset(lat0, lng0, 90, 10);
    expect(geoDistanceM(lat0, lng0, p.lat, p.lng), closeTo(10, 0.05));
    expect(geoBearingDeg(lat0, lng0, p.lat, p.lng), closeTo(90, 0.1));
    final n = geoOffset(lat0, lng0, 0, 12);
    expect(geoBearingDeg(lat0, lng0, n.lat, n.lng), closeTo(0, 0.01));
  });

  test('first fix is taken as is; error = accuracy', () {
    final s = GpsSmoother();
    expect(s.position, isNull);
    expect(s.add(fix(0, 0, 5, 0)), isTrue);
    expect(s.position!.lat, lat0);
    expect(s.position!.errorM, closeTo(5, 1e-9));
  });

  test('weighting: precise fix pulls hard, sloppy fix barely moves', () {
    final a = GpsSmoother()..add(fix(0, 0, 10, 0));
    a.add(fix(4, 0, 3, 2)); // precise
    final b = GpsSmoother()..add(fix(0, 0, 10, 0));
    b.add(fix(4, 0, 30, 2)); // sloppy
    expect(northOf(a.position!), greaterThan(3));
    expect(northOf(b.position!), lessThan(1));
    // Error shrinks after a precise update.
    expect(a.position!.errorM, lessThan(10));
  });

  test('outliers: jump > 3× accuracy within 1 s rejected, last good fix held', () {
    final s = GpsSmoother()..add(fix(0, 0, 4, 0));
    expect(s.add(fix(20, 0, 4, 0.5)), isFalse);
    expect(northOf(s.position!), closeTo(0, 1e-6));
    expect(s.rejectedCount, 1);
  });

  test('outliers: implied speed > 7 m/s rejected', () {
    final s = GpsSmoother()..add(fix(0, 0, 3, 0));
    expect(s.add(fix(60, 0, 3, 4)), isFalse); // ~13 m/s after slack
    expect(s.add(fix(10, 0, 3, 5)), isTrue); // walking pace OK
  });

  test('persistent jump resets after 3 rejects in a row', () {
    final s = GpsSmoother()..add(fix(0, 0, 3, 0));
    expect(s.add(fix(100, 0, 3, 0.2)), isFalse);
    expect(s.add(fix(100, 0, 3, 0.4)), isFalse);
    expect(s.add(fix(100, 0, 3, 0.6)), isTrue);
    expect(northOf(s.position!), closeTo(100, 0.01));
  });

  test('standing still: jitter averaged, bearing frozen below 1 m', () {
    final s = GpsSmoother();
    final target = geoOffset(lat0, lng0, 0, 12);
    final f = BearingFreeze(targetLat: target.lat, targetLng: target.lng);
    const jitter = [
      [0.0, 0.0], [3.0, -2.0], [-2.5, 3.0], [2.0, 2.5], [-3.0, -1.5], [1.5, -3.0],
      [-1.0, 2.0], [2.5, 1.0], [-2.0, -2.5], [0.5, 3.0],
    ];
    final bearings = <double>{};
    for (var i = 0; i < jitter.length; i++) {
      s.add(fix(jitter[i][0], jitter[i][1], 5, i.toDouble()));
      f.update(s.position!);
      bearings.add(f.bearingDeg!);
    }
    // Smoothed position stays within ~1.5 m of truth despite ±3 m jitter.
    expect(geoDistanceM(lat0, lng0, s.position!.lat, s.position!.lng), lessThan(1.5));
    expect(f.frozen, isTrue);
    // Few bearing recomputations, all close to north.
    expect(bearings.length, lessThan(jitter.length));
    for (final b in bearings) {
      expect((b > 180 ? b - 360 : b).abs(), lessThan(12));
    }
    expect(f.distanceM, closeTo(12, 2));
  });

  test('BearingFreeze recomputes after moving ≥ 1 m', () {
    final target = geoOffset(lat0, lng0, 0, 12);
    final f = BearingFreeze(targetLat: target.lat, targetLng: target.lng);
    SmoothedPosition at(double east) {
      final p = geoOffset(lat0, lng0, 90, east);
      return SmoothedPosition(lat: p.lat, lng: p.lng, errorM: 3, rawAccuracyM: 3);
    }

    f.update(at(0));
    expect(f.bearingDeg, closeTo(0, 0.01));
    f.update(at(0.6));
    expect(f.frozen, isTrue);
    expect(f.bearingDeg, closeTo(0, 0.01));
    f.update(at(5));
    expect(f.frozen, isFalse);
    expect(f.bearingDeg, greaterThan(300)); // target now north-west
  });
}
