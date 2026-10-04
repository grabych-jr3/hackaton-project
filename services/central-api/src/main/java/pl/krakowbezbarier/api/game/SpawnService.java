package pl.krakowbezbarier.api.game;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.game.GameRules.Rarity;
import pl.krakowbezbarier.api.game.GameRules.Species;

import java.security.SecureRandom;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.*;

/** Creatures on the map: long-lived demo seeds, "spawn here" test spawns, per-user catches. */
@Service
public class SpawnService {
    private static final Logger log = LoggerFactory.getLogger(SpawnService.class);
    static final Duration SEED_TTL = Duration.ofDays(30);
    static final Duration USER_TTL = Duration.ofHours(2);
    static final int MAX_USER_SPAWNS = 3;

    /** Demo spawns around Kraków centre. seedKey is stable so the refresher upserts instead of duplicating. */
    public record Seed(String key, String speciesId, double lat, double lng, String label) {}

    public static final List<Seed> SEEDS = List.of(
            new Seed("wawel-smok", "smok", 50.0532, 19.9340, "Smocza Jama, Wawel"),
            new Seed("rynek-golab", "golab", 50.0614, 19.9366, "Rynek Główny"),
            new Seed("sukiennice-golab", "golab", 50.0619, 19.9378, "Sukiennice"),
            new Seed("mariacka-sowa", "sowa", 50.0617, 19.9399, "Bazylika Mariacka"),
            new Seed("collegium-sowa", "sowa", 50.0614, 19.9334, "Collegium Maius (dziedziniec)"),
            new Seed("planty-jez", "jez", 50.0640, 19.9330, "Planty"),
            new Seed("barbakan-jez", "jez", 50.0652, 19.9413, "Barbakan / Planty"),
            new Seed("bulwary-wydra", "wydra", 50.0510, 19.9370, "Bulwary Wiślane"),
            new Seed("kazimierz-lis", "lis", 50.0516, 19.9480, "Kazimierz, Szeroka"),
            new Seed("bernatka-wydra", "wydra", 50.0487, 19.9462, "Kładka Ojca Bernatka"),
            new Seed("podgorze-niedzwiedz", "niedzwiedz", 50.0471, 19.9500, "Podgórze, Rynek Podgórski"),
            new Seed("muzeum-lis", "lis", 50.0602, 19.9243, "Muzeum Narodowe"),
            new Seed("massolit-golab", "golab", 50.0626, 19.9258, "Massolit Books"),
            new Seed("schindler-bocian", "bocian", 50.0476, 19.9612, "Fabryka Schindlera"));

    public record SpawnDto(String id, double lat, double lng, String speciesId, String name, String emoji,
                           String rarity, Instant expiresAt, String kind, boolean caughtByMe) {}

    public record SpawnHereRequest(Double lat, Double lng, String speciesId) {}

    private final JdbcTemplate jdbc;
    private final GameService game;
    private final SecureRandom random = new SecureRandom();

    public SpawnService(JdbcTemplate jdbc, GameService game) {
        this.jdbc = jdbc;
        this.game = game;
    }

    /** Runs at startup and every 10 min: (re)creates every seed and pushes expires_at to now + 30 days. */
    @Scheduled(initialDelay = 0, fixedDelay = 600_000)
    public void refreshSeeds() {
        try {
            int n = 0;
            for (Seed s : SEEDS) {
                Species sp = game.species(s.speciesId()).orElseThrow();
                n += jdbc.update("""
                        INSERT INTO creature_spawn (id, geom, species, rarity, expires_at, kind, seed_key)
                        VALUES (?, ST_SetSRID(ST_MakePoint(?, ?), 4326), ?, ?, now() + interval '30 days', 'seed', ?)
                        ON CONFLICT (seed_key) DO UPDATE SET expires_at = EXCLUDED.expires_at,
                          geom = EXCLUDED.geom, species = EXCLUDED.species, rarity = EXCLUDED.rarity""",
                        UUID.randomUUID(), s.lng(), s.lat(), sp.id(), sp.rarity().name(), s.key());
            }
            log.debug("Refreshed {} seed spawns", n);
        } catch (Exception e) {
            log.warn("Seed spawn refresh failed: {}", e.getMessage());
        }
    }

    public List<SpawnDto> list(double[] bbox, UUID userId) {
        StringBuilder sql = new StringBuilder("""
                SELECT s.id, ST_Y(s.geom) AS lat, ST_X(s.geom) AS lng, s.species, s.rarity, s.expires_at, s.kind,
                       EXISTS (SELECT 1 FROM spawn_catch c WHERE c.spawn_id = s.id AND c.user_id = CAST(? AS uuid)) AS caught
                FROM creature_spawn s WHERE s.expires_at > now()""");
        List<Object> args = new ArrayList<>();
        args.add(userId);
        if (bbox != null) {
            sql.append(" AND s.geom && ST_MakeEnvelope(?, ?, ?, ?, 4326)");
            for (double v : bbox) args.add(v);
        }
        sql.append(" ORDER BY s.expires_at DESC");
        return jdbc.query(sql.toString(), (rs, i) -> toDto(rs.getObject("id").toString(), rs.getDouble("lat"),
                rs.getDouble("lng"), rs.getString("species"), rs.getString("rarity"),
                rs.getTimestamp("expires_at").toInstant(), rs.getString("kind"), rs.getBoolean("caught")), args.toArray());
    }

    /** "minLng,minLat,maxLng,maxLat" -> array, or null when absent. */
    public static double[] parseBbox(String bbox) {
        if (bbox == null || bbox.isBlank()) return null;
        String[] p = bbox.split(",");
        if (p.length != 4) throw ApiException.badRequest("bbox must be minLng,minLat,maxLng,maxLat");
        double[] b = new double[4];
        try {
            for (int i = 0; i < 4; i++) b[i] = Double.parseDouble(p[i].trim());
        } catch (NumberFormatException e) {
            throw ApiException.badRequest("bbox must contain 4 numbers");
        }
        if (b[0] > b[2] || b[1] > b[3]) throw ApiException.badRequest("bbox min must be <= max");
        return b;
    }

    @Transactional
    public SpawnDto spawnHere(UUID userId, SpawnHereRequest req) {
        if (req == null || req.lat() == null || req.lng() == null) throw ApiException.badRequest("lat and lng are required");
        double lat = req.lat(), lng = req.lng();
        if (lat < -90 || lat > 90 || lng < -180 || lng > 180) throw ApiException.badRequest("invalid lat/lng");
        Species sp;
        if (req.speciesId() != null && !req.speciesId().isBlank()) {
            sp = game.species(req.speciesId()).orElseThrow(() -> ApiException.badRequest("Unknown speciesId " + req.speciesId()));
        } else {
            sp = randomCommonOrRare();
        }
        // Keep at most MAX_USER_SPAWNS active: expire the oldest ones (catch_record may reference them, so no delete).
        List<UUID> active = jdbc.queryForList("""
                SELECT id FROM creature_spawn WHERE kind = 'user' AND created_by = ? AND expires_at > now()
                ORDER BY created_at ASC FOR UPDATE""", UUID.class, userId);
        for (int i = 0; i <= active.size() - MAX_USER_SPAWNS; i++) {
            jdbc.update("UPDATE creature_spawn SET expires_at = now() WHERE id = ?", active.get(i));
        }
        UUID id = UUID.randomUUID();
        Instant expires = Instant.now().plus(USER_TTL);
        jdbc.update("""
                INSERT INTO creature_spawn (id, geom, species, rarity, expires_at, kind, created_by)
                VALUES (?, ST_SetSRID(ST_MakePoint(?, ?), 4326), ?, ?, ?, 'user', ?)""",
                id, lng, lat, sp.id(), sp.rarity().name(), Timestamp.from(expires), userId);
        return toDto(id.toString(), lat, lng, sp.id(), sp.rarity().name(), expires, "user", false);
    }

    Species randomCommonOrRare() {
        List<Species> pool = game.catalog().species().stream()
                .filter(s -> s.rarity() == Rarity.common || s.rarity() == Rarity.rare).toList();
        if (pool.isEmpty()) pool = game.catalog().species();
        return pool.get(random.nextInt(pool.size()));
    }

    /** Species of a spawn (for catches), if the spawn exists. */
    public Optional<Species> speciesOf(UUID spawnId) {
        List<String> s = jdbc.queryForList("SELECT species FROM creature_spawn WHERE id = ?", String.class, spawnId);
        return s.isEmpty() ? Optional.empty() : game.species(s.get(0));
    }

    public void markCaught(UUID userId, UUID spawnId) {
        jdbc.update("INSERT INTO spawn_catch (user_id, spawn_id) VALUES (?, ?) ON CONFLICT DO NOTHING", userId, spawnId);
    }

    private SpawnDto toDto(String id, double lat, double lng, String speciesId, String rarity, Instant expiresAt,
                           String kind, boolean caught) {
        Optional<Species> sp = game.species(speciesId);
        return new SpawnDto(id, lat, lng, speciesId, sp.map(Species::name).orElse(speciesId),
                sp.map(Species::emoji).orElse("❓"), sp.map(s -> s.rarity().name()).orElse(rarity), expiresAt, kind, caught);
    }
}
