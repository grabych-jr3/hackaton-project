package pl.krakowbezbarier.api;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.fasterxml.jackson.databind.node.IntNode;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.ingest.OsmTagMapper;
import pl.krakowbezbarier.api.place.DemoSeeder;
import pl.krakowbezbarier.api.place.Dtos.*;
import pl.krakowbezbarier.api.place.Enums;
import pl.krakowbezbarier.api.place.FactValidator;
import pl.krakowbezbarier.api.route.RouteDtos.*;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class ContractTest {
    final ObjectMapper om = JsonMapper.builder().findAndAddModules()
            .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS).build();

    @Test
    void placeJsonMatchesFlutterModel() throws Exception {
        var fact = new FactDto("f1", "steps", IntNode.valueOf(0), "osm", "osm:way:1",
                Instant.parse("2026-08-15T10:00:00Z"), null, 0, 0);
        var place = new PlaceDto("osm:way:1", "Sukiennice", "museum", 50.0617, 19.9373, "Rynek", false, List.of(fact));
        var res = new PlacesResponse(List.of(place), Map.of("osm", new SourceInfo(Instant.parse("2026-10-03T05:00:00Z"), false)));
        JsonNode j = om.readTree(om.writeValueAsString(res));
        JsonNode p = j.at("/places/0");
        for (String k : List.of("id", "name", "category", "lat", "lng", "address", "isDemo", "facts")) assertTrue(p.has(k), k);
        assertFalse(p.has("demo"));
        JsonNode f = p.at("/facts/0");
        for (String k : List.of("id", "feature", "value", "source", "sourceRef", "fetchedAt", "confirmedAt", "confirmations", "disputes")) {
            assertTrue(f.has(k), k);
        }
        assertEquals("2026-08-15T10:00:00Z", f.get("fetchedAt").asText());
        assertTrue(f.get("value").isInt());
        assertEquals(false, j.at("/sources/osm/stale").asBoolean());
    }

    @Test
    void routeResponseShape() throws Exception {
        var r = new RouteResponse(10, 9, List.<double[]>of(new double[]{50.06, 19.93}),
                List.of(new Segment("x", 10, List.of())), List.of(0, 1), "openrouteservice", false);
        JsonNode j = om.readTree(om.writeValueAsString(r));
        assertEquals(50.06, j.at("/geometry/0/0").asDouble());
        assertTrue(j.has("distanceM") && j.has("durationS") && j.has("fallback"));
    }

    @Test
    void factValidation() {
        FactValidator.validate("steps", IntNode.valueOf(3));
        FactValidator.validate("kerbHeight", om.valueToTree(">7"));
        FactValidator.validate("kerbHeight", om.valueToTree("3-7"));
        FactValidator.validate("kerbHeight", IntNode.valueOf(5));
        FactValidator.validate("doorWidth", IntNode.valueOf(90));
        FactValidator.validate("ramp", om.valueToTree(true));
        assertThrows(ApiException.class, () -> FactValidator.validate("steps", IntNode.valueOf(51)));
        assertThrows(ApiException.class, () -> FactValidator.validate("steps", om.valueToTree(1.5)));
        assertThrows(ApiException.class, () -> FactValidator.validate("doorWidth", IntNode.valueOf(10)));
        assertThrows(ApiException.class, () -> FactValidator.validate("incline", IntNode.valueOf(41)));
        assertThrows(ApiException.class, () -> FactValidator.validate("kerbHeight", om.valueToTree("high")));
        assertThrows(ApiException.class, () -> FactValidator.validate("ramp", IntNode.valueOf(1)));
        assertThrows(ApiException.class, () -> FactValidator.validate("wings", IntNode.valueOf(1)));
        assertThrows(ApiException.class, () -> FactValidator.validate("steps", null));
    }

    @Test
    void seedFileIsValid() throws Exception {
        JsonNode root = om.readTree(new ClassPathResource("seed/places.json").getInputStream());
        assertTrue(root.path("places").size() >= 10);
        for (JsonNode p : root.path("places")) {
            assertTrue(Enums.CATEGORIES.contains(p.get("category").asText()), p.toString());
            for (JsonNode f : p.path("facts")) {
                assertTrue(Enums.SOURCES.contains(f.get("source").asText()));
                FactValidator.validate(f.get("feature").asText(), f.get("value"));
                assertNotNull(DemoSeeder.parseInstant(f.get("fetchedAt").asText()));
            }
        }
    }

    @Test
    void osmTagMapping() {
        var facts = OsmTagMapper.facts(Map.of("wheelchair", "yes", "step_count", "2", "door:width", "0.9",
                "toilets:wheelchair", "no", "incline", "6%"));
        Map<String, String> m = new java.util.HashMap<>();
        facts.forEach(f -> m.put(f.feature(), f.value().toString()));
        assertEquals("2", m.get("steps"));
        assertEquals("90", m.get("doorWidth"));
        assertEquals("false", m.get("toilet"));
        assertEquals("6", m.get("incline"));
        assertEquals("museum", OsmTagMapper.category(Map.of("tourism", "museum")));
        assertEquals("church", OsmTagMapper.category(Map.of("amenity", "place_of_worship", "historic", "church")));
    }
}
