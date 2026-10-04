import 'dart:async';
import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/features/catch/ar_math.dart';
import 'package:hackaton_project/features/catch/ar_projection.dart';
import 'package:hackaton_project/features/catch/ar_sensors.dart';

double _r(double d) => d * math.pi / 180;

List<double> _mul(List<double> a, List<double> b) => [
      for (var i = 0; i < 3; i++)
        for (var j = 0; j < 3; j++)
          a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j],
    ];

/// Upright portrait, back camera facing magnetic bearing [yaw]°, then tilted
/// up by [tilt]° (about device x) and rolled by [roll]° (about device z).
List<double> pose({double yaw = 0, double tilt = 0, double roll = 0}) {
  final c = math.cos(_r(yaw)), s = math.sin(_r(yaw));
  final base = [c, 0.0, -s, -s, 0.0, -c, 0.0, 1.0, 0.0];
  final ct = math.cos(_r(tilt)), st = math.sin(_r(tilt));
  final rx = [1.0, 0.0, 0.0, 0.0, ct, -st, 0.0, st, ct];
  final cr = math.cos(_r(roll)), sr = math.sin(_r(roll));
  final rz = [cr, -sr, 0.0, sr, cr, 0.0, 0.0, 0.0, 1.0];
  return _mul(_mul(base, rx), rz);
}

const W = 400.0, H = 800.0;

ArProjection proj(List<double> m, {double e = 0, double n = 15, double decl = 0}) =>
    projectTarget(
        m: m, enu: (e: e, n: n, u: arTargetUpM), screenW: W, screenH: H,
        declinationDeg: decl);

void main() {
  test('pose helper reproduces the documented upright-north matrix', () {
    final m = pose();
    for (var i = 0; i < 9; i++) {
      expect(m[i], closeTo(arUprightNorthMatrix[i], 1e-9));
    }
    expect(cameraYawDeg(pose(yaw: 30)), closeTo(30, 1e-6));
    expect(cameraYawDeg(pose(yaw: -90)), closeTo(270, 1e-6));
  });

  test('north target, phone facing north → horizontally centred', () {
    final p = proj(pose());
    expect(p.visible, isTrue);
    expect(p.depth, closeTo(15, 1e-6));
    expect(p.sx, closeTo(W / 2, 1e-6));
    expect(p.sy, greaterThan(H / 2)); // 1.4 m below eye level
    expect(p.sy, lessThan(H / 2 + 60));
    expect(p.edge, 0);
  });

  test('turned 25° right → target near the left edge (hFov 50°)', () {
    final p = proj(pose(yaw: 25));
    expect(p.sx, closeTo(0, 1));
    expect(p.visible, isTrue); // within screen ± sprite size
  });

  test('turned 90° → hidden, arrow points back (left)', () {
    final p = proj(pose(yaw: 90));
    expect(p.visible, isFalse);
    expect(p.edge, -1);
    final q = proj(pose(yaw: -90));
    expect(q.visible, isFalse);
    expect(q.edge, 1);
  });

  test('target behind → hidden', () {
    final p = proj(pose(), n: -15);
    expect(p.visible, isFalse);
    expect(p.depth, lessThan(0));
    expect(p.sx.isNaN, isTrue);
  });

  test('tilting the phone up moves the sprite down', () {
    final a = proj(pose());
    final b = proj(pose(tilt: 10));
    expect(b.sy, greaterThan(a.sy + 50));
    expect(b.sx, closeTo(a.sx, 1e-6));
  });

  test('roll orbits the sprite around the screen centre', () {
    final a = proj(pose(), e: 3); // right of centre
    final b = proj(pose(roll: 30), e: 3);
    final ra = math.atan2(a.sy - H / 2, a.sx - W / 2);
    final rb = math.atan2(b.sy - H / 2, b.sx - W / 2);
    expect((rb - ra).abs(), greaterThan(_r(10)));
    // Rolling the phone counter-clockwise (+z) turns the scene clockwise on
    // screen; target stays visible.
    expect(b.visible, isTrue);
  });

  test('declination: +6° east rotates true-north targets left of magnetic N', () {
    // Phone faces magnetic north; true-north target is 6° west of it.
    final p = proj(pose(), decl: 6);
    expect(p.sx, lessThan(W / 2 - 20));
    // Phone faces true north (magnetic bearing −6°) → centred.
    final q = proj(pose(yaw: -6), decl: 6);
    expect(q.sx, closeTo(W / 2, 1e-6));
    // Target on magnetic north (true bearing +6°) maps to e' = 0.
    final v = trueToMagnetic(
        (e: 10 * math.sin(_r(6)), n: 10 * math.cos(_r(6)), u: 0),
        declinationDeg: 6);
    expect(v.e, closeTo(0, 1e-9));
    expect(v.n, closeTo(10, 1e-9));
  });

  test('FOV crop for BoxFit.cover', () {
    // 400×800 (1:2) vs 3:4 preview → width cut to 2/3.
    final f = croppedFov(hFovDeg: 50, vFovDeg: 65, screenW: 400, screenH: 800);
    expect(math.tan(_r(f.h) / 2), closeTo(math.tan(_r(25)) * (0.5 / 0.75), 1e-9));
    expect(f.v, closeTo(65, 1e-9));
    // Wider screen than the preview → top/bottom cut.
    final g = croppedFov(hFovDeg: 50, vFovDeg: 65, screenW: 900, screenH: 900);
    expect(g.h, closeTo(50, 1e-9));
    expect(math.tan(_r(g.v) / 2), closeTo(math.tan(_r(32.5)) * 0.75, 1e-9));
    expect(vFovForHFov(arDefaultHFovDeg), closeTo(arDefaultVFovDeg, 1e-9));
  });

  test('sprite size clamps 56..280 px', () {
    expect(arSpriteSize(1), 280);
    expect(arSpriteSize(10), 150);
    expect(arSpriteSize(100), 56);
  });

  test('enuOffset: north/east metres', () {
    final o = enuOffset(50, 20, 50.0001, 20);
    expect(o.n, closeTo(11.12, 0.05));
    expect(o.e, closeTo(0, 1e-9));
    final p = enuOffset(50, 20, 50, 20.0001);
    expect(p.e, closeTo(11.12 * math.cos(_r(50)), 0.05));
  });

  test('ScreenSmoother low-passes, resets across hide/show', () {
    final s = ScreenSmoother();
    final a = proj(pose());
    expect(s.add(a)!.x, closeTo(a.sx, 1e-9));
    final b = proj(pose(yaw: 10));
    final x = s.add(b)!.x;
    expect(x, closeTo(a.sx + 0.25 * (b.sx - a.sx), 1e-9));
    expect(s.add(proj(pose(yaw: 180))), isNull);
    expect(s.add(b)!.x, closeTo(b.sx, 1e-9));
  });

  test('gravity+heading fallback matrix matches the pose', () {
    for (final yaw in [0.0, 37.0, 200.0]) {
      final m = pose(yaw: yaw, tilt: 20);
      // Accelerometer = world Up in device coords = row 2 of M.
      final f = matrixFromGravityHeading(m[6], m[7], m[8], yaw)!;
      for (var i = 0; i < 9; i++) {
        expect(f[i], closeTo(m[i], 1e-9), reason: 'yaw $yaw idx $i');
      }
    }
  });

  test('rotationWithFallback: OS events pass through, silence → fallback', () {
    fakeAsync((fa) {
      final os = StreamController<List<double>>();
      final accel = StreamController<Vec3>.broadcast();
      final compass = StreamController<CompassReading>.broadcast();
      final got = <ArRotationMatrix>[];
      final sub = rotationWithFallback(
              os: os.stream,
              accel: accel.stream,
              compass: compass.stream,
              compassMagnetic: true)
          .listen(got.add);
      os.add(arUprightNorthMatrix);
      fa.flushMicrotasks();
      expect(got.single.source, ArRotationSource.os);
      fa.elapse(const Duration(milliseconds: 1600));
      accel.add(const Vec3(0, 9.81, 0));
      compass.add(const CompassReading(heading: 90, accuracyDeg: 5));
      fa.flushMicrotasks();
      expect(got.last.source, ArRotationSource.fallback);
      expect(cameraYawDeg(got.last), closeTo(90, 1e-6));
      os.add(arUprightNorthMatrix);
      fa.flushMicrotasks();
      expect(got.last.source, ArRotationSource.os);
      sub.cancel();
    });
  });
}
