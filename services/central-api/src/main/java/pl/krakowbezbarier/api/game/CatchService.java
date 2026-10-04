package pl.krakowbezbarier.api.game;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.multipart.MultipartFile;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.game.kafka.Events;
import pl.krakowbezbarier.api.game.kafka.PhotoSubmittedProducer;
import pl.krakowbezbarier.api.place.FactValidator;
import pl.krakowbezbarier.api.place.PlaceRepository;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.*;

@Service
public class CatchService {
    private static final Logger log = LoggerFactory.getLogger(CatchService.class);
    static final long MAX_PHOTO_BYTES = 5L * 1024 * 1024;
    public static final String REASON_DUPLICATE = "To miejsce zostało już sfotografowane";
    static final int DAILY_LIMIT = 30;
    static final double MAX_SPAWN_DISTANCE_M = 50;
    static final Duration MAX_PHOTO_AGE = Duration.ofMinutes(10);

    private final JdbcTemplate jdbc;
    private final ObjectMapper om;
    private final PhotoSubmittedProducer producer;
    private final GameService game;
    private final PlaceRepository places;
    private final Path photosDir;

    public CatchService(JdbcTemplate jdbc, ObjectMapper om, PhotoSubmittedProducer producer, GameService game,
                        PlaceRepository places, @Value("${app.photos-dir:./photos}") String photosDir) {
        this.jdbc = jdbc;
        this.om = om;
        this.producer = producer;
        this.game = game;
        this.places = places;
        this.photosDir = Paths.get(photosDir).toAbsolutePath();
    }

    public static final String REASON_STALE = "Analiza nie powiodła się — spróbuj ponownie";
    static final Duration STALE_AFTER = Duration.ofMinutes(2);
    static final int MAX_LIST_LIMIT = 100;

    public record SubmitResult(String catchId, String status, Instant createdAt, String thumbnailUrl) {}

    public record Photo(byte[] bytes, String contentType) {}

    static String thumbnailUrl(Object catchId) { return "/catches/" + catchId + "/photo"; }

    public SubmitResult submit(UUID userId, MultipartFile photo, double lat, double lng, UUID spawnId,
                               String placeId, Instant takenAt) throws IOException {
        if (photo == null || photo.isEmpty()) throw ApiException.badRequest("photo is required");
        if (photo.getSize() > MAX_PHOTO_BYTES) {
            throw new ApiException(HttpStatus.PAYLOAD_TOO_LARGE, "PAYLOAD_TOO_LARGE", "Photo must be at most 5 MB");
        }
        String ext = imageExtension(photo.getBytes());
        if (ext == null) throw ApiException.badRequest("photo must be a JPEG or PNG image");
        if (takenAt == null) throw ApiException.badRequest("takenAt is required");
        if (lat < -90 || lat > 90 || lng < -180 || lng > 180) throw ApiException.badRequest("invalid lat/lng");
        Instant now = Instant.now();
        if (takenAt.isBefore(now.minus(MAX_PHOTO_AGE)) || takenAt.isAfter(now.plus(Duration.ofMinutes(2)))) {
            throw ApiException.badRequest("takenAt must be within the last 10 minutes");
        }
        if (placeId != null && !placeId.isBlank() && !places.exists(placeId)) {
            throw ApiException.notFound("Place " + placeId + " not found");
        }
        if (placeId != null && placeId.isBlank()) placeId = null;
        if (spawnId != null) {
            List<Map<String, Object>> rows = jdbc.queryForList("""
                    SELECT expires_at > now() AS alive,
                           ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?) AS near
                    FROM creature_spawn WHERE id = ?""", lng, lat, MAX_SPAWN_DISTANCE_M, spawnId);
            if (rows.isEmpty()) throw ApiException.notFound("Spawn " + spawnId + " not found");
            if (!Boolean.TRUE.equals(rows.get(0).get("alive"))) throw new ApiException(HttpStatus.GONE, "SPAWN_EXPIRED", "Spawn has expired");
            if (!Boolean.TRUE.equals(rows.get(0).get("near"))) throw ApiException.badRequest("Too far from the spawn (max 50 m)");
        }
        Integer today = jdbc.queryForObject("SELECT count(*) FROM catch_record WHERE user_id = ? AND created_at > now() - interval '1 day'",
                Integer.class, userId);
        if (today != null && today >= DAILY_LIMIT) {
            throw new ApiException(HttpStatus.TOO_MANY_REQUESTS, "RATE_LIMIT", "Daily photo limit (30) reached");
        }

        UUID id = UUID.randomUUID();
        LocalDate d = LocalDate.now(ZoneOffset.UTC);
        Path dir = photosDir.resolve(String.format("%04d/%02d/%02d", d.getYear(), d.getMonthValue(), d.getDayOfMonth()));
        Files.createDirectories(dir);
        Path file = dir.resolve(id + ext);
        photo.transferTo(file);
        String photoPath = file.toString().replace('\\', '/');

        jdbc.update("""
                INSERT INTO catch_record (id, user_id, spawn_id, place_id, geom, photo_path, status, created_at)
                VALUES (?, ?, ?, ?, ST_SetSRID(ST_MakePoint(?, ?), 4326), ?, 'PENDING', ?)
                """, id, userId, spawnId, placeId, lng, lat, photoPath, java.sql.Timestamp.from(now));

        var event = new Events.PhotoSubmitted(id.toString(), photoPath, lat, lng,
                spawnId == null ? null : spawnId.toString(), placeId, now);
        producer.send(event).whenComplete((r, ex) -> {
            if (ex != null) {
                log.warn("Kafka publish failed for catch {}: {}", id, ex.getMessage());
                jdbc.update("UPDATE catch_record SET status = 'FAILED', reason = 'Serwer chwilowo niedostępny — spróbuj ponownie', analyzed_at = now() "
                        + "WHERE id = ? AND status = 'PENDING'", id);
            }
        });
        return new SubmitResult(id.toString(), "PENDING", now, thumbnailUrl(id));
    }

    /** BACKEND.md 6.3 - idempotent: anything not PENDING is ignored. */
    @Transactional
    public void applyAnalysis(Events.PhotoAnalyzed ev) {
        UUID catchId;
        try {
            catchId = UUID.fromString(ev.catchId());
        } catch (Exception e) {
            log.warn("photo.analyzed with invalid catchId {}", ev.catchId());
            return;
        }
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT c.user_id, c.place_id, c.status, ST_X(c.geom) AS lng, ST_Y(c.geom) AS lat, s.rarity
                FROM catch_record c LEFT JOIN creature_spawn s ON s.id = c.spawn_id
                WHERE c.id = ? FOR UPDATE OF c""", catchId);
        if (rows.isEmpty()) {
            log.warn("photo.analyzed for unknown catch {}", catchId);
            return;
        }
        Map<String, Object> c = rows.get(0);
        if (!"PENDING".equals(c.get("status"))) return;

        String status = ev.status() == null ? "FAILED" : ev.status().toUpperCase(Locale.ROOT);
        if (!"OK".equals(status)) {
            if (!"REJECTED".equals(status)) status = "FAILED";
            jdbc.update("UPDATE catch_record SET status = ?, reason = ?, ai_result = ?::jsonb, phash = ?, analyzed_at = now() WHERE id = ?",
                    status, ev.reason(), json(ev.result()), ev.phash(), catchId);
            return;
        }

        JsonNode result = ev.result() == null ? JsonNodeFactory.instance.objectNode() : ev.result();
        double lng = ((Number) c.get("lng")).doubleValue();
        double lat = ((Number) c.get("lat")).doubleValue();
        if (isDuplicate(catchId, ev.phash(), lng, lat)) {
            jdbc.update("UPDATE catch_record SET status = 'REJECTED', reason = ?, ai_result = ?::jsonb, phash = ?, analyzed_at = now() WHERE id = ?",
                    REASON_DUPLICATE, json(result), ev.phash(), catchId);
            return;
        }

        Double confidence = result.hasNonNull("confidence") ? result.get("confidence").asDouble() : null;
        String placeId = (String) c.get("place_id");
        List<String> created = new ArrayList<>();
        if (placeId != null) {
            Instant now = Instant.now();
            String ref = "catch:" + catchId;
            addAiFact(created, placeId, "steps", result.get("steps"), ref, now);
            addAiFact(created, placeId, "kerbHeight", result.get("kerbRange"), ref, now);
            addAiFact(created, placeId, "ramp", result.get("ramp"), ref, now);
        }

        // Same rules as POST /game/reports: severity -> rarity -> species. Catching never awards points.
        UUID userId = (UUID) c.get("user_id");
        GameRules.Species species = game.rollSpecies(reportFromAi(placeId, result));
        game.addCreature(userId, species.id());

        jdbc.update("""
                UPDATE catch_record SET status = 'OK', ai_result = ?::jsonb, ai_confidence = ?, phash = ?, points = 0,
                  species_id = ?, created_facts = ?::jsonb, reason = NULL, analyzed_at = now() WHERE id = ?""",
                json(result), confidence, ev.phash(), species.id(), json(om.valueToTree(created)), catchId);
        jdbc.update("""
                UPDATE grid_cell SET explored_count = explored_count + 1
                WHERE ST_Contains(geom, ST_SetSRID(ST_MakePoint(?, ?), 4326))""", lng, lat);
    }

    /** AI result -> BarrierReport, so photo catches use exactly the survey severity rules. */
    static GameRules.BarrierReport reportFromAi(String placeId, JsonNode r) {
        Integer steps = r.hasNonNull("steps") && r.get("steps").canConvertToInt() ? Math.max(0, r.get("steps").asInt()) : null;
        GameRules.CurbRange curb = switch (r.path("kerbRange").asText("")) {
            case "0-3" -> GameRules.CurbRange.low;
            case "3-7" -> GameRules.CurbRange.mid;
            case ">7" -> GameRules.CurbRange.high;
            default -> GameRules.CurbRange.none;
        };
        GameRules.PassageWidth passage = switch (r.path("widthRange").asText("")) {
            case "<70" -> GameRules.PassageWidth.narrow;
            case "70-90" -> GameRules.PassageWidth.medium;
            case ">90" -> GameRules.PassageWidth.wide;
            default -> GameRules.PassageWidth.none;
        };
        boolean noRamp = r.has("ramp") && r.get("ramp").isBoolean() && !r.get("ramp").asBoolean();
        JsonNode obs = r.path("obstacles");
        boolean obstacles = obs.isArray() && obs.size() > 0;
        boolean uneven = r.path("difficulty").asDouble(0) >= 6;
        return new GameRules.BarrierReport(placeId, steps, curb, passage, noRamp, uneven, obstacles);
    }

    static String imageExtension(byte[] b) {
        if (b.length >= 3 && (b[0] & 0xFF) == 0xFF && (b[1] & 0xFF) == 0xD8 && (b[2] & 0xFF) == 0xFF) return ".jpg";
        if (b.length >= 8 && (b[0] & 0xFF) == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return ".png";
        return null;
    }

    /** Same barrier photographed again: pHash Hamming distance <= 6 within 30 m. */
    private boolean isDuplicate(UUID catchId, String phash, double lng, double lat) {
        if (phash == null || phash.isBlank()) return false;
        List<String> others = jdbc.queryForList("""
                SELECT phash FROM catch_record WHERE id <> ? AND phash IS NOT NULL AND status = 'OK'
                  AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, 30)""",
                String.class, catchId, lng, lat);
        return others.stream().anyMatch(o -> hamming(phash, o) <= 6);
    }

    static int hamming(String a, String b) {
        try {
            if (a.length() != b.length()) return Integer.MAX_VALUE;
            int d = 0;
            for (int i = 0; i < a.length(); i++) {
                d += Integer.bitCount(Character.digit(a.charAt(i), 16) ^ Character.digit(b.charAt(i), 16));
            }
            return d;
        } catch (Exception e) {
            return Integer.MAX_VALUE;
        }
    }

    private void addAiFact(List<String> created, String placeId, String feature, JsonNode value, String ref, Instant now) {
        if (value == null || value.isNull()) return;
        try {
            FactValidator.validate(feature, value);
        } catch (ApiException e) {
            log.info("Skipping AI fact {}={}: {}", feature, value, e.getMessage());
            return;
        }
        created.add(places.insertFact(placeId, feature, value, "ai", ref, now, null, 0, 0, null).toString());
    }

    private String json(JsonNode n) {
        return n == null || n.isNull() ? null : n.toString();
    }

    public Map<String, Object> get(UUID catchId, UUID userId) {
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT id, status, reason, species_id, ai_result::text AS ai_result, created_facts::text AS created_facts
                FROM catch_record WHERE id = ? AND user_id = ?""", catchId, userId);
        if (rows.isEmpty()) throw ApiException.notFound("Catch " + catchId + " not found");
        Map<String, Object> r = rows.get(0);
        Optional<GameRules.Species> species = game.species((String) r.get("species_id"));
        boolean ok = "OK".equals(r.get("status"));
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("catchId", r.get("id").toString());
        out.put("status", r.get("status"));
        out.put("reason", r.get("reason"));
        out.put("result", readTree((String) r.get("ai_result")));
        out.put("species", species.orElse(null));
        out.put("points", species.map(s -> s.rarity().sellValue()).orElse(null));
        out.put("awarded", 0);
        out.put("state", ok ? game.state(userId) : null);
        JsonNode facts = readTree((String) r.get("created_facts"));
        out.put("createdFacts", facts == null ? List.of() : facts);
        return out;
    }

    /** My catches, newest first. {@code since}: only analyzed after it, plus everything still PENDING. */
    public List<Map<String, Object>> list(UUID userId, Instant since, int limit) {
        int lim = Math.max(1, Math.min(limit, MAX_LIST_LIMIT));
        String sql = """
                SELECT id, status, reason, species_id, points, ai_result::text AS ai_result, created_at, analyzed_at, place_id
                FROM catch_record WHERE user_id = ?""";
        List<Object> args = new ArrayList<>(List.of(userId));
        if (since != null) {
            sql += " AND (analyzed_at > ? OR status = 'PENDING')";
            args.add(java.sql.Timestamp.from(since));
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ?";
        args.add(lim);
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map<String, Object> r : jdbc.queryForList(sql, args.toArray())) {
            Optional<GameRules.Species> species = game.species((String) r.get("species_id"));
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("catchId", r.get("id").toString());
            m.put("status", r.get("status"));
            m.put("reason", r.get("reason"));
            m.put("species", species.orElse(null));
            m.put("points", species.map(s -> s.rarity().sellValue()).orElse(null));
            m.put("result", readTree((String) r.get("ai_result")));
            m.put("createdAt", toInstant(r.get("created_at")));
            m.put("analyzedAt", toInstant(r.get("analyzed_at")));
            m.put("placeId", r.get("place_id"));
            m.put("thumbnailUrl", thumbnailUrl(r.get("id")));
            out.add(m);
        }
        return out;
    }

    /** Owner-only photo bytes; other users get 404. */
    public Photo photo(UUID catchId, UUID userId) {
        List<String> paths = jdbc.queryForList("SELECT photo_path FROM catch_record WHERE id = ? AND user_id = ?",
                String.class, catchId, userId);
        if (paths.isEmpty()) throw ApiException.notFound("Catch " + catchId + " not found");
        String path = paths.get(0);
        try {
            byte[] bytes = Files.readAllBytes(Paths.get(path));
            return new Photo(bytes, path.toLowerCase(Locale.ROOT).endsWith(".png") ? "image/png" : "image/jpeg");
        } catch (IOException e) {
            throw ApiException.notFound("Photo for catch " + catchId + " not found");
        }
    }

    /**
     * Vision down: PENDING longer than 2 min becomes FAILED. The WHERE status = 'PENDING' guard plus the row
     * lock taken by applyAnalysis (FOR UPDATE) make this race-free with the Kafka listener.
     */
    @org.springframework.scheduling.annotation.Scheduled(fixedDelay = 30_000, initialDelay = 30_000)
    public int failStalePending() {
        int n = jdbc.update("""
                UPDATE catch_record SET status = 'FAILED', reason = ?, analyzed_at = now()
                WHERE status = 'PENDING' AND created_at < ?""",
                REASON_STALE, java.sql.Timestamp.from(Instant.now().minus(STALE_AFTER)));
        if (n > 0) log.info("Marked {} stale PENDING catches as FAILED", n);
        return n;
    }

    private static Instant toInstant(Object o) {
        if (o == null) return null;
        if (o instanceof java.sql.Timestamp t) return t.toInstant();
        if (o instanceof java.time.OffsetDateTime t) return t.toInstant();
        if (o instanceof Instant i) return i;
        return Instant.parse(o.toString());
    }

    private JsonNode readTree(String s) {
        try {
            return s == null ? null : om.readTree(s);
        } catch (Exception e) {
            return null;
        }
    }
}
