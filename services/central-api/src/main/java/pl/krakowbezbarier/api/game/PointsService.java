package pl.krakowbezbarier.api.game;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/** points_ledger is the source of truth; (reason, ref_id) makes awards idempotent. */
@Service
public class PointsService {
    private final JdbcTemplate jdbc;

    public PointsService(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    /** @return true when the award was applied, false when it was already recorded. */
    @Transactional
    public boolean award(UUID userId, int delta, String reason, String refId) {
        int inserted = jdbc.update("""
                INSERT INTO points_ledger (id, user_id, delta, reason, ref_id) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (reason, ref_id) DO NOTHING
                """, UUID.randomUUID(), userId, delta, reason, refId);
        if (inserted == 0) return false;
        jdbc.update("UPDATE app_user SET points = points + ? WHERE id = ?", delta, userId);
        return true;
    }
}
