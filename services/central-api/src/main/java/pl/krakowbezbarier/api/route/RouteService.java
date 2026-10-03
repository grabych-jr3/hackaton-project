package pl.krakowbezbarier.api.route;

import com.fasterxml.jackson.databind.JsonNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;
import pl.krakowbezbarier.api.common.GeoUtils;
import pl.krakowbezbarier.api.route.RouteDtos.*;

import java.time.Duration;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.IntStream;

/** Proxy to OpenRouteService wheelchair profile with 10-min cache and straight-line fallback. */
@Service
public class RouteService {
    private static final Logger log = LoggerFactory.getLogger(RouteService.class);
    /** Rough wheelchair speed used for the fallback, m/s. */
    static final double FALLBACK_SPEED = 1.1;

    private final RestClient client;
    private final String apiKey;
    private final Duration cacheTtl;
    private final Map<RouteRequest, CacheEntry> cache = new ConcurrentHashMap<>();

    private record CacheEntry(RouteResponse response, Instant expires) {}

    public RouteService(@Value("${app.ors.api-key:}") String apiKey,
                        @Value("${app.ors.base-url:https://api.openrouteservice.org}") String baseUrl,
                        @Value("${app.ors.cache-minutes:10}") int cacheMinutes) {
        var rf = new SimpleClientHttpRequestFactory();
        rf.setConnectTimeout((int) Duration.ofSeconds(5).toMillis());
        rf.setReadTimeout((int) Duration.ofSeconds(15).toMillis());
        this.client = RestClient.builder().baseUrl(baseUrl).requestFactory(rf).build();
        this.apiKey = apiKey;
        this.cacheTtl = Duration.ofMinutes(cacheMinutes);
    }

    public RouteResponse route(RouteRequest req) {
        Instant now = Instant.now();
        CacheEntry hit = cache.get(req);
        if (hit != null && hit.expires().isAfter(now)) return hit.response();
        if (cache.size() > 1000) cache.entrySet().removeIf(e -> e.getValue().expires().isBefore(now));

        if (apiKey == null || apiKey.isBlank()) {
            log.warn("ORS_API_KEY not set - returning straight-line fallback");
            return fallback(req);
        }
        try {
            JsonNode body = client.post().uri("/v2/directions/wheelchair/geojson")
                    .header("Authorization", apiKey)
                    .contentType(MediaType.APPLICATION_JSON)
                    .accept(MediaType.APPLICATION_JSON, MediaType.valueOf("application/geo+json"))
                    .body(orsBody(req))
                    .retrieve().body(JsonNode.class);
            RouteResponse res = parseOrs(body, req.points().size());
            cache.put(req, new CacheEntry(res, now.plus(cacheTtl)));
            return res;
        } catch (Exception e) {
            // do not log the request: it contains the user's profile thresholds
            log.warn("ORS call failed ({}), using fallback", e.getClass().getSimpleName());
            return fallback(req);
        }
    }

    static Map<String, Object> orsBody(RouteRequest req) {
        List<List<Double>> coords = req.points().stream().map(p -> List.of(p.lng(), p.lat())).toList();
        Map<String, Object> restrictions = new LinkedHashMap<>();
        RouteProfile pr = req.profile();
        if (pr != null) {
            if (pr.maxKerbCm() != null) restrictions.put("maximum_sloped_kerb", pr.maxKerbCm() / 100.0);
            if (pr.minWidthCm() != null) restrictions.put("minimum_width", pr.minWidthCm() / 100.0);
            if (pr.maxInclinePct() != null) restrictions.put("maximum_incline", pr.maxInclinePct());
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("coordinates", coords);
        body.put("instructions", true);
        body.put("language", "pl");
        body.put("units", "m");
        if (!restrictions.isEmpty()) {
            body.put("options", Map.of("profile_params", Map.of("restrictions", restrictions)));
        }
        return body;
    }

    static RouteResponse parseOrs(JsonNode body, int pointCount) {
        JsonNode feature = body.path("features").path(0);
        if (feature.isMissingNode()) throw new IllegalStateException("ORS returned no route");
        JsonNode props = feature.path("properties");
        List<double[]> geometry = new ArrayList<>();
        for (JsonNode c : feature.path("geometry").path("coordinates")) {
            geometry.add(new double[]{c.get(1).asDouble(), c.get(0).asDouble()});
        }
        List<Segment> segments = new ArrayList<>();
        for (JsonNode seg : props.path("segments")) {
            for (JsonNode step : seg.path("steps")) {
                segments.add(new Segment(step.path("instruction").asText(""), step.path("distance").asDouble(), List.of()));
            }
        }
        return new RouteResponse(props.path("summary").path("distance").asDouble(),
                props.path("summary").path("duration").asDouble(), geometry, segments,
                IntStream.range(0, pointCount).boxed().toList(), "openrouteservice", false);
    }

    static RouteResponse fallback(RouteRequest req) {
        List<LatLng> pts = req.points();
        double dist = 0;
        List<double[]> geometry = new ArrayList<>();
        for (int i = 0; i < pts.size(); i++) {
            geometry.add(new double[]{pts.get(i).lat(), pts.get(i).lng()});
            if (i > 0) dist += GeoUtils.haversineM(pts.get(i - 1).lat(), pts.get(i - 1).lng(), pts.get(i).lat(), pts.get(i).lng());
        }
        double rounded = Math.round(dist);
        return new RouteResponse(rounded, Math.round(dist / FALLBACK_SPEED), geometry,
                List.of(new Segment("Linia prosta - brak danych o trasie", rounded, List.of("fallback"))),
                IntStream.range(0, pts.size()).boxed().toList(), "straight-line", true);
    }
}
