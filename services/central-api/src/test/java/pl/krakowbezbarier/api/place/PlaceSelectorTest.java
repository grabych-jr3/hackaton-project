package pl.krakowbezbarier.api.place;

import org.junit.jupiter.api.Test;
import pl.krakowbezbarier.api.place.PlaceSelector.Candidate;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class PlaceSelectorTest {
    /** 11 demo places clustered in the Old Town + a 40x40 grid of OSM places (~110 m step) over Kraków. */
    static List<Candidate> city() {
        List<Candidate> all = new ArrayList<>();
        for (int i = 0; i < 11; i++) all.add(new Candidate("demo:" + i, "Demo " + i, "museum", 50.061 + i * 0.0003, 19.937, true, 3));
        String[] cats = {"cafe", "museum", "restaurant", "park", "church", "attraction"};
        for (int i = 0; i < 40; i++)
            for (int j = 0; j < 40; j++) {
                int k = i * 40 + j;
                all.add(new Candidate("osm:node:" + k, k % 7 == 0 ? null : "P" + k, cats[k % cats.length],
                        50.03 + i * 0.001, 19.90 + j * 0.0015, false, k % 5 == 0 ? 2 : 0));
            }
        return all;
    }

    @Test
    void limitRespectedAndClamped() {
        assertEquals(50, PlaceSelector.select(city(), 50, 300).size());
        assertEquals(20, PlaceSelector.select(city(), 20, 300).size());
        assertEquals(200, PlaceSelector.clampLimit(1000, 50));
        assertEquals(50, PlaceSelector.clampLimit(null, 50));
        assertEquals(1, PlaceSelector.clampLimit(0, 50));
    }

    @Test
    void demoPlacesAlwaysIncludedFirst() {
        List<Candidate> sel = PlaceSelector.select(city(), 50, 300);
        for (int i = 0; i < 11; i++) assertTrue(sel.get(i).demo());
        assertEquals(11, sel.stream().filter(Candidate::demo).count());
    }

    @Test
    void osmPicksAtLeast300mApart() {
        List<Candidate> osm = PlaceSelector.select(city(), 50, 300).stream().filter(c -> !c.demo()).toList();
        assertEquals(39, osm.size());
        for (int a = 0; a < osm.size(); a++)
            for (int b = a + 1; b < osm.size(); b++)
                assertTrue(PlaceSelector.distanceM(osm.get(a).lat(), osm.get(a).lng(), osm.get(b).lat(), osm.get(b).lng()) >= 300);
    }

    @Test
    void rankingPrefersAccessibilityFacts() {
        Candidate withFacts = new Candidate("osm:b", "Cafe", "cafe", 50.0, 19.9, false, 2);
        Candidate attractionNoFacts = new Candidate("osm:a", "Wawel", "attraction", 50.1, 19.9, false, 0);
        Candidate cafeNoFacts = new Candidate("osm:c", "Cafe2", "cafe", 50.2, 19.9, false, 0);
        List<Candidate> sel = PlaceSelector.select(List.of(cafeNoFacts, attractionNoFacts, withFacts), 3, 300);
        assertEquals(List.of("osm:b", "osm:a", "osm:c"), sel.stream().map(Candidate::id).toList());
        assertEquals("osm:b", PlaceSelector.select(List.of(attractionNoFacts, withFacts), 1, 300).get(0).id());
    }

    @Test
    void deterministic() {
        List<Candidate> a = new ArrayList<>(city());
        List<Candidate> b = new ArrayList<>(city());
        java.util.Collections.reverse(b);
        assertEquals(PlaceSelector.select(a, 50, 300), PlaceSelector.select(b, 50, 300));
    }
}
