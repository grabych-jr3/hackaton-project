package pl.krakowbezbarier.api.route;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import pl.krakowbezbarier.api.route.RouteDtos.*;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class RouteServiceTest {
    final RouteRequest req = new RouteRequest(
            List.of(new LatLng(50.0617, 19.9373), new LatLng(50.0541, 19.9354)),
            new RouteProfile(3, 80, 6), true, false);

    @Test
    @SuppressWarnings("unchecked")
    void orsBodyUsesLngLatAndMetres() {
        Map<String, Object> body = RouteService.orsBody(req);
        assertEquals(List.of(19.9373, 50.0617), ((List<?>) body.get("coordinates")).get(0));
        var restr = (Map<String, Object>) ((Map<String, Object>) ((Map<String, Object>) body.get("options"))
                .get("profile_params")).get("restrictions");
        assertEquals(0.03, restr.get("maximum_sloped_kerb"));
        assertEquals(0.8, restr.get("minimum_width"));
        assertEquals(6, restr.get("maximum_incline"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void missingWidthDefaultsTo75cm() {
        for (RouteProfile p : new RouteProfile[]{new RouteProfile(3, null, 6), null}) {
            var r = new RouteRequest(req.points(), p, true, false);
            var restr = (Map<String, Object>) ((Map<String, Object>) ((Map<String, Object>) RouteService.orsBody(r)
                    .get("options")).get("profile_params")).get("restrictions");
            assertEquals(0.75, restr.get("minimum_width"));
        }
    }

    @Test
    void noKeyGivesStraightLineFallback() {
        RouteResponse r = new RouteService("", "http://localhost:1", 10).route(req);
        assertTrue(r.fallback());
        assertTrue(r.distanceM() > 800 && r.distanceM() < 900, "distance " + r.distanceM());
        assertArrayEquals(new double[]{50.0617, 19.9373}, r.geometry().get(0));
        assertEquals(List.of(0, 1), r.order());
    }

    @Test
    void parsesOrsGeojson() throws Exception {
        String json = """
                {"features":[{"geometry":{"coordinates":[[19.9373,50.0617],[19.937,50.0612]]},
                 "properties":{"summary":{"distance":1240,"duration":1110},
                 "segments":[{"steps":[{"instruction":"Skręć w lewo","distance":320}]}]}}]}""";
        RouteResponse r = RouteService.parseOrs(new ObjectMapper().readTree(json), 2);
        assertEquals(1240, r.distanceM());
        assertArrayEquals(new double[]{50.0612, 19.937}, r.geometry().get(1));
        assertEquals("Skręć w lewo", r.segments().get(0).instruction());
        assertFalse(r.fallback());
    }
}
