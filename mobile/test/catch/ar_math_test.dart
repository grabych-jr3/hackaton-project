import 'package:flutter_test/flutter_test.dart';
import 'package:hackaton_project/features/catch/ar_math.dart';

// Phone upright (portrait), back camera looking horizontally.
const upright = Vec3(0, 9.81, 0);
// Northern-hemisphere field (north + down) when the camera faces N / E / S / W.
const magFacingNorth = Vec3(0, -40, -20);
const magFacingEast = Vec3(-20, -40, 0);
const magFacingSouth = Vec3(0, -40, 20);
const magFacingWest = Vec3(20, -40, 0);

void main() {
  group('heading from sensors', () {
    test('upright phone, camera in the 4 cardinal directions', () {
      expect(headingFromSensors(upright, magFacingNorth), closeTo(0, 1e-6));
      expect(headingFromSensors(upright, magFacingEast), closeTo(90, 1e-6));
      expect(headingFromSensors(upright, magFacingSouth), closeTo(180, 1e-6));
      expect(headingFromSensors(upright, magFacingWest), closeTo(270, 1e-6));
    });

    test('tilt-compensated: camera tilted 30° down still reads north', () {
      // Rotate device about X by 30°: gravity gains a +z component.
      const c = 0.8660254, s = 0.5;
      const accel = Vec3(0, 9.81 * c, 9.81 * s);
      // World field N=20 (−Z when upright), down=40 (−Y) rotated the same way.
      const mag = Vec3(0, -40 * c + 20 * s, -40 * s - 20 * c);
      expect(headingFromSensors(accel, mag), closeTo(0, 1e-6));
    });

    test('flat phone falls back to the top-edge heading', () {
      // Flat face-up, top edge pointing east: north = −X, down = −Z.
      expect(headingFromSensors(const Vec3(0, 0, 9.81), const Vec3(-20, 0, -40)),
          closeTo(90, 1e-6));
    });

    test('degenerate input returns null', () {
      expect(headingFromSensors(upright, const Vec3(0, 0, 0)), isNull);
    });

    test('camera elevation from gravity', () {
      expect(cameraElevationDeg(upright), closeTo(0, 1e-9));
      expect(cameraElevationDeg(const Vec3(0, 0, 9.81)), closeTo(-90, 1e-9));
      expect(cameraElevationDeg(const Vec3(0, 6.94, 6.94)), closeTo(-45, 0.1));
    });

    test('gyro yaw rate: turning right is clockwise (positive)', () {
      expect(headingRateDegPerSec(const Vec3(0, -1, 0), upright), closeTo(57.2958, 1e-3));
    });
  });

  group('angles', () {
    test('wrap', () {
      expect(wrap360(-10), 350);
      expect(wrap360(370), 10);
      expect(wrap180(190), -170);
      expect(wrap180(-190), 170);
      expect(relativeBearing(10, 350), 20);
      expect(relativeBearing(350, 10), -20);
    });

    test('low-pass and fusion cross 0/360 the short way', () {
      expect(lowPassAngle(350, 10, 0.5), closeTo(0, 1e-9));
      final f = fuseHeading(previous: 359, magnetic: 1, gyroRateDegPerSec: 0, dtSec: 0.02);
      expect(wrap180(f), closeTo(-0.96, 1e-9));
      expect(fuseHeading(previous: null, magnetic: 42, gyroRateDegPerSec: 0, dtSec: 0), 42);
      expect(fuseHeading(previous: 10, magnetic: null, gyroRateDegPerSec: 100, dtSec: 0.1), 20);
    });
  });

  group('screen mapping', () {
    test('bearing → x', () {
      expect(screenX(0, 400), 200);
      expect(screenX(30, 400), 400);
      expect(screenX(-15, 400), 100);
    });

    test('FOV visibility', () {
      expect(inFov(29), isTrue);
      expect(inFov(-30), isTrue);
      expect(inFov(31), isFalse);
      expect(inFov(-170), isFalse);
    });

    test('y: at target elevation the creature is centred; tilting up moves it down', () {
      expect(screenY(targetElevationDeg, 400, 800), 400);
      expect(screenY(10, 400, 800), greaterThan(400));
      expect(screenY(-30, 400, 800), lessThan(400));
    });

    test('size by distance', () {
      expect(spriteSizeForDistance(1), 160);
      expect(spriteSizeForDistance(3), 160);
      expect(spriteSizeForDistance(11.5), closeTo(112, 1e-9));
      expect(spriteSizeForDistance(20), 64);
      expect(spriteSizeForDistance(500), 64);
    });
  });

  group('gating and hints', () {
    test('visibility / gating at 5, 15, 25 m (GPS error 4 m)', () {
      expect(arVisibleRadiusM, 20);
      expect(arCatchRadiusM, 20);
      for (final d in [5.0, 15.0]) {
        final mode = arModeFor(distanceM: d, gpsErrorM: 4);
        expect(mode, ArMode.normal, reason: '$d m');
        expect(canCatchAt(relDeg: 0, distanceM: d, mode: mode), isTrue);
        expect(canCatchAt(relDeg: 16, distanceM: d, mode: mode), isFalse);
      }
      final far = arModeFor(distanceM: 25, gpsErrorM: 4);
      expect(far, ArMode.far);
      expect(canCatchAt(relDeg: 0, distanceM: 25, mode: far), isFalse);
      expect(canCatchAt(relDeg: 0, distanceM: 21), isFalse);
    });

    test('near-field: GPS error > distance → bearing unreliable', () {
      final mode = arModeFor(distanceM: 3, gpsErrorM: 8);
      expect(mode, ArMode.nearField);
      // Bearing ignored for the shutter.
      expect(canCatchAt(relDeg: 120, distanceM: 3, mode: mode), isTrue);
      expect(arHint(relDeg: 120, distanceM: 3, mode: mode),
          'Jesteś bardzo blisko — rozejrzyj się');
      // Centred-ish: offset scaled by distance/error.
      expect(nearFieldTargetRel(40, 3, 8), closeTo(15, 1e-9));
      expect(nearFieldTargetRel(40, 10, 8), 40);
      // Drift damped to ≤ 30°/s.
      expect(rateLimitAngle(0, 90, 0.5), closeTo(15, 1e-9));
      expect(rateLimitAngle(0, -90, 0.1), closeTo(-3, 1e-9));
      expect(rateLimitAngle(0, 2, 0.5), closeTo(2, 1e-9));
      expect(rateLimitAngle(175, -175, 1), closeTo(-175, 1e-9)); // wrap
    });

    test('screen EMA in angle space (wrap-safe)', () {
      expect(emaRelAngle(null, 10), 10);
      expect(emaRelAngle(0, 10), closeTo(2, 1e-9));
      expect(emaRelAngle(170, -170), closeTo(174, 1e-9));
    });

    test('hints', () {
      expect(arHint(relDeg: -90, distanceM: 15), 'Obróć się w lewo — stworek 15 m stąd');
      expect(arHint(relDeg: 90, distanceM: 15), 'Obróć się w prawo — stworek 15 m stąd');
      expect(arHint(relDeg: 0, distanceM: 12), 'Stworek przed Tobą — zrób zdjęcie');
      expect(arHint(relDeg: 20, distanceM: 12), 'Wyceluj stworka na środek ekranu');
      expect(arHint(relDeg: 90, distanceM: 35, mode: ArMode.far),
          'Podejdź bliżej — stworek 35 m stąd, kierunek →');
      expect(arHint(relDeg: 0, distanceM: 30), 'Podejdź bliżej — stworek 30 m stąd, kierunek ↑');
      expect(directionArrow(-90), '←');
      expect(directionArrow(180), '↓');
      expect(directionArrow(40), '↗');
    });

    test('magnetometer validity', () {
      expect(magneticFieldLooksValid(magFacingNorth), isTrue);
      expect(magneticFieldLooksValid(const Vec3(0, 0, 5)), isFalse);
      expect(magneticFieldLooksValid(const Vec3(200, 0, 0)), isFalse);
    });
  });
}
