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
    static final long MAX_PHOTO_BYTES = 3L * 1024 * 1024;
    static final int DAILY_LIMIT = 30;
    static final double MAX_SPAWN_DISTANCE_M = 50;
    static final Duration MAX_PHOTO_AGE = Duration.ofMinutes(10);
    static final Map<String, Integer> RARITY_POINTS = Map.of("common", 10, "rare", 25, "epic", 60, "legendary", 150);

    private final JdbcTemplate jdbc;
    private final ObjectMapper om;
    private final PhotoSubmittedProducer producer;
    private final PointsService points;
    private final PlaceRepository places;
    private final Path photosDir;

    public CatchService(JdbcTemplate jdbc, ObjectMapper om, PhotoSubmittedProducer producer, PointsService points,
                        PlaceRepository places, @Value("${app.photos-dir:./photos}") String photosDir) {
        this.jdbc = jdbc;
        this.om = om;
        this.producer = producer;
        this.points = points;
        this.places = places;
        this.photosDir = Paths.get(photosDir).toAbsolutePath();
    }

    public record SubmitResult(String catchId, String status) {}

    public SubmitResult submit(UUID userId, MultipartFile photo, double lat, double lng, UUID spawnId,
                               String placeId, Instant takenAt) throws IOException {
        if (photo == null || photo.isEmpty()) throw ApiException.badRequest("photo is required");
        if (photo.getSize() > MAX_PHOTO_BYTES) throw ApiException.badRequest("photo must be at most 3 MB");
        String ct = photo.getContentType();
        if (ct != null && !ct.startsWith("image/")) throw ApiException.badRequest("photo must be an image");
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
        Path file = dir.resolve(id + ".jpg");
        photo.transferTo(file);
        String photoPath = file.toString().replace('\\', '/');

        jdbc.update("""
                INSERT INTO catch_record (id, user_id, spawn_id, place_id, geom, photo_path, status)
                VALUES (?, ?, ?, ?, ST_SetSRID(ST_MakePoint(?, ?), 4326), ?, 'PENDING')
                """, id, userId, spawnId, placeId, lng, lat, photoPath);

        var event = new Events.PhotoSubmitted(id.toString(), photoPath, lat, lng,
                spawnId == null ? null : spawnId.toString(), placeId, now);
        producer.send(event).whenComplete((r, ex) -> {
            if (ex != null) {
                log.warn("Kafka publish failed for catch {}: {}", id, ex.getMessage());
                jdbc.update("UPDATE catch_record SET status = 'FAILED', reason = 'broker unavailable', analyzed_at = now() "
                        + "WHERE id = ? AND status = 'PENDING'", id);
            }
        });
        return new SubmitResult(id.toString(), "PENDING");
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

        String rarity = c.get("rarity") == null ? "common" : (String) c.get("rarity");
        int pts = pointsFor(rarity, confidence);
        UUID userId = (UUID) c.get("user_id");
        String reason = null;
        if (isDuplicate(catchId, ev.phash(), ((Number) c.get("lng")).doubleValue(), ((Number) c.get("lat")).doubleValue())) {
            pts = 0;
            reason = "duplicate";
        }
        if (pts > 0) points.award(userId, pts, "catch", catchId.toString());

        jdbc.update("""
                UPDATE catch_record SET status = 'OK', ai_result = ?::jsonb, ai_confidence = ?, phash = ?, points = ?,
                  created_facts = ?::jsonb, reason = ?, analyzed_at = now() WHERE id = ?""",
                json(result), confidence, ev.phash(), pts, json(om.valueToTree(created)), reason, catchId);
        jdbc.update("""
                UPDATE grid_cell SET explored_count = explored_count + 1
                WHERE ST_Contains(geom, ST_SetSRID(ST_MakePoint(?, ?), 4326))""",
                ((Number) c.get("lng")).doubleValue(), ((Number) c.get("lat")).doubleValue());
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

    static int pointsFor(String rarity, Double confidence) {
        int base = RARITY_POINTS.getOrDefault(rarity, 10);
        return confidence != null && confidence < 0.5 ? base / 2 : base;
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
                SELECT c.id, c.status, c.points, c.reason, c.ai_result::text AS ai_result,
                       c.created_facts::text AS created_facts, COALESCE(s.rarity, 'common') AS rarity
                FROM catch_record c LEFT JOIN creature_spawn s ON s.id = c.spawn_id
                WHERE c.id = ? AND c.user_id = ?""", catchId, userId);
        if (rows.isEmpty()) throw ApiException.notFound("Catch " + catchId + " not found");
        Map<String, Object> r = rows.get(0);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("catchId", r.get("id").toString());
        out.put("status", r.get("status"));
        out.put("points", r.get("points"));
        out.put("rarity", r.get("rarity"));
        out.put("result", readTree((String) r.get("ai_result")));
        JsonNode facts = readTree((String) r.get("created_facts"));
        out.put("createdFacts", facts == null ? List.of() : facts);
        out.put("reason", r.get("reason"));
        return out;
    }

    private JsonNode readTree(String s) {
        try {
            return s == null ? null : om.readTree(s);
        } catch (Exception e) {
            return null;
        }
    }
}
