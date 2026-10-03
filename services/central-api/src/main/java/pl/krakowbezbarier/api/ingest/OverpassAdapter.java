package pl.krakowbezbarier.api.ingest;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.web.client.RestClient;
import pl.krakowbezbarier.api.common.GeoUtils.BBox;

import java.time.Instant;
import java.util.*;

@Component
public class OverpassAdapter implements SourceAdapter {
    private final RestClient client;
    private final ObjectMapper om;

    public OverpassAdapter(@Value("${app.overpass.url}") String url, ObjectMapper om) {
        var rf = new SimpleClientHttpRequestFactory();
        rf.setConnectTimeout(10_000);
        rf.setReadTimeout(120_000);
        this.client = RestClient.builder().baseUrl(url).requestFactory(rf)
                .defaultHeader("User-Agent", "krakow-bez-barier/0.1 (hackathon)").build();
        this.om = om;
    }

    @Override
    public String sourceId() { return "osm"; }

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
        var form = new LinkedMultiValueMap<String, String>();
        form.add("data", query(bbox));
        String body = client.post().contentType(MediaType.APPLICATION_FORM_URLENCODED).body(form)
                .retrieve().body(String.class);
        return parse(om.readTree(body));
    }

    static List<ImportedPlace> parse(JsonNode root) {
        List<ImportedPlace> out = new ArrayList<>();
        Instant now = Instant.now();
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
            Instant fetched = now;
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
