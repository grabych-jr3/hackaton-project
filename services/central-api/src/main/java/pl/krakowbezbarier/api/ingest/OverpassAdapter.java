package pl.krakowbezbarier.api.ingest;

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
import pl.krakowbezbarier.api.common.GeoUtils.BBox;

import java.time.Instant;
import java.util.*;

/**
 * Overpass import with mirror failover: each fetch tries the configured mirrors in order
 * (connect timeout 10 s, read timeout 90 s) and returns the first successful response.
 */
@Component
public class OverpassAdapter implements SourceAdapter {
    private static final Logger log = LoggerFactory.getLogger(OverpassAdapter.class);
    static final List<String> DEFAULT_URLS = List.of(
            "https://overpass-api.de/api/interpreter",
            "https://lz4.overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter");

    /** POSTs an Overpass QL query to one mirror and returns the raw response body. */
    @FunctionalInterface
    interface Transport {
        String post(String url, String query) throws Exception;
    }

    private final List<String> urls;
    private final Transport transport;
    private final ObjectMapper om;
    private volatile String lastOrigin;

    @Autowired
    public OverpassAdapter(@Value("${app.overpass.urls:}") String urls, ObjectMapper om) {
        this(parseUrls(urls), restTransport(), om);
    }

    OverpassAdapter(List<String> urls, Transport transport, ObjectMapper om) {
        this.urls = urls.isEmpty() ? DEFAULT_URLS : List.copyOf(urls);
        this.transport = transport;
        this.om = om;
    }

    static List<String> parseUrls(String csv) {
        if (csv == null) return List.of();
        return Arrays.stream(csv.split(",")).map(String::trim).filter(s -> !s.isEmpty()).toList();
    }

    private static Transport restTransport() {
        var rf = new SimpleClientHttpRequestFactory();
        rf.setConnectTimeout(10_000);
        rf.setReadTimeout(90_000);
        RestClient client = RestClient.builder().requestFactory(rf)
                .defaultHeader("User-Agent", "krakow-bez-barier/0.1 (hackathon)").build();
        return (url, query) -> {
            var form = new LinkedMultiValueMap<String, String>();
            form.add("data", query);
            return client.post().uri(url).contentType(MediaType.APPLICATION_FORM_URLENCODED).body(form)
                    .retrieve().body(String.class);
        };
    }

    List<String> urls() { return urls; }

    @Override
    public String sourceId() { return "osm"; }

    @Override
    public String lastOrigin() { return lastOrigin; }

    static String query(BBox b) {
        // Overpass bbox order: south,west,north,east
        String bb = b.minLat() + "," + b.minLng() + "," + b.maxLat() + "," + b.maxLng();
        return """
                [out:json][timeout:90];
                (
                  nwr["tourism"~"attraction|museum|gallery|viewpoint"](%1$s);
                  nwr["historic"](%1$s);
                  nwr["amenity"~"cafe|restaurant|toilets|place_of_worship"](%1$s);
                  nwr["leisure"="park"](%1$s);
                );
                out center tags meta;
                """.formatted(bb);
    }

    @Override
    public List<ImportedPlace> fetch(BBox bbox) throws Exception {
        String q = query(bbox);
        List<String> errors = new ArrayList<>();
        for (String url : urls) {
            try {
                String body = transport.post(url, q);
                JsonNode root = om.readTree(body);
                if (!root.has("elements")) throw new IllegalStateException("no 'elements' in response");
                List<ImportedPlace> out = parse(root);
                lastOrigin = url;
                log.info("Overpass mirror {} succeeded ({} places)", url, out.size());
                return out;
            } catch (Exception e) {
                log.warn("Overpass mirror {} failed: {}", url, e.getMessage());
                errors.add(url + ": " + e.getMessage());
            }
        }
        throw new Exception("All Overpass mirrors failed: " + String.join("; ", errors));
    }

    static List<ImportedPlace> parse(JsonNode root) {
        return parse(root, Instant.now());
    }

    /** @param defaultFetched used for elements without a {@code timestamp} (e.g. the offline snapshot). */
    static List<ImportedPlace> parse(JsonNode root, Instant defaultFetched) {
        List<ImportedPlace> out = new ArrayList<>();
        for (JsonNode el : root.path("elements")) {
            JsonNode tagsNode = el.path("tags");
            Map<String, String> tags = new LinkedHashMap<>();
            tagsNode.fields().forEachRemaining(e -> tags.put(e.getKey(), e.getValue().asText()));
            String name = tags.get("name");
            String category = OsmTagMapper.category(tags);
            if (name == null || category == null) continue;
            double lat = el.has("lat") ? el.get("lat").asDouble() : el.path("center").path("lat").asDouble(Double.NaN);
            double lng = el.has("lon") ? el.get("lon").asDouble() : el.path("center").path("lon").asDouble(Double.NaN);
            if (Double.isNaN(lat) || Double.isNaN(lng)) continue;
            String id = "osm:" + el.path("type").asText() + ":" + el.path("id").asText();
            Instant fetched = defaultFetched;
            if (el.hasNonNull("timestamp")) {
                try { fetched = Instant.parse(el.get("timestamp").asText()); } catch (Exception ignored) { }
            }
            String street = tags.get("addr:street"), number = tags.get("addr:housenumber");
            String address = street == null ? null : (number == null ? street : street + " " + number);
            out.add(new ImportedPlace(id, name, category, lat, lng, address, tags, fetched, OsmTagMapper.facts(tags)));
        }
        return out;
    }
}
