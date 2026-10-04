package pl.krakowbezbarier.api.ingest;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.support.TransactionCallback;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.client.ResourceAccessException;
import pl.krakowbezbarier.api.common.GeoUtils.BBox;
import pl.krakowbezbarier.api.health.SourceStatusRepository;
import pl.krakowbezbarier.api.place.PlaceRepository;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class OsmImportTest {
    static final ObjectMapper OM = new ObjectMapper();
    static final BBox BBOX = new BBox(19.90, 50.04, 19.98, 50.075);
    static final String OK = """
            {"osm3s":{"timestamp_osm_base":"2026-05-06T03:25:00Z"},"elements":[
             {"type":"node","id":1,"lat":50.06,"lon":19.94,"tags":{"name":"Muzeum","tourism":"museum","wheelchair":"yes"}}]}
            """;
    static final List<String> MIRRORS = List.of("http://m1", "http://m2", "http://m3", "http://m4");

    /** Fake HTTP transport: mirrors listed in {@code timeouts} fail with a connect timeout, others return OK. */
    static OverpassAdapter adapter(List<String> calls, List<String> timeouts) {
        return new OverpassAdapter(MIRRORS, (url, q) -> {
            calls.add(url);
            if (timeouts.contains(url)) throw new ResourceAccessException("I/O error on POST " + url + ": Connect timed out");
            return OK;
        }, OM);
    }

    @Test
    void defaultsWhenUrlsBlank() {
        assertEquals(OverpassAdapter.DEFAULT_URLS, new OverpassAdapter(List.of(), (u, q) -> OK, OM).urls());
        assertEquals(List.of("a", "b"), OverpassAdapter.parseUrls(" a, ,b "));
        assertEquals(4, OverpassAdapter.DEFAULT_URLS.size());
        assertTrue(OverpassAdapter.DEFAULT_URLS.get(0).contains("overpass-api.de"));
    }

    @Test
    void failsOverToThirdMirrorInOrder() throws Exception {
        List<String> calls = new ArrayList<>();
        var a = adapter(calls, List.of("http://m1", "http://m2"));
        var places = a.fetch(BBOX);
        assertEquals(List.of("http://m1", "http://m2", "http://m3"), calls);
        assertEquals("http://m3", a.lastOrigin());
        assertEquals(1, places.size());
        assertEquals("osm:node:1", places.get(0).id());
    }

    @Test
    void allMirrorsFailThrows() {
        List<String> calls = new ArrayList<>();
        var a = adapter(calls, MIRRORS);
        Exception e = assertThrows(Exception.class, () -> a.fetch(BBOX));
        assertEquals(MIRRORS, calls);
        assertTrue(e.getMessage().contains("All Overpass mirrors failed"));
        assertNull(a.lastOrigin());
    }

    record Ctx(ImportJob job, SourceStatusRepository status, PlaceRepository places, JdbcTemplate jdbc) {}

    @SuppressWarnings("unchecked")
    static Ctx job(SourceAdapter adapter, int existingOsmPlaces) {
        var places = mock(PlaceRepository.class);
        var status = mock(SourceStatusRepository.class);
        var jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject(anyString(), eq(Integer.class), any(Object[].class))).thenReturn(existingOsmPlaces);
        var tx = mock(TransactionTemplate.class);
        doAnswer(inv -> {
            inv.<java.util.function.Consumer<Object>>getArgument(0).accept(null);
            return null;
        }).when(tx).executeWithoutResult(any());
        var job = new ImportJob(List.of(adapter), places, status, jdbc, tx, OM, "classpath:seed/osm_krakow_center.json", false);
        job.retryDelaysMs = new long[]{0, 0, 0};
        return new Ctx(job, status, places, jdbc);
    }

    @Test
    void successRecordsMirrorInSourceStatus() {
        var a = adapter(new ArrayList<>(), List.of("http://m1", "http://m2"));
        var c = job(a, 0);
        assertTrue(c.job().importCity(a, "krakow", BBOX));
        verify(c.status()).success("osm", "http://m3");
        verify(c.status(), never()).error(anyString(), anyString(), eq(true));
    }

    @Test
    void allFailMarksStaleAndKeepsExistingOsmData() {
        var c = job(adapter(new ArrayList<>(), MIRRORS), 42);
        assertFalse(c.job().importCity(adapter(new ArrayList<>(), MIRRORS), "krakow", BBOX));
        verify(c.status(), times(4)).error(eq("osm"), contains("All Overpass mirrors failed"), eq(false));
        verify(c.status()).error(eq("osm"), contains("All Overpass mirrors failed"), eq(true));
        verify(c.status(), never()).snapshotLoaded(any(), any(), any());
        verify(c.places(), never()).upsertPlace(any(), any(), any(), any(), anyDouble(), anyDouble(), any(), any(), anyBoolean());
    }

    @Test
    void allFailWithNoOsmPlacesImportsSnapshot() {
        var a = adapter(new ArrayList<>(), MIRRORS);
        var c = job(a, 0);
        assertFalse(c.job().importCity(a, "krakow", BBOX));
        verify(c.status()).error(eq("osm"), anyString(), eq(true));
        verify(c.status()).snapshotLoaded(eq("osm"), startsWith("snapshot:osm_krakow_center.json@"), anyString());
        verify(c.places(), atLeast(500)).upsertPlace(startsWith("osm:"), eq("krakow"), anyString(), anyString(),
                anyDouble(), anyDouble(), any(), any(), eq(false));
        // fetched_at = snapshot timestamp_osm_base, not "now"
        var ts = org.mockito.ArgumentCaptor.forClass(Instant.class);
        verify(c.places(), atLeastOnce()).upsertOsmFact(anyString(), anyString(), any(), anyString(), ts.capture());
        assertTrue(ts.getAllValues().stream().allMatch(t -> t.isBefore(Instant.now().minusSeconds(3600))));
    }
}
