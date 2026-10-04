package pl.krakowbezbarier.api.route;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

import java.time.Duration;
import java.util.Map;

/** Thin HTTP client for ORS /v2/directions/{profile}/geojson (foot-walking, wheelchair). Never logs or exposes the API key. */
@Component
public class OrsClient {
    private static final ObjectMapper OM = new ObjectMapper();

    private final RestClient client;
    private final String apiKey;

    public OrsClient(@Value("${app.ors.api-key:}") String apiKey,
                     @Value("${app.ors.base-url:https://api.openrouteservice.org}") String baseUrl) {
        var rf = new SimpleClientHttpRequestFactory();
        rf.setConnectTimeout((int) Duration.ofSeconds(5).toMillis());
        rf.setReadTimeout((int) Duration.ofSeconds(30).toMillis()); // public ORS can be slow on long routes
        this.client = RestClient.builder().baseUrl(baseUrl).requestFactory(rf).build();
        this.apiKey = apiKey;
    }

    public boolean hasKey() { return apiKey != null && !apiKey.isBlank(); }

    /** @throws OrsException on any ORS / transport failure */
    public JsonNode directions(String profile, Map<String, Object> body) {
        try {
            JsonNode res = client.post().uri("/v2/directions/{profile}/geojson", profile)
                    .header("Authorization", apiKey)
                    .contentType(MediaType.APPLICATION_JSON)
                    .accept(MediaType.APPLICATION_JSON, MediaType.valueOf("application/geo+json"))
                    .body(body)
                    .retrieve().body(JsonNode.class);
            if (res == null || res.path("features").path(0).isMissingNode()) {
                throw new OrsException(res == null ? null : errorCode(res), 200,
                        res == null ? "empty response" : errorMessage(res, "no route in response"));
            }
            return res;
        } catch (OrsException e) {
            throw e;
        } catch (RestClientResponseException e) {
            Integer code = null;
            String msg = e.getStatusText();
            try {
                JsonNode err = OM.readTree(e.getResponseBodyAsString());
                code = errorCode(err);
                msg = errorMessage(err, msg);
            } catch (Exception ignored) { /* non-JSON body */ }
            throw new OrsException(code, e.getStatusCode().value(), msg);
        } catch (Exception e) {
            throw new OrsException(null, 0, e.getClass().getSimpleName());
        }
    }

    /**
     * ORS Snap API: nearest point on the {profile} graph within radiusM of (lat,lng).
     * @return {lat, lng, snappedDistanceM} or null if nothing within radius
     * @throws OrsException on any ORS / transport failure
     */
    public double[] snap(String profile, double lat, double lng, int radiusM) {
        try {
            JsonNode res = client.post().uri("/v2/snap/{profile}/json", profile)
                    .header("Authorization", apiKey)
                    .contentType(MediaType.APPLICATION_JSON).accept(MediaType.APPLICATION_JSON)
                    .body(Map.of("locations", java.util.List.of(java.util.List.of(lng, lat)), "radius", radiusM))
                    .retrieve().body(JsonNode.class);
            JsonNode loc = res == null ? null : res.path("locations").path(0);
            if (loc == null || loc.isNull() || loc.isMissingNode() || !loc.path("location").isArray()) return null;
            return new double[]{loc.path("location").path(1).asDouble(), loc.path("location").path(0).asDouble(),
                    loc.path("snapped_distance").asDouble(0)};
        } catch (RestClientResponseException e) {
            throw new OrsException(null, e.getStatusCode().value(), e.getStatusText());
        } catch (Exception e) {
            throw new OrsException(null, 0, e.getClass().getSimpleName());
        }
    }

    private static Integer errorCode(JsonNode n) {
        JsonNode c = n.path("error").path("code");
        return c.isNumber() ? c.asInt() : null;
    }

    private static String errorMessage(JsonNode n, String def) {
        JsonNode err = n.path("error");
        if (err.isTextual()) return err.asText();
        String m = err.path("message").asText("");
        return m.isBlank() ? def : m;
    }

    /** code = ORS internal error code (e.g. 2009) or null; httpStatus 0 = transport failure. */
    public static class OrsException extends RuntimeException {
        private final Integer code;
        private final int httpStatus;

        public OrsException(Integer code, int httpStatus, String message) {
            super(message);
            this.code = code;
            this.httpStatus = httpStatus;
        }

        public Integer code() { return code; }
        public int httpStatus() { return httpStatus; }
    }
}
