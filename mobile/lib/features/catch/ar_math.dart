import 'dart:math';

/// Pure math for the geo-anchored AR sprite (unit-tested).

/// Default horizontal camera field of view (degrees) in portrait.
const defaultHorizontalFovDeg = 60.0;

/// Target elevation of the creature (slightly below horizon = on the ground).
const targetElevationDeg = -5.0;

/// Creature is drawn only within this distance (m); beyond → arrow hint.
const arVisibleRadiusM = 20.0;

/// Max distance (m) at which a photo may be taken.
const arCatchRadiusM = 20.0;

/// Near-field (bearing unreliable) max on-screen drift rate (deg/s).
const arNearFieldMaxRateDegPerSec = 30.0;

/// EMA weight of a new sample for the on-screen angle / elevation.
const arScreenEmaAlpha = 0.2;

/// Creature must be within ±this many degrees of the screen centre to shoot.
const catchCenterToleranceDeg = 15.0;

/// Plain 3-vector (device coordinates as delivered by sensors_plus/Android).
class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x, y, z;

  double get length => sqrt(x * x + y * y + z * z);
  Vec3 cross(Vec3 o) => Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 scale(double s) => Vec3(x * s, y * s, z * s);
  Vec3 normalized() {
    final l = length;
    return l == 0 ? this : scale(1 / l);
  }

  @override
  String toString() => 'Vec3($x, $y, $z)';
}

/// Wraps [deg] into [0, 360).
double wrap360(double deg) {
  final r = deg % 360;
  return r < 0 ? r + 360 : r;
}

/// Wraps [deg] into [-180, 180).
double wrap180(double deg) => wrap360(deg + 180) - 180;

/// Tilt-compensated compass heading (degrees clockwise from magnetic north)
/// of the direction the BACK camera looks, from gravity ([accel], m/s², the
/// accelerometer reaction vector) and the magnetic field ([mag], µT).
///
/// Same construction as Android `SensorManager.getRotationMatrix`:
/// H = E × A (east), M = A × H (north). The back camera looks along −Z of
/// the device; its heading is atan2(east, north) of −Z expressed in world
/// coordinates. When the phone lies almost flat (−Z ≈ straight down) the top
/// edge (+Y) heading is used instead. Returns null for degenerate input.
double? headingFromSensors(Vec3 accel, Vec3 mag) {
  final a = accel.normalized();
  final h = mag.cross(accel);
  if (h.length < 1e-6 || accel.length < 1e-6) return null;
  final hn = h.normalized();
  final m = a.cross(hn);
  // Rotation matrix rows: [hn; m; a]. Column 2 = device Z in world (E,N,U).
  final camEast = -hn.z, camNorth = -m.z;
  final double rad;
  if (sqrt(camEast * camEast + camNorth * camNorth) > 0.3) {
    rad = atan2(camEast, camNorth);
  } else {
    rad = atan2(hn.y, m.y); // flat phone: heading of the top edge
  }
  return wrap360(rad * 180 / pi);
}

/// Elevation (degrees, + above horizon) of the back camera's view direction
/// from gravity: flat face-up = −90, upright = 0.
double cameraElevationDeg(Vec3 accel) {
  final l = accel.length;
  if (l < 1e-6) return 0;
  return asin((-accel.z / l).clamp(-1.0, 1.0)) * 180 / pi;
}

/// Heading rate (deg/s, clockwise) from the gyroscope ([gyro], rad/s) and
/// gravity: rotation about world-up, sign flipped (CCW-positive → compass).
double headingRateDegPerSec(Vec3 gyro, Vec3 accel) {
  final up = accel.normalized();
  return -gyro.dot(up) * 180 / pi;
}

/// Complementary filter step: integrate gyro, pull gently to the compass.
/// Handles the 0/360 wrap.
double fuseHeading({
  required double? previous,
  required double? magnetic,
  required double gyroRateDegPerSec,
  required double dtSec,
  double gyroWeight = 0.98,
}) {
  if (previous == null) return wrap360(magnetic ?? 0);
  final predicted = previous + gyroRateDegPerSec * dtSec;
  if (magnetic == null) return wrap360(predicted);
  return wrap360(magnetic + gyroWeight * wrap180(predicted - magnetic));
}

/// Low-pass for an angle in degrees (wrap-safe). [alpha] = weight of new.
double lowPassAngle(double? previous, double next, double alpha) {
  if (previous == null) return wrap360(next);
  return wrap360(previous + alpha * wrap180(next - previous));
}

/// Signed angle (−180..180) from the camera heading to the creature bearing.
double relativeBearing(double bearingDeg, double headingDeg) =>
    wrap180(bearingDeg - headingDeg);

/// Whether a relative angle is inside the horizontal FOV.
bool inFov(double relDeg, {double fovDeg = defaultHorizontalFovDeg}) =>
    relDeg.abs() <= fovDeg / 2;

/// Horizontal screen x of the creature centre.
double screenX(double relDeg, double width, {double fovDeg = defaultHorizontalFovDeg}) =>
    width / 2 + relDeg / (fovDeg / 2) * (width / 2);

/// Vertical screen y: creature at [targetElevationDeg]; tilting the camera
/// up moves it down the screen. Vertical FOV derived from the aspect ratio.
double screenY(double elevationDeg, double width, double height,
    {double fovDeg = defaultHorizontalFovDeg}) {
  final vFov = fovDeg * height / width;
  final rel = targetElevationDeg - elevationDeg;
  return height / 2 - rel / (vFov / 2) * (height / 2);
}

/// Sprite size: 160 px at ≤3 m down to 64 px at ≥[arVisibleRadiusM] (linear).
double spriteSizeForDistance(double meters) {
  const near = 3.0, far = arVisibleRadiusM, big = 160.0, small = 64.0;
  if (meters <= near) return big;
  if (meters >= far) return small;
  return big - (meters - near) / (far - near) * (big - small);
}

/// How the creature is presented for the current distance / GPS error.
enum ArMode {
  /// Beyond [arVisibleRadiusM]: sprite hidden, radar/arrow hint.
  far,

  /// GPS error larger than the distance: bearing unreliable, sprite shown
  /// near the centre with damped drift.
  nearField,

  /// Normal geo-anchored placement.
  normal,
}

ArMode arModeFor({required double distanceM, required double gpsErrorM}) {
  if (distanceM > arVisibleRadiusM) return ArMode.far;
  if (gpsErrorM > distanceM) return ArMode.nearField;
  return ArMode.normal;
}

/// Shutter allowed: within [arCatchRadiusM] and centred (±15°); in near-field
/// mode the bearing is meaningless, so only the distance counts.
bool canCatchAt({
  required double relDeg,
  required double distanceM,
  ArMode mode = ArMode.normal,
}) {
  if (distanceM > arCatchRadiusM || mode == ArMode.far) return false;
  return mode == ArMode.nearField || relDeg.abs() <= catchCenterToleranceDeg;
}

/// Target on-screen angle in near-field mode: the raw relative bearing
/// scaled by how trustworthy it is (distance / error < 1) → centred-ish.
double nearFieldTargetRel(double relDeg, double distanceM, double gpsErrorM) {
  if (gpsErrorM <= 0) return relDeg;
  return relDeg * (distanceM / gpsErrorM).clamp(0.0, 1.0);
}

/// Moves [previous] towards [target] (degrees, wrap-safe) by at most
/// [maxRateDegPerSec]·[dtSec].
double rateLimitAngle(double previous, double target, double dtSec,
    {double maxRateDegPerSec = arNearFieldMaxRateDegPerSec}) {
  final step = maxRateDegPerSec * max(0.0, dtSec);
  return wrap180(previous + wrap180(target - previous).clamp(-step, step));
}

/// EMA in angle space for a relative angle (−180..180). [alpha] = new weight.
double emaRelAngle(double? previous, double next, {double alpha = arScreenEmaAlpha}) {
  if (previous == null) return wrap180(next);
  return wrap180(previous + alpha * wrap180(next - previous));
}

/// Arrow pointing to the creature relative to where the camera looks.
String directionArrow(double relDeg) {
  const arrows = ['↑', '↗', '→', '↘', '↓', '↙', '←', '↖'];
  return arrows[(wrap360(relDeg + 22.5) ~/ 45) % 8];
}

/// Plausible Earth field strength (µT); outside → compass needs calibration.
bool magneticFieldLooksValid(Vec3 mag) {
  final l = mag.length;
  return l >= 20 && l <= 75;
}

/// Hint for the current state (Polish UI).
String arHint({
  required double relDeg,
  required double distanceM,
  ArMode mode = ArMode.normal,
  double fovDeg = defaultHorizontalFovDeg,
}) {
  final m = distanceM.round();
  if (mode == ArMode.far || distanceM > arVisibleRadiusM) {
    return 'Podejdź bliżej — stworek $m m stąd, kierunek ${directionArrow(relDeg)}';
  }
  if (mode == ArMode.nearField) return 'Jesteś bardzo blisko — rozejrzyj się';
  if (!inFov(relDeg, fovDeg: fovDeg)) {
    final side = relDeg < 0 ? 'w lewo' : 'w prawo';
    return 'Obróć się $side — stworek $m m stąd';
  }
  if (relDeg.abs() > catchCenterToleranceDeg) {
    return 'Wyceluj stworka na środek ekranu';
  }
  return 'Stworek przed Tobą — zrób zdjęcie';
}
