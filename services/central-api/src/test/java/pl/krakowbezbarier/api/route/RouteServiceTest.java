package pl.krakowbezbarier.api.route;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import pl.krakowbezbarier.api.crowd.CrowdService;
import pl.krakowbezbarier.api.route.OrsClient.OrsException;
import pl.krakowbezbarier.api.route.RouteDtos.*;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class RouteServiceTest {
    static final ObjectMapper OM = new ObjectMapper();
    final RouteRequest req = new RouteRequest(
            List.of(new LatLng(50.0617, 19.9373), new LatLng(50.0541, 19.9354)),
            new RouteProfile(0, 3, 80, 6), true, false);

    /** Synthetic route: steps on [0,1], -3 steepness + cobblestone on [1,3]. */
    static final String OK_JSON = """
            {"features":[{"geometry":{"coordinates":[[19.9373,50.0617],[19.937,50.0612],[19.936,50.060],[19.935,50.059]]},
             "properties":{"summary":{"distance":500,"duration":400},
             "extras":{"steepness":{"values":[[0,1,0],[1,3,-3]]},
                       "surface":{"values":[[0,2,14],[2,3,5]]},
                       "waytype":{"values":[[0,1,8],[1,3,7]]}},
             "segments":[{"steps":[
               {"instruction":"Schodami w dół","distance":20,"way_points":[0,1]},
               {"instruction":"Prosto","distance":400,"way_points":[1,3]},
               {"instruction":"Cel","distance":0,"way_points":[3,3]}]}]}}]}""";

    static final String FLAT_JSON = """
            {"features":[{"geometry":{"coordinates":[[19.9373,50.0617],[19.937,50.0612]]},
             "properties":{"summary":{"distance":100,"duration":80},
             "extras":{"steepness":{"values":[[0,1,1]]},"surface":{"values":[[0,1,3]]},"waytype":{"values":[[0,1,7]]}},
             "segments":[{"steps":[{"instruction":"Prosto","distance":100,"way_points":[0,1]}]}]}}]}""";

    /** Fake ORS: replays outcomes (JsonNode or OrsException) and records (profile, body) of each call. */
    static class FakeOrs extends OrsClient {
        final List<String> profiles = new ArrayList<>();
        final List<Map<String, Object>> calls = new ArrayList<>();
        final List<Object> outcomes;
        FakeOrs(Object... outcomes) { super("k", "http://localhost:1"); this.outcomes = new ArrayList<>(List.of(outcomes)); }
        @Override public JsonNode directions(String profile, Map<String, Object> body) {
            profiles.add(profile);
            calls.add(body);
            Object o = outcomes.remove(0);
            if (o instanceof OrsException e) throw e;
            return (JsonNode) o;
        }
    }

    static JsonNode json(String s) throws Exception { return OM.readTree(s); }

    /** Real ORS foot-walking response, Planty (Straszewskiego) -> Wawel courtyard, 2026-10-03. */
    static JsonNode wawelFixture() throws Exception {
        try (InputStream in = RouteServiceTest.class.getResourceAsStream("/ors/foot-walking-wawel.json")) {
            return OM.readTree(in);
        }
    }

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
    void orsBodyHasRadiusesAndExtraInfo() {
        var r3 = new RouteRequest(List.of(new LatLng(50, 19), new LatLng(50.1, 19.1), new LatLng(50.2, 19.2)), null, false, false);
        Map<String, Object> body = RouteService.orsBody(r3);
        assertEquals(List.of(-1, -1, -1), body.get("radiuses"));
        assertEquals(List.of("steepness", "surface", "waytype"), body.get("extra_info"));
        assertEquals(true, body.get("instructions"));
        assertEquals("pl", body.get("language"));
        assertEquals("m", body.get("units"));
        assertTrue(body.containsKey("options"));
        assertFalse(RouteService.orsBody(r3, false).containsKey("options"));
    }

    @Test
    void noKeyGivesStraightLineFallback() {
        RouteResponse r = new RouteService(new OrsClient("", "http://localhost:1"), 10).route(req);
        assertTrue(r.fallback());
        assertEquals("Brak klucza OpenRouteService", r.fallbackReason());
        assertFalse(r.relaxed());
        assertFalse(r.accessible());
        assertTrue(r.barriers().isEmpty());
        assertNull(r.alternative());
        assertEquals("foot-walking", r.profile());
        assertTrue(r.distanceM() > 800 && r.distanceM() < 900, "distance " + r.distanceM());
        assertArrayEquals(new double[]{50.0617, 19.9373}, r.geometry().get(0));
        assertEquals(List.of(0, 1), r.order());
    }

    @Test
    void parsesOrsGeojson() throws Exception {
        String s = """
                {"features":[{"geometry":{"coordinates":[[19.9373,50.0617],[19.937,50.0612]]},
                 "properties":{"summary":{"distance":1240,"duration":1110},
                 "segments":[{"steps":[{"instruction":"Skręć w lewo","distance":320}]}]}}]}""";
        RouteResponse r = RouteService.parseOrs(json(s), 2);
        assertEquals(1240, r.distanceM());
        assertArrayEquals(new double[]{50.0612, 19.937}, r.geometry().get(1));
        assertEquals("Skręć w lewo", r.segments().get(0).instruction());
        assertFalse(r.fallback());
    }

    @Test
    void barriersFromRealFootWalkingFixture() throws Exception {
        List<Barrier> b = RouteService.barriers(wawelFixture(), new RouteProfile(0, 3, null, 6));
        assertEquals(List.of(
                new Barrier(12, 13, "steps", "Schody", null),
                new Barrier(18, 20, "steps", "Schody", null),
                // -3 (7-9 %) on [25,38] and -5 (>=16 %) on [38,41] merged, steepest detail kept
                new Barrier(25, 41, "steep", "Stromy odcinek", "ponad 15%")), b);
    }

    @Test
    void strollerProfileFlagsStepsWithDetailAndOnlyVerySteep() throws Exception {
        List<Barrier> b = RouteService.barriers(wawelFixture(), new RouteProfile(3, 5, null, 8));
        assertEquals(List.of(
                new Barrier(12, 13, "steps", "Schody", "sprawdź liczbę stopni"),
                new Barrier(18, 20, "steps", "Schody", "sprawdź liczbę stopni"),
                new Barrier(38, 41, "steep", "Stromy odcinek", "ponad 15%")), b);
    }

    @Test
    void surfaceOnlyForWheelchairPreset() throws Exception {
        List<Barrier> wc = RouteService.barriers(json(OK_JSON), new RouteProfile(0, 3, null, 10));
        assertTrue(wc.contains(new Barrier(2, 3, "surface", "Nawierzchnia: kostka brukowa", null)), wc.toString());
        List<Barrier> stroller = RouteService.barriers(json(OK_JSON), new RouteProfile(2, 5, null, 10));
        assertTrue(stroller.stream().noneMatch(x -> x.type().equals("surface")), stroller.toString());
    }

    @Test
    void mergesAdjacentSpansOfSameType() {
        List<Barrier> m = RouteService.merge(List.of(
                new Barrier(5, 7, "steps", "Schody", null),
                new Barrier(0, 2, "steps", "Schody", null),
                new Barrier(2, 4, "steps", "Schody", null),
                new Barrier(3, 6, "steep", "Stromy odcinek", "ok. 8%"),
                new Barrier(6, 9, "steep", "Stromy odcinek", "ok. 12%"),
                new Barrier(1, 2, "surface", "Nawierzchnia: żwir", null),
                new Barrier(2, 3, "surface", "Nawierzchnia: piasek", null)));
        assertEquals(List.of(
                new Barrier(0, 4, "steps", "Schody", null),
                new Barrier(1, 2, "surface", "Nawierzchnia: żwir", null),
                new Barrier(2, 3, "surface", "Nawierzchnia: piasek", null),
                new Barrier(3, 9, "steep", "Stromy odcinek", "ok. 12%"),
                new Barrier(5, 7, "steps", "Schody", null)), m);
    }

    @Test
    void barriersTriggerWheelchairAlternative() throws Exception {
        var fake = new FakeOrs(wawelFixture(), json(FLAT_JSON));
        RouteResponse r = new RouteService(fake, 10).route(req);
        assertEquals(List.of("foot-walking", "wheelchair"), fake.profiles);
        assertFalse(fake.calls.get(0).containsKey("options"));
        assertTrue(fake.calls.get(1).containsKey("options"));
        assertEquals("foot-walking", r.profile());
        assertFalse(r.accessible());
        assertEquals(3, r.barriers().size());
        RouteResponse alt = r.alternative();
        assertNotNull(alt);
        assertEquals("wheelchair", alt.profile());
        assertTrue(alt.accessible());
        assertTrue(alt.barriers().isEmpty());
        assertNull(alt.alternative());
        assertFalse(alt.relaxed());
    }

    @Test
    void noBarriersNoAlternative() throws Exception {
        var fake = new FakeOrs(json(FLAT_JSON));
        RouteResponse r = new RouteService(fake, 10).route(req);
        assertEquals(List.of("foot-walking"), fake.profiles);
        assertTrue(r.accessible());
        assertTrue(r.barriers().isEmpty());
        assertNull(r.alternative());
    }

    static final OrsException NO_ROUTE = new OrsException(2009, 404, "Route could not be found");

    /** n retryable failures (exact destination + offsets that also fail). */
    static Object[] failures(int n) { Object[] o = new Object[n]; Arrays.fill(o, NO_ROUTE); return o; }

    static Object[] concat(Object[] a, Object... b) {
        Object[] o = Arrays.copyOf(a, a.length + b.length);
        System.arraycopy(b, 0, o, a.length, b.length);
        return o;
    }

    @Test
    void alternativeRelaxedRetryWithoutRestrictions() throws Exception {
        int offs = RouteService.DEST_OFFSETS_M.length;
        var fake = new FakeOrs(concat(concat(new Object[]{json(OK_JSON)}, failures(1 + offs)), json(FLAT_JSON)));
        RouteResponse r = new RouteService(fake, 10).route(req);
        assertEquals(2 + offs + 1, fake.calls.size());
        assertTrue(fake.calls.get(1).containsKey("options"));
        assertFalse(fake.calls.get(fake.calls.size() - 1).containsKey("options"));
        assertTrue(r.alternative().relaxed());
        assertFalse(r.alternative().accessible());
        assertTrue(r.alternative().note().startsWith("Brak trasy bez barier do samego celu"));
        assertFalse(r.fallback());
    }

    @Test
    void alternativeOmittedWhenAllWheelchairCallsFail() throws Exception {
        int offs = RouteService.DEST_OFFSETS_M.length;
        var fake = new FakeOrs(concat(new Object[]{json(OK_JSON)}, failures(2 + offs)));
        RouteResponse r = new RouteService(fake, 10).route(req);
        assertEquals(3 + offs, fake.calls.size());
        assertNull(r.alternative());
        assertNotNull(r.note());
        assertFalse(r.fallback());
    }

    @Test
    void nonRetryableWheelchairErrorStopsImmediately() throws Exception {
        var fake = new FakeOrs(json(OK_JSON), new OrsException(2003, 400, "bad"));
        RouteResponse r = new RouteService(fake, 10).route(req);
        assertEquals(2, fake.calls.size());
        assertNull(r.alternative());
    }

    /** Stara Synagoga case: exact destination unreachable for wheelchair, first offset works -> note with gap. */
    @Test
    @SuppressWarnings("unchecked")
    void destinationSnappedToNearbyAccessiblePoint() throws Exception {
        String end = """
                {"features":[{"geometry":{"coordinates":[[19.9373,50.0617],[19.9354,50.05446]]},
                 "properties":{"summary":{"distance":1560,"duration":1300},
                 "extras":{"steepness":{"values":[[0,1,0]]},"surface":{"values":[[0,1,3]]},"waytype":{"values":[[0,1,3]]}},
                 "segments":[{"steps":[{"instruction":"Prosto","distance":1560,"way_points":[0,1]}]}]}}]}""";
        var fake = new FakeOrs(json(OK_JSON), NO_ROUTE, json(end));
        RouteResponse r = new RouteService(fake, 10).route(req);
        assertEquals(3, fake.calls.size());
        var coords = (List<List<Double>>) fake.calls.get(2).get("coordinates");
        assertTrue(coords.get(1).get(1) > req.points().get(1).lat(), "first offset is north");
        RouteResponse alt = r.alternative();
        assertTrue(alt.accessible());
        assertTrue(alt.barriers().isEmpty());
        assertNotNull(alt.note());
        assertTrue(alt.note().contains("ostatnie") && alt.note().contains("m może wymagać pomocy"), alt.note());
    }

    /** Wheelchair route that still has steps: barriers reported; a barrier-free offset is preferred. */
    @Test
    void alternativeWithBarriersIsReportedAndOffsetPreferred() throws Exception {
        var fake = new FakeOrs(json(OK_JSON), json(OK_JSON), json(FLAT_JSON));
        RouteResponse alt = new RouteService(fake, 10).route(req).alternative();
        assertTrue(alt.barriers().isEmpty());
        assertEquals(3, fake.calls.size());

        int offs = RouteService.DEST_OFFSETS_M.length;
        fake = new FakeOrs(concat(new Object[]{json(OK_JSON), json(OK_JSON)}, failures(offs)));
        alt = new RouteService(fake, 10).route(req).alternative();
        assertFalse(alt.accessible());
        assertFalse(alt.barriers().isEmpty());
        assertTrue(alt.note().contains("wymagać pomocy"), alt.note());
    }

    @Test
    void gapNoteOnlyForNoticeableGap() {
        LatLng d = new LatLng(50.0514, 19.9485);
        RouteResponse near = new RouteResponse("wheelchair", 1, 1, List.<double[]>of(new double[]{50.05141, 19.9485}),
                List.of(), List.of(), "x", false, false, null, List.of(), true, null);
        assertNull(RouteService.gapNote(near, d));
        LatLng o = RouteService.offset(d, 40, 0);
        assertEquals(40, pl.krakowbezbarier.api.common.GeoUtils.haversineM(d.lat(), d.lng(), o.lat(), o.lng()), 0.5);
        RouteResponse far = new RouteResponse("wheelchair", 1, 1, List.<double[]>of(new double[]{o.lat(), o.lng()}),
                List.of(), List.of(), "x", false, false, null, List.of(), true, null);
        assertEquals("Brak trasy bez barier do samego celu — ostatnie 40 m może wymagać pomocy", RouteService.gapNote(far, d));
    }

    @Test
    void primaryFailureGivesFallbackWithReason() {
        var fake = new FakeOrs(new OrsException(2009, 404, "Route could not be found"));
        RouteResponse r = new RouteService(fake, 10).route(req);
        assertTrue(r.fallback());
        assertFalse(r.accessible());
        assertTrue(r.fallbackReason().startsWith("OpenRouteService: nie znaleziono trasy (kod 2009)"), r.fallbackReason());
    }

    @Test
    void transportErrorFallsBack() {
        var fake = new FakeOrs(new OrsException(null, 0, "SocketTimeoutException"));
        RouteResponse r = new RouteService(fake, 10).route(req);
        assertEquals(1, fake.calls.size());
        assertTrue(r.fallbackReason().contains("usługa niedostępna"), r.fallbackReason());
    }

    @Test
    void extrasBecomePolishWarnings() throws Exception {
        RouteResponse r = RouteService.parseOrs(json(OK_JSON), 2);
        assertEquals("Schody", r.segments().get(0).warning());
        assertEquals("Stromy odcinek (ok. 8%); Nawierzchnia: kostka brukowa", r.segments().get(1).warning());
        assertEquals(3, r.segments().size());
        assertNull(RouteService.warningFor(json("{}"), 0, 3));
    }

    @Test
    @SuppressWarnings("unchecked")
    void avoidCrowdsSendsAvoidPolygonsInLngLat() throws Exception {
        CrowdService crowd = mock(CrowdService.class);
        List<double[]> ring = List.of(new double[]{50.06, 19.93}, new double[]{50.062, 19.93}, new double[]{50.062, 19.934},
                new double[]{50.06, 19.934}, new double[]{50.06, 19.93});
        when(crowd.crowdedPolygons(anyDouble(), anyList(), anyInt())).thenReturn(List.of(ring));
        var fake = new FakeOrs(json(FLAT_JSON));
        var r = new RouteService(fake, crowd, 10).route(new RouteRequest(req.points(), null, true, false));
        var opts = (Map<String, Object>) fake.calls.get(0).get("options");
        var avoid = (Map<String, Object>) opts.get("avoid_polygons");
        assertEquals("MultiPolygon", avoid.get("type"));
        assertEquals(List.of(19.93, 50.06), ((List<List<List<List<Double>>>>) avoid.get("coordinates")).get(0).get(0).get(0));
        assertEquals("Trasa omija zatłoczone miejsca (1)", r.note());
    }

    @Test
    void avoidCrowdsRetriesWithoutPolygonsWhenNoRoute() throws Exception {
        CrowdService crowd = mock(CrowdService.class);
        when(crowd.crowdedPolygons(anyDouble(), anyList(), anyInt()))
                .thenReturn(List.of(List.of(new double[]{50, 19}, new double[]{50.1, 19}, new double[]{50, 19})));
        var fake = new FakeOrs(new OrsException(2009, 404, "no route"), json(FLAT_JSON));
        var r = new RouteService(fake, crowd, 10).route(new RouteRequest(req.points(), null, true, false));
        assertEquals(2, fake.calls.size());
        assertFalse(fake.calls.get(1).containsKey("options"));
        assertFalse(r.fallback());
        assertNull(r.note());
    }

    @Test
    void noAvoidWithoutFlag() throws Exception {
        CrowdService crowd = mock(CrowdService.class);
        var fake = new FakeOrs(json(FLAT_JSON));
        new RouteService(fake, crowd, 10).route(new RouteRequest(req.points(), req.profile(), false, false));
        verifyNoInteractions(crowd);
    }
}
