package pl.krakowbezbarier.api.crowd;

import org.junit.jupiter.api.Test;
import pl.krakowbezbarier.api.common.GeoUtils.BBox;
import pl.krakowbezbarier.api.crowd.CrowdModel.*;

import java.time.Instant;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class CrowdModelTest {
    // 2026-10-03 is a Saturday, 2026-10-05 a Monday
    final LocalDateTime satAfternoon = LocalDateTime.of(2026, 10, 3, 14, 0);
    final LocalDateTime satNight = LocalDateTime.of(2026, 10, 3, 3, 0);
    final LocalDateTime monMorning = LocalDateTime.of(2026, 10, 5, 10, 30);

    @Test
    void openingHoursCommonForms() {
        assertTrue(OpeningHours.isOpen("24/7", satNight));
        assertTrue(OpeningHours.isOpen("Mo-Fr 09:00-17:00", monMorning));
        assertFalse(OpeningHours.isOpen("Mo-Fr 09:00-17:00", satAfternoon));
        assertTrue(OpeningHours.isOpen("Mo-Fr 09:00-17:00; Sa 10:00-15:00", satAfternoon));
        assertFalse(OpeningHours.isOpen("Mo-Su 10:00-18:00; Sa off", satAfternoon));
        assertTrue(OpeningHours.isOpen("10:00-12:00,13:00-18:00", satAfternoon));
        assertFalse(OpeningHours.isOpen("10:00-12:00,15:00-18:00", satAfternoon));
        assertTrue(OpeningHours.isOpen("Mo,We,Sa 12:00-16:00", satAfternoon));
        assertTrue(OpeningHours.isOpen("Sa-Mo 12:00-16:00", satAfternoon));
    }

    @Test
    void openingHoursPastMidnight() {
        // Friday 22:00-04:00 -> Saturday 03:00 is still open
        assertTrue(OpeningHours.isOpen("Fr 22:00-04:00", satNight));
        assertFalse(OpeningHours.isOpen("Sa 22:00-04:00", satNight));
        assertTrue(OpeningHours.isOpen("Sa 22:00-04:00", satNight.withHour(23)));
    }

    @Test
    void openingHoursUnknown() {
        assertNull(OpeningHours.isOpen(null, satNight));
        assertNull(OpeningHours.isOpen("PH off; Mo-Fr 09:00-17:00", monMorning));
        assertNull(OpeningHours.isOpen("sunrise-sunset", monMorning));
        assertNull(OpeningHours.isOpen("Jan-Mar 10:00-12:00", monMorning));
    }

    @Test
    void closedPlaceAddsNothing() {
        var closed = List.of(new Place("museum", "Mo-Fr 09:00-17:00"));
        assertEquals(0, CrowdModel.rawBase(closed, null, satAfternoon));
        var open = List.of(new Place("museum", "Sa 09:00-17:00"));
        assertTrue(CrowdModel.rawBase(open, null, satAfternoon) > 0);
        var unknown = List.of(new Place("museum", null));
        assertEquals(CrowdModel.rawBase(open, null, satAfternoon) * CrowdModel.UNKNOWN_HOURS_FACTOR,
                CrowdModel.rawBase(unknown, null, satAfternoon), 1e-9);
    }

    @Test
    void touristCellBusierAtDayThanNight() {
        var rynek = List.of(new Place("attraction", null), new Place("museum", null), new Place("cafe", null),
                new Place("restaurant", null), new Place("church", null));
        double[] transit = new double[24];
        java.util.Arrays.fill(transit, 0.5);
        double peak = CrowdModel.peakPotential(rynek, transit);
        double day = CrowdModel.normalise(CrowdModel.rawBase(rynek, transit, satAfternoon), peak);
        double night = CrowdModel.normalise(CrowdModel.rawBase(rynek, transit, satNight), peak);
        assertTrue(day > 0.6, "day " + day);
        assertTrue(night < 0.2, "night " + night);
        assertEquals(0, CrowdModel.normalise(5, 0));
        assertEquals(1, CrowdModel.normalise(1000, 10));
    }

    @Test
    void surveyDecaysWithHalfLife() {
        Instant now = Instant.parse("2026-10-03T12:00:00Z");
        Survey fresh = CrowdModel.survey(List.of(new Report(2, now)), now);
        assertEquals(1.0, fresh.value(), 1e-9);
        assertEquals(1.0, fresh.weight(), 1e-9);
        Survey old = CrowdModel.survey(List.of(new Report(2, now.minusSeconds(30 * 60))), now);
        assertEquals(0.5, old.weight(), 1e-9);
        // a fresh "luźno" outweighs a 1h old "tłoczno" 4:1
        Survey mixed = CrowdModel.survey(List.of(new Report(0, now), new Report(2, now.minusSeconds(3600))), now);
        assertEquals(0.2, mixed.value(), 1e-9);
    }

    @Test
    void liveHiddenBelowThreeUsers() {
        assertNull(CrowdModel.live(0));
        assertNull(CrowdModel.live(2));
        assertEquals(0.15, CrowdModel.live(3), 1e-9);
        assertEquals(1.0, CrowdModel.live(50), 1e-9);
    }

    @Test
    void combineFallsBackToBaseAndLetsSurveysWin() {
        Estimate onlyBase = CrowdModel.combine(0.8, null, null);
        assertEquals(0.8, onlyBase.crowd(), 1e-9);
        assertEquals("tłoczno", onlyBase.label());
        assertEquals("base", onlyBase.source());
        assertEquals(1.0, (double) onlyBase.mix().get("base"), 1e-9);

        // two fresh "luźno" answers pull a crowded base down
        Estimate surveyed = CrowdModel.combine(0.8, new Survey(0, 2, 2), null);
        assertEquals(0.44, surveyed.crowd(), 1e-9);
        assertEquals("średnio", surveyed.label());
        assertEquals(2, surveyed.mix().get("reports"));
        Map<String, Object> mix = CrowdModel.combine(0.1, new Survey(1, 0.5, 1), 0.5).mix();
        assertEquals(1.0, (double) mix.get("base") + (double) mix.get("survey") + (double) mix.get("live"), 0.011);
    }

    @Test
    void hexGridMapsPointsToStableCells() {
        CrowdGrid g = CrowdGrid.of("krakow", new BBox(19.90, 50.04, 19.98, 50.08), 100);
        // ~5.7 x 4.5 km of 100 m hexes (8660 m2 each) -> roughly 3000 cells
        assertTrue(g.allCells().size() > 2500 && g.allCells().size() < 4000, "cells " + g.allCells().size());
        assertNotNull(g.cellAt(50.0401, 19.9001));
        assertNotNull(g.cellAt(50.0799, 19.9799));
        assertNull(g.cellAt(50.0, 19.93));

        String rynek = g.cellAt(50.0617, 19.9373);
        int[] qr = CrowdGrid.xy(rynek);
        double[] c = g.center(qr[0], qr[1]);
        // the point is within the circumradius of its cell's centre
        assertTrue(pl.krakowbezbarier.api.common.GeoUtils.haversineM(c[0], c[1], 50.0617, 19.9373) <= g.radiusM() + 0.5);
        // the centre maps back to the same cell, and neighbours are ~100 m apart
        assertEquals(rynek, g.cellAt(c[0], c[1]));
        double[] n = g.center(qr[0] + 1, qr[1]);
        assertEquals(100, pl.krakowbezbarier.api.common.GeoUtils.haversineM(c[0], c[1], n[0], n[1]), 1);

        List<double[]> poly = g.polygon(qr[0], qr[1]);
        assertEquals(7, poly.size());
        assertArrayEquals(poly.get(0), poly.get(6));
        for (int i = 0; i < 6; i++) {
            assertEquals(g.radiusM(), pl.krakowbezbarier.api.common.GeoUtils.haversineM(c[0], c[1], poly.get(i)[0], poly.get(i)[1]), 0.5);
        }
        assertTrue(g.intersects(qr[0], qr[1], new BBox(19.937, 50.0615, 19.938, 50.062)));
        assertFalse(g.intersects(qr[0], qr[1], new BBox(19.95, 50.07, 19.96, 50.075)));
    }

    @Test
    void gtfsHelpers() {
        assertEquals(List.of("stop_1", "Grodzki, \"Urząd\"", "", "50.08"),
                GtfsTransitImporter.splitCsv("stop_1,\"Grodzki, \"\"Urząd\"\"\",,50.08"));
        assertEquals(5, GtfsTransitImporter.hour("05:35:00"));
        assertEquals(1, GtfsTransitImporter.hour("25:10:00"));
        assertEquals(-1, GtfsTransitImporter.hour("x"));
        double[] a = new double[24], b = new double[24];
        a[8] = 10; b[8] = 5; b[20] = 2;
        var n = GtfsTransitImporter.normalise(Map.of("a", a, "b", b));
        assertEquals(1.0, n.get("a")[8]);
        assertEquals(0.5, n.get("b")[8]);
        assertEquals(0.2, n.get("b")[20]);
    }

    @Test
    void demoBaseBusyOldTownQuietOutskirts() {
        double rynek = CrowdModel.demoBase("krakow:9:9", 50.0617, 19.9373, satAfternoon);
        double outskirts = CrowdModel.demoBase("krakow:0:0", 50.041, 19.901, satAfternoon);
        assertTrue(rynek > 0.8, "rynek " + rynek);
        assertTrue(outskirts < 0.25, "outskirts " + outskirts);
        assertTrue(CrowdModel.demoBase("krakow:9:9", 50.0617, 19.9373, satNight) < rynek);
    }
}
