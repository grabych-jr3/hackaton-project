package pl.krakowbezbarier.api.crowd;

import pl.krakowbezbarier.api.common.GeoUtils.BBox;

import java.util.ArrayList;
import java.util.List;

/**
 * Regular ~sizeM x sizeM grid over a city bbox. Cell ids are {@code city:x:y} (x = column from west, y = row from south).
 * Pure math, so a point is mapped to its cell without PostGIS.
 */
public record CrowdGrid(String cityId, BBox bbox, double stepLng, double stepLat, int cols, int rows) {
    static final double M_PER_DEG_LAT = 111_320.0;

    public static CrowdGrid of(String cityId, BBox b, int sizeM) {
        double midLat = (b.minLat() + b.maxLat()) / 2;
        double stepLat = sizeM / M_PER_DEG_LAT;
        double stepLng = sizeM / (M_PER_DEG_LAT * Math.cos(Math.toRadians(midLat)));
        int cols = (int) Math.ceil((b.maxLng() - b.minLng()) / stepLng);
        int rows = (int) Math.ceil((b.maxLat() - b.minLat()) / stepLat);
        return new CrowdGrid(cityId, b, stepLng, stepLat, cols, rows);
    }

    /** Cell id containing the point, or null when it is outside the grid. */
    public String cellAt(double lat, double lng) {
        int x = (int) Math.floor((lng - bbox.minLng()) / stepLng);
        int y = (int) Math.floor((lat - bbox.minLat()) / stepLat);
        if (x < 0 || y < 0 || x >= cols || y >= rows) return null;
        return id(x, y);
    }

    public String id(int x, int y) { return cityId + ":" + x + ":" + y; }

    /** Ring of [lat, lng] pairs (Flutter order), closed. */
    public List<double[]> polygon(int x, int y) {
        double w = bbox.minLng() + x * stepLng, s = bbox.minLat() + y * stepLat;
        double e = w + stepLng, n = s + stepLat;
        return List.of(new double[]{s, w}, new double[]{n, w}, new double[]{n, e}, new double[]{s, e}, new double[]{s, w});
    }

    /** [x, y] parsed from a cell id of this grid. */
    public static int[] xy(String cellId) {
        String[] p = cellId.split(":");
        return new int[]{Integer.parseInt(p[p.length - 2]), Integer.parseInt(p[p.length - 1])};
    }

    public List<int[]> allCells() {
        List<int[]> out = new ArrayList<>(cols * rows);
        for (int x = 0; x < cols; x++) for (int y = 0; y < rows; y++) out.add(new int[]{x, y});
        return out;
    }
}
