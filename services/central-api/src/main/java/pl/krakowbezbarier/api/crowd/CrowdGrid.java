package pl.krakowbezbarier.api.crowd;

import pl.krakowbezbarier.api.common.GeoUtils.BBox;

import java.util.*;

/**
 * Hexagonal (honeycomb) grid over a city bbox, pointy-top, axial coordinates (q, r).
 * sizeM is the distance between opposite flat sides (= distance between neighbour centres).
 * Cell ids are {@code city:q:r}. Pure math on a local equirectangular projection, so a point maps to its cell
 * without PostGIS. Cells cover the bbox plus one ring, so every point inside the bbox has a cell.
 */
public final class CrowdGrid {
    static final double M_PER_DEG_LAT = 111_320.0;
    private static final double SQRT3 = Math.sqrt(3);

    private final String cityId;
    private final BBox bbox;
    private final double sizeM;
    /** Circumradius (centre to corner), m. */
    private final double radiusM;
    private final double lat0, lng0, mPerDegLng;
    private final List<int[]> cells = new ArrayList<>();
    private final Set<String> ids = new HashSet<>();

    private CrowdGrid(String cityId, BBox b, double sizeM) {
        this.cityId = cityId;
        this.bbox = b;
        this.sizeM = sizeM;
        this.radiusM = sizeM / SQRT3;
        this.lat0 = b.minLat();
        this.lng0 = b.minLng();
        this.mPerDegLng = M_PER_DEG_LAT * Math.cos(Math.toRadians((b.minLat() + b.maxLat()) / 2));
        double w = (b.maxLng() - b.minLng()) * mPerDegLng, h = (b.maxLat() - b.minLat()) * M_PER_DEG_LAT;
        int rMax = (int) Math.ceil(h / (1.5 * radiusM)) + 1;
        for (int r = -1; r <= rMax; r++) {
            int qFrom = (int) Math.floor(-r / 2.0) - 1, qTo = (int) Math.ceil(w / sizeM - r / 2.0) + 1;
            for (int q = qFrom; q <= qTo; q++) {
                double[] c = centerM(q, r);
                if (c[0] < -sizeM || c[0] > w + sizeM || c[1] < -sizeM || c[1] > h + sizeM) continue;
                cells.add(new int[]{q, r});
                ids.add(id(q, r));
            }
        }
    }

    public static CrowdGrid of(String cityId, BBox b, int sizeM) { return new CrowdGrid(cityId, b, sizeM); }

    public String cityId() { return cityId; }
    public BBox bbox() { return bbox; }
    public double sizeM() { return sizeM; }
    public double radiusM() { return radiusM; }

    /** Cell centre in local metres {x east, y north}. */
    private double[] centerM(int q, int r) {
        return new double[]{sizeM * (q + r / 2.0), 1.5 * radiusM * r};
    }

    /** Cell id containing the point, or null when it is outside the grid. */
    public String cellAt(double lat, double lng) {
        double x = (lng - lng0) * mPerDegLng, y = (lat - lat0) * M_PER_DEG_LAT;
        double fq = (SQRT3 / 3 * x - y / 3) / radiusM, fr = (2.0 / 3 * y) / radiusM;
        // cube rounding
        double fs = -fq - fr;
        long q = Math.round(fq), r = Math.round(fr), s = Math.round(fs);
        double dq = Math.abs(q - fq), dr = Math.abs(r - fr), ds = Math.abs(s - fs);
        if (dq > dr && dq > ds) q = -r - s;
        else if (dr > ds) r = -q - s;
        String id = id((int) q, (int) r);
        return ids.contains(id) ? id : null;
    }

    public String id(int q, int r) { return cityId + ":" + q + ":" + r; }

    /** Centre as {lat, lng}. */
    public double[] center(int q, int r) {
        double[] m = centerM(q, r);
        return new double[]{lat0 + m[1] / M_PER_DEG_LAT, lng0 + m[0] / mPerDegLng};
    }

    /** Closed ring of 7 [lat, lng] pairs (Flutter order). */
    public List<double[]> polygon(int q, int r) {
        double[] c = centerM(q, r);
        List<double[]> ring = new ArrayList<>(7);
        for (int i = 0; i <= 6; i++) {
            double a = Math.toRadians(60 * (i % 6) - 30);
            double x = c[0] + radiusM * Math.cos(a), y = c[1] + radiusM * Math.sin(a);
            ring.add(new double[]{lat0 + y / M_PER_DEG_LAT, lng0 + x / mPerDegLng});
        }
        return ring;
    }

    /** True when the cell (its circumscribed box) touches the bbox. */
    public boolean intersects(int q, int r, BBox b) {
        double[] c = center(q, r);
        double dLat = radiusM / M_PER_DEG_LAT, dLng = radiusM / mPerDegLng;
        return c[0] - dLat <= b.maxLat() && c[0] + dLat >= b.minLat() && c[1] - dLng <= b.maxLng() && c[1] + dLng >= b.minLng();
    }

    /** [q, r] parsed from a cell id of this grid. */
    public static int[] xy(String cellId) {
        String[] p = cellId.split(":");
        return new int[]{Integer.parseInt(p[p.length - 2]), Integer.parseInt(p[p.length - 1])};
    }

    public List<int[]> allCells() { return Collections.unmodifiableList(cells); }
}
