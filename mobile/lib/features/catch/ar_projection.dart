import 'dart:math' as math;

/// Full 3D AR projection (pure, unit-tested).
///
/// Why: the old azimuth/Euler approach breaks when the phone is held upright
/// in portrait (pitch ≈ −90° → gimbal lock, azimuth undefined). Instead the
/// target is projected through the OS rotation matrix with a pinhole camera.
///
/// ## Frames
/// * World (Android `TYPE_ROTATION_VECTOR`): X = East, Y = **magnetic** North,
///   Z = Up.
/// * Device: x = right of the screen, y = top of the screen, z = out of the
///   screen (towards the user). The back camera looks along **−z**.
///
/// ## Matrix layout (verified in flutter_rotation_sensor 0.2.0 source)
/// The Android plugin sends the raw rotation-vector quaternion (x, y, z, w);
/// Dart `Quaternion.toRotationMatrix()` builds the standard matrix, stored
/// **row-major** (`Matrix3[i]` = row i~/3, col i%3) — identical to Android's
/// `SensorManager.getRotationMatrixFromVector`. It maps device → world:
/// `world = M · device`. Hence columns of M are the device axes in world
/// coordinates and rows of M are the world axes in device coordinates, and
/// `device = Mᵀ · world`:
///   dx = m0·e + m3·n + m6·u
///   dy = m1·e + m4·n + m7·u
///   dz = m2·e + m5·n + m8·u
///
/// Example — phone upright in portrait, back camera facing north:
/// x = East, y = Up, z = South → M = [1,0,0, 0,0,−1, 0,1,0].

/// Magnetic declination for Kraków (NOAA WMM 2025), degrees, positive = east.
const arDeclinationDeg = 6.0;

/// Target is drawn this far below the phone (≈ ground level at hand height).
const arTargetUpM = -1.4;

/// Default field of view of the full 4:3 sensor, portrait orientation.
const arDefaultHFovDeg = 50.0;
const arDefaultVFovDeg = 65.0;

/// Sensor aspect ratio in portrait (width / height).
const arSensorPortraitAspect = 3 / 4;

/// Points closer than this in front of the camera are treated as hidden.
const arMinDepthM = 0.1;

/// Upright portrait facing north (see doc above).
const List<double> arUprightNorthMatrix = [1, 0, 0, 0, 0, -1, 0, 1, 0];

const _earthR = 6371000.0;
double _rad(double d) => d * math.pi / 180;

/// East/North/Up offset (metres, **true** north) from user to target.
({double e, double n, double u}) enuOffset(
    double userLat, double userLng, double targetLat, double targetLng,
    {double up = arTargetUpM}) {
  final dLat = _rad(targetLat - userLat);
  final dLng = _rad(targetLng - userLng);
  return (e: dLng * _earthR * math.cos(_rad(userLat)), n: dLat * _earthR, u: up);
}

/// Converts a true-north ENU offset into the magnetic-north frame used by the
/// rotation vector.
///
/// Sign: with declination D east (+), magnetic north lies at true bearing +D,
/// so a target at true bearing β has magnetic bearing β − D. Rotating the
/// (e, n) vector counter-clockwise (E → N) by D achieves that:
///   e' = e·cosD − n·sinD,  n' = e·sinD + n·cosD.
/// Check: a target at true bearing D (on magnetic north) → e' = 0, n' > 0.
({double e, double n, double u}) trueToMagnetic(
    ({double e, double n, double u}) v,
    {double declinationDeg = arDeclinationDeg}) {
  final d = _rad(declinationDeg);
  final c = math.cos(d), s = math.sin(d);
  return (e: v.e * c - v.n * s, n: v.e * s + v.n * c, u: v.u);
}

/// `device = Mᵀ · world` (row-major M, world = M · device).
({double x, double y, double z}) worldToDevice(
    List<double> m, ({double e, double n, double u}) w) {
  return (
    x: m[0] * w.e + m[3] * w.n + m[6] * w.u,
    y: m[1] * w.e + m[4] * w.n + m[7] * w.u,
    z: m[2] * w.e + m[5] * w.n + m[8] * w.u,
  );
}

/// Camera yaw (degrees clockwise from the matrix's north, 0..360): the back
/// camera's forward axis −z in world coordinates is (−m2, −m5, −m8).
double cameraYawDeg(List<double> m) {
  final d = math.atan2(-m[2], -m[5]) * 180 / math.pi;
  return (d % 360 + 360) % 360;
}

/// Field of view after the BoxFit.cover crop of a [previewAspect] (w/h)
/// preview into a [screen]: tan(f'/2) = tan(f/2) · visible/full.
({double h, double v}) croppedFov({
  required double hFovDeg,
  required double vFovDeg,
  required double screenW,
  required double screenH,
  double previewAspect = arSensorPortraitAspect,
}) {
  final s = screenW / screenH;
  var hFrac = 1.0, vFrac = 1.0;
  if (s < previewAspect) {
    hFrac = s / previewAspect; // sides cut off
  } else {
    vFrac = previewAspect / s; // top/bottom cut off
  }
  double crop(double f, double frac) =>
      2 * math.atan(math.tan(_rad(f) / 2) * frac) * 180 / math.pi;
  return (h: crop(hFovDeg, hFrac), v: crop(vFovDeg, vFrac));
}

/// vFov that keeps the default h/v ratio of tangents for a tuned [hFovDeg].
double vFovForHFov(double hFovDeg) {
  final k = math.tan(_rad(arDefaultVFovDeg) / 2) / math.tan(_rad(arDefaultHFovDeg) / 2);
  return 2 * math.atan(math.tan(_rad(hFovDeg) / 2) * k) * 180 / math.pi;
}

/// Sprite size in px for a distance in metres.
double arSpriteSize(double distanceM) =>
    (1500 / math.max(distanceM, 0.01)).clamp(56.0, 280.0);

/// Result of projecting a target onto the screen.
class ArProjection {
  const ArProjection({
    required this.dx,
    required this.dy,
    required this.dz,
    required this.sx,
    required this.sy,
    required this.size,
    required this.distanceM,
    required this.visible,
    required this.edge,
  });

  /// Target in device coordinates (metres).
  final double dx, dy, dz;

  /// Screen position (px); NaN when behind the camera.
  final double sx, sy;
  final double size;

  /// Horizontal ground distance (m).
  final double distanceM;
  final bool visible;

  /// −1 = arrow on the left, +1 = right, 0 = on screen.
  final int edge;

  double get depth => -dz;
}

/// Projects a true-north ENU target offset through rotation matrix [m].
/// [hFovDeg]/[vFovDeg] are the effective (already cropped) screen FOVs.
ArProjection projectTarget({
  required List<double> m,
  required ({double e, double n, double u}) enu,
  required double screenW,
  required double screenH,
  double hFovDeg = arDefaultHFovDeg,
  double vFovDeg = arDefaultVFovDeg,
  double declinationDeg = arDeclinationDeg,
}) {
  final dist = math.sqrt(enu.e * enu.e + enu.n * enu.n);
  final size = arSpriteSize(dist);
  final d = worldToDevice(m, trueToMagnetic(enu, declinationDeg: declinationDeg));
  final depth = -d.z;
  if (depth <= arMinDepthM) {
    return ArProjection(
        dx: d.x, dy: d.y, dz: d.z, sx: double.nan, sy: double.nan,
        size: size, distanceM: dist, visible: false, edge: d.x < 0 ? -1 : 1);
  }
  final fx = (screenW / 2) / math.tan(_rad(hFovDeg) / 2);
  final fy = (screenH / 2) / math.tan(_rad(vFovDeg) / 2);
  final sx = screenW / 2 + fx * d.x / depth;
  final sy = screenH / 2 - fy * d.y / depth;
  final visible = sx >= -size &&
      sx <= screenW + size &&
      sy >= -size &&
      sy <= screenH + size;
  return ArProjection(
      dx: d.x, dy: d.y, dz: d.z, sx: sx, sy: sy, size: size,
      distanceM: dist, visible: visible,
      edge: visible ? 0 : (sx < screenW / 2 ? -1 : 1));
}

/// Low-pass filter for the on-screen position; never smooths across a
/// hide/show transition (re-appearing sprite jumps straight to its spot).
class ScreenSmoother {
  ScreenSmoother({this.alpha = 0.25});
  final double alpha;
  double? _x, _y;

  ({double x, double y})? add(ArProjection p) {
    if (!p.visible) {
      _x = _y = null;
      return null;
    }
    final px = _x, py = _y;
    _x = px == null ? p.sx : px + alpha * (p.sx - px);
    _y = py == null ? p.sy : py + alpha * (p.sy - py);
    return (x: _x!, y: _y!);
  }
}

/// Rotation matrix (row-major, world = M·device) from gravity + compass
/// heading — fallback when the OS rotation vector is silent.
/// [accel] is the accelerometer reading in device coords (points up at rest);
/// [headingDeg] is the camera (−z) bearing in the same north as the result.
List<double>? matrixFromGravityHeading(
    double ax, double ay, double az, double headingDeg) {
  final gl = math.sqrt(ax * ax + ay * ay + az * az);
  if (gl < 1e-6) return null;
  final u = [ax / gl, ay / gl, az / gl];
  // Camera forward (0,0,−1) projected onto the horizontal plane; if the phone
  // lies flat use the top edge (0,1,0) instead.
  var f = [0.0 + u[0] * u[2], 0.0 + u[1] * u[2], -1.0 + u[2] * u[2]];
  var fl = math.sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
  if (fl < 0.2) {
    f = [-u[1] * u[0], 1 - u[1] * u[1], -u[1] * u[2]];
    fl = math.sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
    if (fl < 1e-6) return null;
  }
  f = [f[0] / fl, f[1] / fl, f[2] / fl];
  // Right (east of forward) R = F × U.
  final r = [
    f[1] * u[2] - f[2] * u[1],
    f[2] * u[0] - f[0] * u[2],
    f[0] * u[1] - f[1] * u[0],
  ];
  final h = _rad(headingDeg), c = math.cos(h), s = math.sin(h);
  final north = [for (var i = 0; i < 3; i++) c * f[i] - s * r[i]];
  final east = [for (var i = 0; i < 3; i++) s * f[i] + c * r[i]];
  // Rows of M = world axes expressed in device coordinates.
  return [...east, ...north, ...u];
}
