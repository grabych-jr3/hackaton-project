package pl.krakowbezbarier.api.place;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.game.PointsService;
import pl.krakowbezbarier.api.place.Dtos.FactDto;
import pl.krakowbezbarier.api.place.Dtos.NewFactRequest;

import java.time.Instant;
import java.util.UUID;

@Service
public class FactService {
    static final int CONFIRM_POINTS = 15;
    static final int HIDE_AFTER_DISPUTES = 3;

    private final PlaceRepository places;
    private final JdbcTemplate jdbc;
    private final PointsService points;

    public FactService(PlaceRepository places, JdbcTemplate jdbc, PointsService points) {
        this.places = places;
        this.jdbc = jdbc;
        this.points = points;
    }

    @Transactional
    public FactDto addUserFact(String placeId, NewFactRequest req, UUID userId) {
        if (!places.exists(placeId)) throw ApiException.notFound("Place " + placeId + " not found");
        FactValidator.validate(req.feature(), req.value());
        UUID id = places.insertFact(placeId, req.feature(), req.value(), "user", null, Instant.now(), null, 0, 0, userId);
        return places.findFact(id).orElseThrow();
    }

    @Transactional
    public FactDto vote(UUID factId, UUID userId, boolean confirm) {
        if (places.findFact(factId).isEmpty()) throw ApiException.notFound("Fact " + factId + " not found");
        int inserted = jdbc.update("""
                INSERT INTO fact_vote (fact_id, user_id, vote) VALUES (?, ?, ?)
                ON CONFLICT (fact_id, user_id) DO NOTHING
                """, factId, userId, confirm ? "confirm" : "dispute");
        if (inserted == 0) throw ApiException.conflict("You have already voted on fact " + factId);
        if (confirm) {
            jdbc.update("UPDATE accessibility_fact SET confirmations = confirmations + 1, confirmed_at = now() WHERE id = ?", factId);
            points.award(userId, CONFIRM_POINTS, "confirm", factId + ":" + userId);
        } else {
            jdbc.update("UPDATE accessibility_fact SET disputes = disputes + 1, active = (disputes + 1 < ?) WHERE id = ?",
                    HIDE_AFTER_DISPUTES, factId);
        }
        return places.findFact(factId).orElseThrow();
    }
}
