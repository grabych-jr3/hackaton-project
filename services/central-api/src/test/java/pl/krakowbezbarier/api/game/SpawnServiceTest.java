package pl.krakowbezbarier.api.game;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.place.PlaceRepository;

import java.util.*;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SpawnServiceTest {
    final ObjectMapper om = JsonMapper.builder().findAndAddModules().build();
    JdbcTemplate jdbc;
    GameService game;
    SpawnService svc;
    SpawnSnapper snapper;
    final UUID user = UUID.randomUUID();

    @BeforeEach
    void setUp() throws Exception {
        jdbc = mock(JdbcTemplate.class);
        game = new GameService(jdbc, om, mock(PointsService.class), mock(PlaceRepository.class));
        snapper = mock(SpawnSnapper.class);
        when(snapper.snap(anyDouble(), anyDouble())).thenAnswer(i -> new SpawnSnapper.Result(i.getArgument(0), i.getArgument(1), SpawnSnapper.Method.original, 0));
        svc = new SpawnService(jdbc, game, snapper);
    }

    @Test
    void seedsCoverCentreWithOneLegendarySmok() {
        assertTrue(SpawnService.SEEDS.size() >= 12);
        assertEquals(SpawnService.SEEDS.size(), SpawnService.SEEDS.stream().map(SpawnService.Seed::key).distinct().count());
        Map<GameRules.Rarity, Long> byRarity = SpawnService.SEEDS.stream()
                .collect(Collectors.groupingBy(s -> game.species(s.speciesId()).orElseThrow().rarity(), Collectors.counting()));
        assertEquals(1L, byRarity.get(GameRules.Rarity.legendary));
        assertTrue(byRarity.get(GameRules.Rarity.common) > byRarity.getOrDefault(GameRules.Rarity.epic, 0L));
        SpawnService.Seed smok = SpawnService.SEEDS.stream().filter(s -> s.speciesId().equals("smok")).findFirst().orElseThrow();
        assertEquals(50.0541, smok.lat(), 0.002); // near Wawel
        for (var s : SpawnService.SEEDS) { // Kraków centre
            assertTrue(s.lat() > 50.04 && s.lat() < 50.07 && s.lng() > 19.92 && s.lng() < 19.97, s.key());
        }
    }

    @Test
    void refreshSeedsUpsertsEverySeed() {
        when(jdbc.update(anyString(), any(Object[].class))).thenReturn(1);
        svc.refreshSeeds();
        ArgumentCaptor<Object[]> args = ArgumentCaptor.forClass(Object[].class);
        verify(jdbc, times(SpawnService.SEEDS.size())).update(contains("ON CONFLICT (seed_key)"), args.capture());
        Set<Object> keys = args.getAllValues().stream().map(a -> a[a.length - 1]).collect(Collectors.toSet());
        assertEquals(SpawnService.SEEDS.size(), keys.size());
    }

    @Test
    @SuppressWarnings("unchecked")
    void bboxFilterIsApplied() {
        double[] b = SpawnService.parseBbox("19.93,50.05,19.94,50.06");
        assertArrayEquals(new double[]{19.93, 50.05, 19.94, 50.06}, b);
        svc.list(b, user);
        ArgumentCaptor<Object[]> args = ArgumentCaptor.forClass(Object[].class);
        verify(jdbc).query(contains("ST_MakeEnvelope(?, ?, ?, ?, 4326)"), any(RowMapper.class), args.capture());
        assertEquals(List.of(user, 19.93, 50.05, 19.94, 50.06), Arrays.asList(args.getValue()));

        reset(jdbc);
        svc.list(SpawnService.parseBbox(null), null);
        verify(jdbc).query(argThat((String sql) -> !sql.contains("ST_MakeEnvelope") && sql.contains("expires_at > now()")),
                any(RowMapper.class), any(Object[].class));

        assertThrows(ApiException.class, () -> SpawnService.parseBbox("1,2,3"));
        assertThrows(ApiException.class, () -> SpawnService.parseBbox("a,b,c,d"));
        assertThrows(ApiException.class, () -> SpawnService.parseBbox("20,50,19,51"));
    }

    @Test
    void spawnHereReplacesOldestWhenLimitReached() {
        UUID a = UUID.randomUUID(), b = UUID.randomUUID(), c = UUID.randomUUID();
        when(jdbc.queryForList(contains("kind = 'user'"), eq(UUID.class), any(Object[].class))).thenReturn(List.of(a, b, c));
        var dto = svc.spawnHere(user, new SpawnService.SpawnHereRequest(50.06, 19.93, "sowa"));
        verify(jdbc).update(contains("SET expires_at = now()"), eq(a));
        verify(jdbc, never()).update(contains("SET expires_at = now()"), eq(b));
        verify(jdbc).update(contains("'user'"), any(), eq(19.93), eq(50.06), eq("sowa"), eq("rare"), any(), eq(user));
        JsonNode j = om.valueToTree(dto);
        assertEquals("sowa", j.get("speciesId").asText());
        assertEquals("Motylosmok", j.get("name").asText());
        assertEquals("rare", j.get("rarity").asText());
        assertEquals("user", j.get("kind").asText());
        assertEquals(50.06, j.get("lat").asDouble());
        for (String k : List.of("id", "lng", "emoji", "expiresAt", "caughtByMe")) assertTrue(j.has(k), k);
    }

    @Test
    void spawnHereUnderLimitExpiresNothingAndRandomIsCommonOrRare() {
        when(jdbc.queryForList(contains("kind = 'user'"), eq(UUID.class), any(Object[].class))).thenReturn(List.of(UUID.randomUUID()));
        for (int i = 0; i < 20; i++) {
            var dto = svc.spawnHere(user, new SpawnService.SpawnHereRequest(50.06, 19.93, null));
            assertTrue(Set.of("common", "rare").contains(dto.rarity()));
        }
        verify(jdbc, never()).update(contains("SET expires_at = now()"), any(Object[].class));
        assertThrows(ApiException.class, () -> svc.spawnHere(user, new SpawnService.SpawnHereRequest(50.0, 19.0, "nope")));
        assertThrows(ApiException.class, () -> svc.spawnHere(user, new SpawnService.SpawnHereRequest(null, 19.0, null)));
    }

    @Test
    void spawnHereReturnsSnappedCoordinates() {
        when(snapper.snap(50.06, 19.93)).thenReturn(new SpawnSnapper.Result(50.0601, 19.9302, SpawnSnapper.Method.ors, 15));
        var dto = svc.spawnHere(user, new SpawnService.SpawnHereRequest(50.06, 19.93, "sowa"));
        assertEquals(50.0601, dto.lat());
        assertEquals(19.9302, dto.lng());
        verify(jdbc).update(contains("'user'"), any(), eq(19.9302), eq(50.0601), eq("sowa"), eq("rare"), any(), eq(user));
    }

    @Test
    void seedSnapIsCachedAndReused() {
        SpawnService.Seed s = SpawnService.SEEDS.get(0);
        when(snapper.snap(s.lat(), s.lng())).thenReturn(new SpawnSnapper.Result(50.1, 19.9, SpawnSnapper.Method.overpass, 7));
        Map<String, double[]> cache = new HashMap<>();
        assertArrayEquals(new double[]{50.1, 19.9}, svc.seedPoint(s, cache));
        verify(jdbc).update(contains("INSERT INTO spawn_seed_snap"), eq(s.key()), eq(s.lat()), eq(s.lng()), eq(50.1), eq(19.9), eq("overpass"));

        reset(snapper, jdbc);
        cache.put(s.key(), new double[]{s.lat(), s.lng(), 50.2, 19.8});
        assertArrayEquals(new double[]{50.2, 19.8}, svc.seedPoint(s, cache));
        verifyNoInteractions(snapper, jdbc);

        // failure (original) is returned but not cached -> retried next refresh
        when(snapper.snap(anyDouble(), anyDouble())).thenAnswer(i -> new SpawnSnapper.Result(i.getArgument(0), i.getArgument(1), SpawnSnapper.Method.original, 0));
        assertArrayEquals(new double[]{s.lat(), s.lng()}, svc.seedPoint(s, new HashMap<>()));
        verify(jdbc, never()).update(contains("spawn_seed_snap"), any(Object[].class));
    }
}
