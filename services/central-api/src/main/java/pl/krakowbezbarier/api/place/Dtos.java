package pl.krakowbezbarier.api.place;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/** JSON contracts; field names match mobile/lib/data/models/*.dart. */
public final class Dtos {
    private Dtos() {}

    public record FactDto(String id, String feature, JsonNode value, String source, String sourceRef,
                          Instant fetchedAt, Instant confirmedAt, int confirmations, int disputes) {}

    public record PlaceDto(String id, String name, String category, double lat, double lng, String address,
                           @JsonProperty("isDemo") boolean isDemo, List<FactDto> facts) {}

    public record SourceInfo(Instant lastSuccessAt, boolean stale) {}

    public record PlacesResponse(List<PlaceDto> places, Map<String, SourceInfo> sources) {}

    public record NewFactRequest(String feature, JsonNode value) {}
}
