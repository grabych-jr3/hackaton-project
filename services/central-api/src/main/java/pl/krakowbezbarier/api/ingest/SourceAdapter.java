package pl.krakowbezbarier.api.ingest;

import com.fasterxml.jackson.databind.JsonNode;
import pl.krakowbezbarier.api.common.GeoUtils.BBox;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/** A new data source = a new class implementing this interface. */
public interface SourceAdapter {
    String sourceId();

    List<ImportedPlace> fetch(BBox bbox) throws Exception;

    record ImportedFact(String feature, JsonNode value) {}

    record ImportedPlace(String id, String name, String category, double lat, double lng, String address,
                         Map<String, String> tags, Instant fetchedAt, List<ImportedFact> facts) {}
}
