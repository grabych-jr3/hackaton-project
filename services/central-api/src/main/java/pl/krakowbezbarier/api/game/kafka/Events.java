package pl.krakowbezbarier.api.game.kafka;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;

/** Kafka message contracts (BACKEND.md section 6). */
public final class Events {
    private Events() {}

    public record PhotoSubmitted(String catchId, String photoPath, double lat, double lng, String spawnId,
                                 String placeId, Instant submittedAt) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record PhotoAnalyzed(String catchId, String status, JsonNode result, String phash, String reason) {}
}
