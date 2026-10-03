package pl.krakowbezbarier.api.health;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import pl.krakowbezbarier.api.place.Dtos.SourceInfo;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Repository
public class SourceStatusRepository {
    private final JdbcTemplate jdbc;

    public SourceStatusRepository(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public record SourceStatus(String source, Instant lastSuccessAt, Instant lastErrorAt, String lastError, boolean stale) {}

    public List<SourceStatus> all() {
        return jdbc.query("SELECT * FROM source_status ORDER BY source", (rs, i) -> new SourceStatus(
                rs.getString("source"), ts(rs.getTimestamp("last_success_at")), ts(rs.getTimestamp("last_error_at")),
                rs.getString("last_error"), rs.getBoolean("stale")));
    }

    public Map<String, SourceInfo> summary() {
        Map<String, SourceInfo> m = new LinkedHashMap<>();
        all().forEach(s -> m.put(s.source(), new SourceInfo(s.lastSuccessAt(), s.stale())));
        return m;
    }

    public void success(String source) {
        jdbc.update("""
                INSERT INTO source_status (source, last_success_at, stale) VALUES (?, now(), false)
                ON CONFLICT (source) DO UPDATE SET last_success_at = now(), stale = false
                """, source);
    }

    public void error(String source, String message, boolean stale) {
        String msg = message == null ? null : message.substring(0, Math.min(500, message.length()));
        jdbc.update("""
                INSERT INTO source_status (source, last_error_at, last_error, stale) VALUES (?, now(), ?, ?)
                ON CONFLICT (source) DO UPDATE SET last_error_at = now(), last_error = EXCLUDED.last_error,
                  stale = EXCLUDED.stale
                """, source, msg, stale);
    }

    private static Instant ts(Timestamp t) { return t == null ? null : t.toInstant(); }
}
