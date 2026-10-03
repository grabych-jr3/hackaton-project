package pl.krakowbezbarier.api.common;

/** Small geo helpers. Remember: JSON uses lat/lng, PostGIS/GeoJSON uses x=lng, y=lat. */
public final class GeoUtils {
    private GeoUtils() {}

    public record BBox(double minLng, double minLat, double maxLng, double maxLat) {}

    /** Parses {@code minLng,minLat,maxLng,maxLat}. */
    public static BBox parseBbox(String bbox) {
        if (bbox == null || bbox.isBlank()) return null;
        String[] p = bbox.split(",");
        if (p.length != 4) throw ApiException.badRequest("bbox must be minLng,minLat,maxLng,maxLat");
        try {
            double minLng = Double.parseDouble(p[0].trim()), minLat = Double.parseDouble(p[1].trim());
            double maxLng = Double.parseDouble(p[2].trim()), maxLat = Double.parseDouble(p[3].trim());
            if (minLng > maxLng || minLat > maxLat) throw ApiException.badRequest("bbox min must be <= max");
            return new BBox(minLng, minLat, maxLng, maxLat);
        } catch (NumberFormatException e) {
            throw ApiException.badRequest("bbox must contain 4 numbers");
        }
    }

    /** Great-circle distance in metres. */
    public static double haversineM(double lat1, double lng1, double lat2, double lng2) {
        double r = 6_371_000;
        double dLat = Math.toRadians(lat2 - lat1), dLng = Math.toRadians(lng2 - lng1);
        double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
        return 2 * r * Math.asin(Math.sqrt(a));
    }
}
