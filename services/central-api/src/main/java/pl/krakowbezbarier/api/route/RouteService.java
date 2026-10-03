package pl.krakowbezbarier.api.route;

import com.fasterxml.jackson.databind.JsonNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import pl.krakowbezbarier.api.common.GeoUtils;
import pl.krakowbezbarier.api.route.OrsClient.OrsException;
import pl.krakowbezbarier.api.route.RouteDtos.*;

import java.time.Duration;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.IntStream;

/**
 * Route proxy to OpenRouteService with a 10-min cache.
 * <ol>
 *   <li>Primary: normal pedestrian route (foot-walking); spans not passable for the user's profile
 *       (steps, too steep, bad surface) are returned as {@code barriers} (geometry index spans).</li>
 *   <li>If there are barriers: wheelchair route as {@code alternative}
 *       (restricted -> one retry without restrictions, relaxed=true -> omitted if both fail).</li>
 *   <li>If the primary fails: straight-line fallback with a Polish fallbackReason.</li>
 * </ol>
 */
@Service
public class RouteService {
    private static final Logger log = LoggerFactory.getLogger(RouteService.class);
    static final String FOOT = "foot-walking";
    static final String WHEELCHAIR = "wheelchair";
    /** Rough wheelchair speed used for the fallback, m/s. */
    static final double FALLBACK_SPEED = 1.1;
    static final int DEFAULT_MIN_WIDTH_CM = 75;
    static final int DEFAULT_MAX_INCLINE_PCT = 6;
    /** ORS codes meaning "no route for these constraints/points" - worth a relaxed retry. */
    static final Set<Integer> RETRY_CODES = Set.of(2004, 2009, 2010, 2099);

    // ORS extra_info ids (https://giscience.github.io/openrouteservice/api-reference/endpoints/directions/extra-info/)
    static final int WAYTYPE_STEPS = 8;
    /** steepness class (abs) -> lower bound of its grade, %. */
    private static final int[] STEEP_LOWER = {0, 1, 4, 7, 10, 16};
    private static final String[] STEEP_DETAIL = {null, "ok. 2%", "ok. 5%", "ok. 8%", "ok. 12%", "ponad 15%"};

    private final OrsClient ors;
    private final Duration cacheTtl;
    private final Map<RouteRequest, CacheEntry> cache = new ConcurrentHashMap<>();

    private record CacheEntry(RouteResponse response, Instant expires) {}

    public RouteService(OrsClient ors, @Value("${app.ors.cache-minutes:10}") int cacheMinutes) {
        this.ors = ors;
        this.cacheTtl = Duration.ofMinutes(cacheMinutes);
    }

    public RouteResponse route(RouteRequest req) {
        Instant now = Instant.now();
        CacheEntry hit = cache.get(req);
        if (hit != null && hit.expires().isAfter(now)) return hit.response();
        if (cache.size() > 1000) cache.entrySet().removeIf(e -> e.getValue().expires().isBefore(now));

        if (!ors.hasKey()) {
            log.warn("ORS_API_KEY not set - returning straight-line fallback");
            return fallback(req, "Brak klucza OpenRouteService");
        }
        int n = req.points().size();
        RouteResponse res;
        try {
            JsonNode body = ors.directions(FOOT, orsBody(req, false));
            res = parseOrs(body, n, false, FOOT);
            List<Barrier> barriers = barriers(body, req.profile());
            res = res.withBarriers(barriers, barriers.isEmpty());
        } catch (OrsException e) {
            logOrs(FOOT, e, false);
            return fallback(req, reason(e));
        } catch (RuntimeException e) {
            log.warn("ORS response unparseable ({})", e.getClass().getSimpleName());
            return fallback(req, "OpenRouteService: nieprawidłowa odpowiedź");
        }
        if (!res.barriers().isEmpty()) res = res.withAlternative(wheelchair(req));
        cache.put(req, new CacheEntry(res, now.plus(cacheTtl)));
        return res;
    }

    /** Wheelchair route: restricted, then once without restrictions (relaxed). null if both fail. */
    RouteResponse wheelchair(RouteRequest req) {
        int n = req.points().size();
        try {
            return parseOrs(ors.directions(WHEELCHAIR, orsBody(req, true)), n, false, WHEELCHAIR);
        } catch (OrsException e) {
            logOrs(WHEELCHAIR, e, true);
            if (!retryable(e)) return null;
        } catch (RuntimeException e) {
            log.warn("ORS wheelchair response unparseable ({})", e.getClass().getSimpleName());
            return null;
        }
        try {
            // relaxed: the route ignores the user's thresholds, so it is not marked accessible
            return parseOrs(ors.directions(WHEELCHAIR, orsBody(req, false)), n, true, WHEELCHAIR)
                    .withBarriers(List.of(), false);
        } catch (OrsException e) {
            logOrs(WHEELCHAIR, e, false);
        } catch (RuntimeException e) {
            log.warn("ORS wheelchair response unparseable ({})", e.getClass().getSimpleName());
        }
        return null;
    }

    static boolean retryable(OrsException e) {
        return e.code() != null && RETRY_CODES.contains(e.code());
    }

    /** Logs code/status only: the ORS message echoes coordinates, the request holds the user's profile. */
    private static void logOrs(String profile, OrsException e, boolean restricted) {
        log.warn("ORS error profile={} code={} http={} restricted={}", profile, e.code(), e.httpStatus(), restricted);
    }

    static String reason(OrsException e) {
        String what;
        Integer c = e.code();
        if (c == null) {
            what = e.httpStatus() == 0 ? "usługa niedostępna" : "błąd HTTP " + e.httpStatus();
        } else {
            what = switch (c) {
                case 2009 -> "nie znaleziono trasy";
                case 2010 -> "nie znaleziono punktu na sieci ścieżek";
                case 2004 -> "przekroczony limit odległości";
                case 2099 -> "nieznany błąd wyznaczania trasy";
                default -> "błąd";
            };
        }
        StringBuilder sb = new StringBuilder("OpenRouteService: ").append(what);
        if (c != null) sb.append(" (kod ").append(c).append(")");
        String msg = e.getMessage();
        if (msg != null && !msg.isBlank()) {
            sb.append(" - ").append(msg.length() > 200 ? msg.substring(0, 200) + "…" : msg);
        }
        return sb.toString();
    }

    static Map<String, Object> orsBody(RouteRequest req) { return orsBody(req, true); }

    static Map<String, Object> orsBody(RouteRequest req, boolean withRestrictions) {
        List<List<Double>> coords = req.points().stream().map(p -> List.of(p.lng(), p.lat())).toList();
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("coordinates", coords);
        // -1 = snap to the nearest routable way regardless of distance (GPS error, courtyards, parks)
        body.put("radiuses", Collections.nCopies(coords.size(), -1));
        body.put("instructions", true);
        body.put("language", "pl");
        body.put("units", "m");
        body.put("extra_info", List.of("steepness", "surface", "waytype"));
        if (withRestrictions) {
            Map<String, Object> restrictions = new LinkedHashMap<>();
            RouteProfile pr = req.profile();
            if (pr != null) {
                if (pr.maxKerbCm() != null) restrictions.put("maximum_sloped_kerb", pr.maxKerbCm() / 100.0);
                if (pr.maxInclinePct() != null) restrictions.put("maximum_incline", pr.maxInclinePct());
            }
            // the app no longer sends a user-adjustable width: default to a standard wheelchair (75 cm)
            int widthCm = pr != null && pr.minWidthCm() != null ? pr.minWidthCm() : DEFAULT_MIN_WIDTH_CM;
            restrictions.put("minimum_width", widthCm / 100.0);
            body.put("options", Map.of("profile_params", Map.of("restrictions", restrictions)));
        }
        return body;
    }

    static RouteResponse parseOrs(JsonNode body, int pointCount) { return parseOrs(body, pointCount, false, WHEELCHAIR); }

    /** Parses an ORS GeoJSON route; barriers empty / accessible=true (callers set barriers for the primary). */
    static RouteResponse parseOrs(JsonNode body, int pointCount, boolean relaxed, String profile) {
        JsonNode feature = body.path("features").path(0);
        if (feature.isMissingNode()) throw new IllegalStateException("ORS returned no route");
        JsonNode props = feature.path("properties");
        List<double[]> geometry = new ArrayList<>();
        for (JsonNode c : feature.path("geometry").path("coordinates")) {
            geometry.add(new double[]{c.get(1).asDouble(), c.get(0).asDouble()});
        }
        JsonNode extras = props.path("extras");
        List<Segment> segments = new ArrayList<>();
        for (JsonNode seg : props.path("segments")) {
            for (JsonNode step : seg.path("steps")) {
                JsonNode wp = step.path("way_points");
                String warning = wp.size() == 2 ? warningFor(extras, wp.get(0).asInt(), wp.get(1).asInt()) : null;
                segments.add(new Segment(step.path("instruction").asText(""), step.path("distance").asDouble(), warning));
            }
        }
        return new RouteResponse(profile, props.path("summary").path("distance").asDouble(),
                props.path("summary").path("duration").asDouble(), geometry, segments,
                IntStream.range(0, pointCount).boxed().toList(), "openrouteservice", false, relaxed, null,
                List.of(), true, null);
    }

    /** Polish name of an ORS surface id that is unsuitable for a wheelchair, else null. */
    static String badSurface(int v) {
        return switch (v) {
            case 2 -> "nieutwardzona";
            case 5 -> "kostka brukowa";
            case 8, 9, 10 -> "żwir";
            case 11, 12 -> "grunt";
            case 13 -> "lód";
            case 15 -> "piasek";
            case 16 -> "zrębki";
            case 17 -> "trawa";
            case 18 -> "płyty ażurowe";
            default -> null; // 0 unknown, 1 paved, 3 asphalt, 4 concrete, 6 metal, 7 wood, 14 paving stones
        };
    }

    /**
     * Geometry index spans of the route impassable for the profile:
     * steps (always; detail "sprawdź liczbę stopni" when maxSteps > 0), steepness classes whose lower bound
     * exceeds maxInclinePct, and bad surfaces when maxKerbCm <= 3 (wheelchair preset; null profile = wheelchair).
     * Adjacent/overlapping spans of the same type are merged. ("narrow" is not derivable from ORS extras.)
     */
    static List<Barrier> barriers(JsonNode body, RouteProfile pr) {
        JsonNode extras = body.path("features").path(0).path("properties").path("extras");
        int maxIncline = pr != null && pr.maxInclinePct() != null ? pr.maxInclinePct() : DEFAULT_MAX_INCLINE_PCT;
        boolean wheelchairSurface = pr == null || pr.maxKerbCm() == null || pr.maxKerbCm() <= 3;
        String stepsDetail = pr != null && pr.maxSteps() != null && pr.maxSteps() > 0 ? "sprawdź liczbę stopni" : null;

        List<Barrier> raw = new ArrayList<>();
        for (JsonNode r : extras.path("waytype").path("values")) {
            if (r.get(2).asInt() == WAYTYPE_STEPS) raw.add(new Barrier(r.get(0).asInt(), r.get(1).asInt(), "steps", "Schody", stepsDetail));
        }
        for (JsonNode r : extras.path("steepness").path("values")) {
            int cls = Math.min(5, Math.abs(r.get(2).asInt()));
            if (STEEP_LOWER[cls] > maxIncline) {
                raw.add(new Barrier(r.get(0).asInt(), r.get(1).asInt(), "steep", "Stromy odcinek", STEEP_DETAIL[cls]));
            }
        }
        if (wheelchairSurface) {
            for (JsonNode r : extras.path("surface").path("values")) {
                String s = badSurface(r.get(2).asInt());
                if (s != null) raw.add(new Barrier(r.get(0).asInt(), r.get(1).asInt(), "surface", "Nawierzchnia: " + s, null));
            }
        }
        return merge(raw);
    }

    /** Merges touching/overlapping spans of the same type (surface: same label too); steep keeps the steepest detail. */
    static List<Barrier> merge(List<Barrier> in) {
        List<Barrier> sorted = new ArrayList<>(in);
        sorted.sort(Comparator.comparing(Barrier::type).thenComparing(Barrier::label).thenComparingInt(Barrier::fromIndex));
        List<Barrier> out = new ArrayList<>();
        for (Barrier b : sorted) {
            Barrier last = out.isEmpty() ? null : out.get(out.size() - 1);
            boolean sameKind = last != null && last.type().equals(b.type())
                    && (!"surface".equals(b.type()) || last.label().equals(b.label()));
            if (sameKind && b.fromIndex() <= last.toIndex()) {
                String detail = last.detail();
                if ("steep".equals(b.type()) && steepRank(b.detail()) > steepRank(detail)) detail = b.detail();
                out.set(out.size() - 1, new Barrier(last.fromIndex(), Math.max(last.toIndex(), b.toIndex()),
                        last.type(), last.label(), detail));
            } else {
                out.add(b);
            }
        }
        out.sort(Comparator.comparingInt(Barrier::fromIndex).thenComparing(Barrier::type));
        return out;
    }

    private static int steepRank(String detail) { return Arrays.asList(STEEP_DETAIL).indexOf(detail); }

    /** Polish warning for geometry index range [from, to] of a step, from ORS extra_info; null if nothing notable. */
    static String warningFor(JsonNode extras, int from, int to) {
        LinkedHashSet<String> out = new LinkedHashSet<>();
        for (int v : valuesIn(extras.path("waytype"), from, to)) {
            String w = switch (v) {
                case WAYTYPE_STEPS -> "Schody";
                case 9 -> "Prom";
                case 10 -> "Odcinek w budowie";
                default -> null;
            };
            if (w != null) out.add(w);
        }
        int maxSteep = 0;
        for (int v : valuesIn(extras.path("steepness"), from, to)) maxSteep = Math.max(maxSteep, Math.min(5, Math.abs(v)));
        // ORS classes: 3 = 7-9 %, 4 = 10-15 %, 5 = >=16 %
        if (maxSteep == 3) out.add("Stromy odcinek (ok. 8%)");
        else if (maxSteep == 4) out.add("Stromy odcinek (ok. 12%)");
        else if (maxSteep >= 5) out.add("Bardzo stromy odcinek (ponad 15%)");
        for (int v : valuesIn(extras.path("surface"), from, to)) {
            String s = badSurface(v);
            if (s != null) out.add("Nawierzchnia: " + s);
        }
        return out.isEmpty() ? null : String.join("; ", out);
    }

    /** Values of extra ranges [a, b, value] overlapping [from, to] (zero-length steps match their point). */
    private static List<Integer> valuesIn(JsonNode extra, int from, int to) {
        List<Integer> vals = new ArrayList<>();
        for (JsonNode r : extra.path("values")) {
            int a = r.get(0).asInt(), b = r.get(1).asInt();
            boolean overlap = from == to ? (a <= from && from <= b) : (a < to && b > from);
            if (overlap) vals.add(r.get(2).asInt());
        }
        return vals;
    }

    static RouteResponse fallback(RouteRequest req) { return fallback(req, null); }

    /** Straight line; no accessibility data, so accessible=false (client shows "Brak danych o dostępności trasy"). */
    static RouteResponse fallback(RouteRequest req, String reason) {
        List<LatLng> pts = req.points();
        double dist = 0;
        List<double[]> geometry = new ArrayList<>();
        for (int i = 0; i < pts.size(); i++) {
            geometry.add(new double[]{pts.get(i).lat(), pts.get(i).lng()});
            if (i > 0) dist += GeoUtils.haversineM(pts.get(i - 1).lat(), pts.get(i - 1).lng(), pts.get(i).lat(), pts.get(i).lng());
        }
        double rounded = Math.round(dist);
        return new RouteResponse(FOOT, rounded, Math.round(dist / FALLBACK_SPEED), geometry,
                List.of(new Segment("Linia prosta - brak danych o trasie", rounded, "Trasa przybliżona (linia prosta) - brak danych o dostępności")),
                IntStream.range(0, pts.size()).boxed().toList(), "straight-line", true, false,
                reason == null ? "Brak danych o trasie" : reason, List.of(), false, null);
    }
}
