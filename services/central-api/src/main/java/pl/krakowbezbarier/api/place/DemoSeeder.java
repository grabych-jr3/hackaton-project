package pl.krakowbezbarier.api.place;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.io.InputStream;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;

/** Loads seed/places.json (copy of mobile/assets/demo/places.json) when the place table is empty. */
@Component
public class DemoSeeder {
    private static final Logger log = LoggerFactory.getLogger(DemoSeeder.class);
    private final PlaceRepository places;
    private final ObjectMapper om;
    private final boolean enabled;

    public DemoSeeder(PlaceRepository places, ObjectMapper om, @Value("${app.seed.enabled:true}") boolean enabled) {
        this.places = places;
        this.om = om;
        this.enabled = enabled;
    }

    @EventListener(ApplicationReadyEvent.class)
    @org.springframework.core.annotation.Order(0) // before ImportJob.onStartup
    @Transactional
    public void seed() throws Exception {
        if (!enabled || places.count() > 0) return;
        try (InputStream in = new ClassPathResource("seed/places.json").getInputStream()) {
            JsonNode root = om.readTree(in);
            int n = 0;
            for (JsonNode p : root.path("places")) {
                String id = p.get("id").asText();
                places.upsertPlace(id, "krakow", p.get("name").asText(), p.get("category").asText(),
                        p.get("lat").asDouble(), p.get("lng").asDouble(),
                        p.hasNonNull("address") ? p.get("address").asText() : null, null, true);
                for (JsonNode f : p.path("facts")) {
                    places.insertFact(id, f.get("feature").asText(), f.get("value"), f.get("source").asText(),
                            f.hasNonNull("sourceRef") ? f.get("sourceRef").asText() : null,
                            parseInstant(f.get("fetchedAt").asText()),
                            f.hasNonNull("confirmedAt") ? parseInstant(f.get("confirmedAt").asText()) : null,
                            f.path("confirmations").asInt(0), f.path("disputes").asInt(0), null);
                }
                n++;
            }
            log.info("Seeded {} demo places", n);
        }
    }

    /** Accepts "2026-09-20" or full ISO-8601 instants. */
    public static Instant parseInstant(String s) {
        if (s.length() == 10) return LocalDate.parse(s).atStartOfDay(ZoneOffset.UTC).toInstant();
        return Instant.parse(s);
    }
}
