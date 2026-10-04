import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/crowd.dart';

/// Crowd layer drawn as a soft "cloud": every honeycomb cell is a radial
/// gradient (no borders) that fades out at its edge and overlaps its
/// neighbours, so busy streets read as a glow rather than a grid.
class CrowdCloudLayer extends StatelessWidget {
  const CrowdCloudLayer({super.key, required this.cells});

  final List<CrowdCell> cells;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return MobileLayerTransformer(
      child: IgnorePointer(
        child: CustomPaint(
          size: Size.infinite,
          painter: _CloudPainter(cells, camera),
        ),
      ),
    );
  }
}

/// Muted app colours: mint (calm) -> amber -> soft red (crowded).
Color crowdCloudColor(double crowd) {
  const calm = AppColors.primary, mid = AppColors.warn, busy = AppColors.bad;
  final c = crowd < 0.5
      ? Color.lerp(calm, mid, crowd / 0.5)!
      : Color.lerp(mid, busy, (crowd - 0.5) / 0.5)!;
  // pull towards the dark background so it is not neon
  return Color.lerp(c, AppColors.background, 0.3)!;
}

/// Opacity at the centre of a cell: quiet places almost invisible.
double crowdCloudAlpha(double crowd) => 1.4 * 1.12 * (0.04 + 0.30 * crowd * crowd);

class _CloudPainter extends CustomPainter {
  _CloudPainter(this.cells, this.camera);

  final List<CrowdCell> cells;
  final MapCamera camera;

  /// Blob radius relative to the cell's circumradius: > 1 so cells blend.
  static const _spread = 1.7;

  @override
  void paint(Canvas canvas, Size size) {
    for (final c in cells) {
      if (c.polygon.length < 4) continue;
      final ring = c.polygon.length > 1 && c.polygon.first == c.polygon.last
          ? c.polygon.sublist(0, c.polygon.length - 1)
          : c.polygon;
      var lat = 0.0, lng = 0.0;
      for (final p in ring) {
        lat += p.latitude;
        lng += p.longitude;
      }
      final center =
          camera.getOffsetFromOrigin(LatLng(lat / ring.length, lng / ring.length));
      final corner = camera.getOffsetFromOrigin(ring.first);
      final radius = (corner - center).distance * _spread;
      if (radius < 1) continue;
      final color = crowdCloudColor(c.crowd);
      final alpha = crowdCloudAlpha(c.crowd);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: alpha * 0.55),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      old.cells != cells ||
      old.camera.zoom != camera.zoom ||
      old.camera.center != camera.center ||
      old.camera.size != camera.size ||
      old.camera.rotation != camera.rotation;
}
