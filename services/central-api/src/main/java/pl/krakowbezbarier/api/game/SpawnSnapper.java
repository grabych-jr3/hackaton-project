package pl.krakowbezbarier.api.game;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.web.client.RestClient;
import pl.krakowbezbarier.api.route.OrsClient;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Moves a spawn point out of buildings onto an outdoor walkable spot.
 * 1) ORS Snap (foot-walking, radius 60 m); 2) Overpass: if the point is inside a building polygon,
 * move it to the nearest footway/street within 60 m; 3) otherwise keep the original point.
 */
@Component
public class SpawnSnapper {
    private static final Logger log = LoggerFactory.getLogger(SpawnSnapper.class);
    static final int RADIUS_M = 60;
    static final List<String> DEFAULT_MIRRORS = List.of(
            "https://overpass-api.de/api/interpreter",
            "https://lz4.overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter");

    public enum Method { ors, overpass, outdoor, original }

    public record Result(double lat, double lng, Method method, double movedM) {}

    @FunctionalInterface
    interface OrsSnap { double[] snap(double lat, double lng) throws Exception; }

    @FunctionalInterface
    interface Overpass { String query(String url, String ql) throws Exception; }

    private final OrsSnap ors;          // null = no key
    private final Overpass overpass;
    private final List<String> mirrors;
    private final ObjectMapper om = new ObjectMapper();

    @Autowired
    public SpawnSnapper(OrsClient orsClient, @Value("${app.overpass.urls:}") String urls) {
        this(orsClient.hasKey() ? (lat, lng) -> orsClient.snap("foot-walking", lat, lng, RADIUS_M) : null,
                restOverpass(), parse(urls));
    }

    SpawnSnapper(OrsSnap ors, Overpass overpass, List<String> mirrors) {
        this.ors = ors;
        this.overpass = overpass;
        this.mirrors = mirrors == null || mirrors.isEmpty() ? DEFAULT_MIRRORS : List.copyOf(mirrors);
    }

    private static List<String> parse(String csv) {
        if (csv == null) return List.of();
        return Arrays.stream(csv.split(",")).map(String::trim).filter(s -> !s.isEmpty()).toList();
    }

    private static Overpass restOverpass() {
        var rf = new SimpleClientHttpRequestFactory();
        rf.setConnectTimeout(5_000);
        rf.setReadTimeout(5_000);
        RestClient client = RestClient.builder().requestFactory(rf)
                .defaultHeader("User-Agent", "krakow-bez-barier/0.1 (hackathon)").build();
        return (url, ql) -> {
            var form = new LinkedMultiValueMap<String, String>();
            form.add("data", ql);
            return client.post().uri(url).contentType(MediaType.APPLICATION_FORM_URLENCODED).body(form)
                    .retrieve().body(String.class);
        };
    }

    public Result snap(double lat, double lng) {
        if (ors != null) {
            try {
                double[] r = ors.snap(lat, lng);
                if (r != null && r[2] <= RADIUS_M) return new Result(r[0], r[1], Method.ors, distM(lat, lng, r[0], r[1]));
            } catch (Exception e) {
                log.debug("ORS snap failed: {}", e.getMessage());
            }
        }
        String ql = String.format(java.util.Locale.ROOT, """
                [out:json][timeout:5];
                way["building"](around:15,%1$.7f,%2$.7f);out geom;
                way["highway"~"^(footway|pedestrian|path|living_street|residential|service)$"](around:%3$d,%1$.7f,%2$.7f);out geom;""",
                lat, lng, RADIUS_M);
        for (String url : mirrors) {
            try {
                Result r = fromOverpass(lat, lng, om.readTree(overpass.query(url, ql)));
                if (r != null) return r;
            } catch (Exception e) {
                log.debug("Overpass mirror {} failed: {}", url, e.getMessage());
            }
        }
        return new Result(lat, lng, Method.original, 0);
    }

    /** null when the answer is unusable (caller tries the next mirror). */
    static Result fromOverpass(double lat, double lng, JsonNode json) {
        JsonNode els = json.path("elements");
        if (!els.isArray()) return null;
        boolean inside = false;
        List<double[][]> roads = new ArrayList<>();
        for (JsonNode el : els) {
            double[][] g = geom(el.path("geometry"));
            if (g.length < 2) continue;
            if (el.path("tags").has("building")) {
                if (pointInPolygon(lat, lng, g)) inside = true;
            } else if (el.path("tags").has("highway")) {
                roads.add(g);
            }
        }
        if (!inside) return new Result(lat, lng, Method.outdoor, 0);
        double best = Double.MAX_VALUE;
        double[] bp = null;
        for (double[][] g : roads) {
            for (int i = 0; i + 1 < g.length; i++) {
                double[] p = nearestOnSegment(lat, lng, g[i], g[i + 1]);
                double d = distM(lat, lng, p[0], p[1]);
                if (d < best) { best = d; bp = p; }
            }
        }
        if (bp == null || best > RADIUS_M) return new Result(lat, lng, Method.original, 0);
        return new Result(bp[0], bp[1], Method.overpass, best);
    }

    private static double[][] geom(JsonNode g) {
        if (!g.isArray()) return new double[0][];
        double[][] out = new double[g.size()][];
        for (int i = 0; i < g.size(); i++) out[i] = new double[]{g.get(i).path("lat").asDouble(), g.get(i).path("lon").asDouble()};
        return out;
    }

    static boolean pointInPolygon(double lat, double lng, double[][] poly) {
        boolean in = false;
        for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
            double yi = poly[i][0], xi = poly[i][1], yj = poly[j][0], xj = poly[j][1];
            if ((yi > lat) != (yj > lat) && lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) in = !in;
        }
        return in;
    }

    /** Projection on a segment in a local equirectangular frame (fine for < 100 m). */
    static double[] nearestOnSegment(double lat, double lng, double[] a, double[] b) {
        double k = Math.cos(Math.toRadians(lat));
        double ax = a[1] * k, ay = a[0], bx = b[1] * k, by = b[0], px = lng * k, py = lat;
        double dx = bx - ax, dy = by - ay, len = dx * dx + dy * dy;
        double t = len == 0 ? 0 : Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len));
        return new double[]{ay + t * dy, (ax + t * dx) / k};
    }

    static double distM(double lat1, double lng1, double lat2, double lng2) {
        double r = 6_371_000, dLat = Math.toRadians(lat2 - lat1), dLng = Math.toRadians(lng2 - lng1);
        double h = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
        return 2 * r * Math.asin(Math.sqrt(h));
    }
}
