package pl.krakowbezbarier.api.game;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class SpawnSnapperTest {
    // building square around (50.0610, 19.9370), footway along lat 50.0615
    static final String INSIDE = """
            {"elements":[
             {"type":"way","tags":{"building":"yes"},"geometry":[{"lat":50.0608,"lon":19.9367},{"lat":50.0608,"lon":19.9373},
               {"lat":50.0612,"lon":19.9373},{"lat":50.0612,"lon":19.9367},{"lat":50.0608,"lon":19.9367}]},
             {"type":"way","tags":{"highway":"footway"},"geometry":[{"lat":50.0615,"lon":19.9360},{"lat":50.0615,"lon":19.9380}]}]}""";

    @Test
    void orsSnapUsedWhenAvailable() {
        List<String> calls = new ArrayList<>();
        var s = new SpawnSnapper((lat, lng) -> new double[]{50.0615, 19.9370, 12}, (u, q) -> { calls.add(u); return INSIDE; }, List.of("m"));
        var r = s.snap(50.0610, 19.9370);
        assertEquals(SpawnSnapper.Method.ors, r.method());
        assertEquals(50.0615, r.lat());
        assertTrue(calls.isEmpty());
    }

    @Test
    void insideBuildingMovedToFootwayViaOverpassWhenOrsFails() {
        List<String> calls = new ArrayList<>();
        var s = new SpawnSnapper((lat, lng) -> { throw new RuntimeException("down"); }, (u, q) -> {
            calls.add(u);
            if (u.equals("bad")) throw new RuntimeException("timeout");
            assertTrue(q.contains("around:15,50.0610000,19.9370000"));
            return INSIDE;
        }, List.of("bad", "good"));
        var r = s.snap(50.0610, 19.9370);
        assertEquals(SpawnSnapper.Method.overpass, r.method());
        assertEquals(50.0615, r.lat(), 1e-7);
        assertEquals(19.9370, r.lng(), 1e-7);
        assertEquals(55.6, r.movedM(), 1.0);
        assertEquals(List.of("bad", "good"), calls);
    }

    @Test
    void noKeyAndOutsideBuildingKeepsPoint() {
        var s = new SpawnSnapper(null, (u, q) -> INSIDE, List.of("m"));
        var r = s.snap(50.0620, 19.9390);
        assertEquals(SpawnSnapper.Method.outdoor, r.method());
        assertEquals(50.0620, r.lat());
    }

    @Test
    void allFailuresKeepOriginal() {
        var s = new SpawnSnapper((lat, lng) -> null, (u, q) -> { throw new RuntimeException("x"); }, List.of("a", "b"));
        var r = s.snap(50.0610, 19.9370);
        assertEquals(SpawnSnapper.Method.original, r.method());
        assertEquals(50.0610, r.lat());
        assertEquals(19.9370, r.lng());
        var s2 = new SpawnSnapper((lat, lng) -> new double[]{50.07, 19.94, 500}, (u, q) -> "{}", List.of("a"));
        assertEquals(SpawnSnapper.Method.original, s2.snap(50.0610, 19.9370).method());
    }
}
