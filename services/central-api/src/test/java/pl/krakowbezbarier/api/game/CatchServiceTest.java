package pl.krakowbezbarier.api.game;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import pl.krakowbezbarier.api.game.GameRules.*;
import pl.krakowbezbarier.api.game.kafka.Events;
import pl.krakowbezbarier.api.game.kafka.PhotoSubmittedProducer;
import pl.krakowbezbarier.api.place.PlaceRepository;

import java.util.*;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class CatchServiceTest {
    final ObjectMapper om = JsonMapper.builder().findAndAddModules().build();
    JdbcTemplate jdbc;
    GameService game;
    CatchService svc;
    final UUID user = UUID.randomUUID();
    final UUID catchId = UUID.randomUUID();
    final Species kerbik = new Species("kerbik", "Kerbik", "🧱", Rarity.rare);

    @BeforeEach
    void setUp() {
        jdbc = mock(JdbcTemplate.class);
        game = mock(GameService.class);
        svc = new CatchService(jdbc, om, mock(PhotoSubmittedProducer.class), game, mock(PlaceRepository.class), "build/tmp-photos");
        when(game.rollSpecies(any())).thenReturn(kerbik);
    }

    private void pendingCatch(String status) {
        Map<String, Object> row = new HashMap<>();
        row.put("user_id", user);
        row.put("place_id", null);
        row.put("status", status);
        row.put("lng", 19.93);
        row.put("lat", 50.06);
        when(jdbc.queryForList(contains("FOR UPDATE OF c"), any(Object[].class))).thenReturn(List.of(row));
    }

    private Events.PhotoAnalyzed ok(String phash) throws Exception {
        JsonNode r = om.readTree("""
                {"steps":3,"kerbRange":">7","widthRange":"<70","ramp":false,"handrail":false,
                 "obstacles":["słupek"],"difficulty":8,"confidence":0.9}""");
        return new Events.PhotoAnalyzed(catchId.toString(), "OK", r, phash, null);
    }

    @Test
    void okAnalysisGrantsCreatureWithoutPoints() throws Exception {
        pendingCatch("PENDING");
        when(jdbc.queryForList(contains("SELECT phash"), eq(String.class), any(Object[].class))).thenReturn(List.of());
        svc.applyAnalysis(ok("ffff0000ffff0000"));
        verify(game).addCreature(user, "kerbik");
        verify(jdbc).update(contains("status = 'OK'"), any(), any(), any(), eq("kerbik"), any(), eq(catchId));
        verify(jdbc, never()).update(contains("points_ledger"), any(Object[].class));
        verify(jdbc, never()).update(contains("app_user"), any(Object[].class));
    }

    @Test
    void severityMappedFromAiLikeReports() throws Exception {
        BarrierReport r = CatchService.reportFromAi("p1", ok("x").result());
        assertEquals(3, r.stepsOr0());
        assertEquals(CurbRange.high, r.curb());
        assertEquals(PassageWidth.narrow, r.passage());
        assertTrue(r.noRamp());
        assertTrue(r.obstacles());
        assertTrue(r.uneven());
        assertEquals(10, r.severity());
        assertEquals(0, CatchService.reportFromAi(null, om.readTree("{\"steps\":0,\"ramp\":true,\"obstacles\":[]}")).severity());
    }

    @Test
    void alreadyProcessedIsIgnored() throws Exception {
        pendingCatch("OK");
        svc.applyAnalysis(ok("ffff0000ffff0000"));
        verify(game, never()).addCreature(any(), any());
        verify(jdbc, never()).update(anyString(), any(Object[].class));
    }

    @Test
    void duplicatePhashRejectedWithoutCreature() throws Exception {
        pendingCatch("PENDING");
        when(jdbc.queryForList(contains("SELECT phash"), eq(String.class), any(Object[].class)))
                .thenReturn(List.of("ffff0000ffff0001"));
        svc.applyAnalysis(ok("ffff0000ffff0000"));
        verify(game, never()).addCreature(any(), any());
        verify(jdbc).update(contains("status = 'REJECTED'"), eq(CatchService.REASON_DUPLICATE), any(), any(), eq(catchId));
    }

    @Test
    void getResponseShape() throws Exception {
        Map<String, Object> row = new HashMap<>();
        row.put("id", catchId);
        row.put("status", "OK");
        row.put("reason", null);
        row.put("species_id", "kerbik");
        row.put("ai_result", "{\"steps\":3}");
        row.put("created_facts", "[]");
        when(jdbc.queryForList(contains("FROM catch_record WHERE id"), any(Object[].class))).thenReturn(List.of(row));
        when(game.species("kerbik")).thenReturn(Optional.of(kerbik));
        when(game.state(user)).thenReturn(new GameState(100, Map.of("kerbik", 1), List.of()));
        JsonNode j = om.valueToTree(svc.get(catchId, user));
        for (String k : List.of("catchId", "status", "reason", "result", "species", "points", "awarded", "state", "createdFacts")) {
            assertTrue(j.has(k), k);
        }
        assertEquals("kerbik", j.at("/species/id").asText());
        assertEquals("rare", j.at("/species/rarity").asText());
        assertEquals("🧱", j.at("/species/emoji").asText());
        assertEquals(25, j.get("points").asInt());
        assertEquals(0, j.get("awarded").asInt());
        assertEquals(1, j.at("/state/caught/kerbik").asInt());
    }

    @Test
    void imageSniffing() {
        assertEquals(".jpg", CatchService.imageExtension(new byte[]{(byte) 0xFF, (byte) 0xD8, (byte) 0xFF, 0}));
        assertEquals(".png", CatchService.imageExtension(new byte[]{(byte) 0x89, 'P', 'N', 'G', 13, 10, 26, 10}));
        assertNull(CatchService.imageExtension("GIF89a".getBytes()));
    }

    @Test
    void listFiltersBySinceAndOrdersNewestFirst() {
        Map<String, Object> row = new HashMap<>();
        row.put("id", catchId);
        row.put("status", "OK");
        row.put("species_id", "kerbik");
        row.put("ai_result", "{\"steps\":3}");
        row.put("created_at", java.sql.Timestamp.from(java.time.Instant.parse("2026-10-04T10:00:00Z")));
        row.put("analyzed_at", java.sql.Timestamp.from(java.time.Instant.parse("2026-10-04T10:00:05Z")));
        row.put("place_id", "osm:1");
        when(jdbc.queryForList(anyString(), any(Object[].class))).thenReturn(List.of(row));
        when(game.species("kerbik")).thenReturn(Optional.of(kerbik));
        java.time.Instant since = java.time.Instant.parse("2026-10-04T09:00:00Z");

        List<Map<String, Object>> out = svc.list(user, since, 500);

        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        var args = org.mockito.ArgumentCaptor.forClass(Object[].class);
        verify(jdbc).queryForList(sql.capture(), args.capture());
        assertTrue(sql.getValue().contains("user_id = ?"));
        assertTrue(sql.getValue().contains("(analyzed_at > ? OR status = 'PENDING')"));
        assertTrue(sql.getValue().contains("ORDER BY created_at DESC"));
        assertEquals(user, args.getValue()[0]);
        assertEquals(java.sql.Timestamp.from(since), args.getValue()[1]);
        assertEquals(100, args.getValue()[2]);

        JsonNode j = om.valueToTree(out.get(0));
        for (String k : List.of("catchId", "status", "reason", "species", "points", "result", "createdAt", "analyzedAt", "placeId", "thumbnailUrl")) {
            assertTrue(j.has(k), k);
        }
        assertEquals("/catches/" + catchId + "/photo", j.get("thumbnailUrl").asText());
        assertEquals(25, j.get("points").asInt());
    }

    @Test
    void listWithoutSinceHasNoFilter() {
        when(jdbc.queryForList(anyString(), any(Object[].class))).thenReturn(List.of());
        svc.list(user, null, 20);
        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        var args = org.mockito.ArgumentCaptor.forClass(Object[].class);
        verify(jdbc).queryForList(sql.capture(), args.capture());
        assertFalse(sql.getValue().contains("analyzed_at >"));
        assertArrayEquals(new Object[]{user, 20}, args.getValue());
    }

    @Test
    void photoOwnerOnly() throws Exception {
        java.nio.file.Path f = java.nio.file.Files.createTempFile("catch", ".png");
        java.nio.file.Files.write(f, new byte[]{(byte) 0x89, 'P', 'N', 'G'});
        when(jdbc.queryForList(contains("photo_path"), eq(String.class), eq(catchId), eq(user))).thenReturn(List.of(f.toString()));
        CatchService.Photo p = svc.photo(catchId, user);
        assertEquals("image/png", p.contentType());
        assertEquals(4, p.bytes().length);
        var ex = assertThrows(pl.krakowbezbarier.api.common.ApiException.class, () -> svc.photo(catchId, UUID.randomUUID()));
        assertEquals(org.springframework.http.HttpStatus.NOT_FOUND, ex.status());
    }

    @Test
    void stalePendingMarkedFailedOnlyWherePending() {
        when(jdbc.update(anyString(), any(Object[].class))).thenReturn(2);
        assertEquals(2, svc.failStalePending());
        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        var args = org.mockito.ArgumentCaptor.forClass(Object[].class);
        verify(jdbc).update(sql.capture(), args.capture());
        assertTrue(sql.getValue().contains("SET status = 'FAILED'"));
        assertTrue(sql.getValue().contains("WHERE status = 'PENDING' AND created_at < ?"));
        assertEquals(CatchService.REASON_STALE, args.getValue()[0]);
        java.time.Instant cutoff = ((java.sql.Timestamp) args.getValue()[1]).toInstant();
        long ageSec = java.time.Duration.between(cutoff, java.time.Instant.now()).toSeconds();
        assertTrue(ageSec >= 119 && ageSec <= 125, "cutoff ~2 min ago: " + ageSec);
    }
}
