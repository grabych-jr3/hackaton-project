package pl.krakowbezbarier.api.ingest;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.core.io.DefaultResourceLoader;
import org.springframework.core.io.Resource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;
import pl.krakowbezbarier.api.common.GeoUtils.BBox;
import pl.krakowbezbarier.api.health.SourceStatusRepository;
import pl.krakowbezbarier.api.place.PlaceRepository;

import java.io.InputStream;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * One Overpass request per city bbox (the adapter itself fails over across mirrors);
 * retries 5/15/45 s, then marks the source stale. If the city still has no OSM places at that point,
 * the bundled offline snapshot (seed/osm_krakow_center.json) is imported so real places appear even offline.
 */
@Component
public class ImportJob {
    private static final Logger log = LoggerFactory.getLogger(ImportJob.class);
    static final String SNAPSHOT_SOURCE = "osm";

    private final List<SourceAdapter> adapters;
    private final PlaceRepository places;
    private final SourceStatusRepository status;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate tx;
    private final ObjectMapper om;
    private final String snapshotLocation;
    private final boolean startupImport;
    private final AtomicBoolean running = new AtomicBoolean(false);
    long[] retryDelaysMs = {5_000, 15_000, 45_000};

    public ImportJob(List<SourceAdapter> adapters, PlaceRepository places, SourceStatusRepository status,
                     JdbcTemplate jdbc, TransactionTemplate tx, ObjectMapper om,
                     @Value("${app.overpass.snapshot:classpath:seed/osm_krakow_center.json}") String snapshotLocation,
                     @Value("${app.overpass.startup-import:true}") boolean startupImport) {
        this.adapters = adapters;
        this.places = places;
        this.status = status;
        this.jdbc = jdbc;
        this.tx = tx;
        this.om = om;
        this.snapshotLocation = snapshotLocation;
        this.startupImport = startupImport;
    }

    @Scheduled(cron = "${app.overpass.cron}")
    public void scheduled() { runAll(); }

    /** On startup: if there are no OSM places yet (only demo), import now (live, else snapshot). */
    @EventListener(ApplicationReadyEvent.class)
    @Order(Ordered.LOWEST_PRECEDENCE)
    public void onStartup() {
        if (!startupImport) return;
        try {
            Integer n = jdbc.queryForObject("SELECT count(*) FROM place WHERE id LIKE 'osm:%' AND NOT is_demo", Integer.class);
            if (n != null && n > 0) return;
        } catch (Exception e) {
            log.warn("Startup OSM check failed: {}", e.getMessage());
            return;
        }
        log.info("No OSM places in DB - starting initial import");
        Thread.ofVirtual().name("osm-initial-import").start(this::runAll);
    }

    /** @return false if an import is already running. */
    public boolean runAll() {
        if (!running.compareAndSet(false, true)) return false;
        try {
            var cities = jdbc.query("SELECT id, ST_XMin(bbox) a, ST_YMin(bbox) b, ST_XMax(bbox) c, ST_YMax(bbox) d FROM city WHERE bbox IS NOT NULL",
                    (rs, i) -> new Object[]{rs.getString("id"), new BBox(rs.getDouble("a"), rs.getDouble("b"), rs.getDouble("c"), rs.getDouble("d"))});
            for (SourceAdapter a : adapters) {
                for (Object[] city : cities) importCity(a, (String) city[0], (BBox) city[1]);
            }
            return true;
        } finally {
            running.set(false);
        }
    }

    /** @return true if live data was imported. */
    boolean importCity(SourceAdapter adapter, String cityId, BBox bbox) {
        Exception last = null;
        for (int attempt = 0; attempt <= retryDelaysMs.length; attempt++) {
            try {
                List<SourceAdapter.ImportedPlace> result = adapter.fetch(bbox);
                tx.executeWithoutResult(s -> result.forEach(p -> save(cityId, p)));
                String origin = adapter.lastOrigin();
                status.success(adapter.sourceId(), origin);
                log.info("Imported {} places from {} for {} via {}", result.size(), adapter.sourceId(), cityId, origin);
                return true;
            } catch (Exception e) {
                last = e;
                log.warn("Import {} attempt {} failed: {}", adapter.sourceId(), attempt + 1, e.getMessage());
                status.error(adapter.sourceId(), e.getMessage(), false);
                if (attempt < retryDelaysMs.length) {
                    try {
                        Thread.sleep(retryDelaysMs[attempt]);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            }
        }
        String err = last == null ? "interrupted" : last.getMessage();
        status.error(adapter.sourceId(), err, true);
        if (SNAPSHOT_SOURCE.equals(adapter.sourceId()) && !hasOsmPlaces(cityId)) importSnapshot(cityId, err);
        return false;
    }

    private boolean hasOsmPlaces(String cityId) {
        Integer n = jdbc.queryForObject("SELECT count(*) FROM place WHERE city_id = ? AND id LIKE 'osm:%' AND NOT is_demo",
                Integer.class, cityId);
        return n != null && n > 0;
    }

    /** Imports the bundled Overpass snapshot; fetched_at = snapshot's osm3s.timestamp_osm_base. Source stays stale. */
    int importSnapshot(String cityId, String liveError) {
        Resource res = new DefaultResourceLoader().getResource(snapshotLocation);
        if (!res.exists()) {
            log.warn("OSM snapshot {} not found", snapshotLocation);
            return 0;
        }
        try (InputStream in = res.getInputStream()) {
            JsonNode root = om.readTree(in);
            Instant ts = Instant.parse(root.path("osm3s").path("timestamp_osm_base").asText());
            List<SourceAdapter.ImportedPlace> result = OverpassAdapter.parse(root, ts);
            tx.executeWithoutResult(s -> result.forEach(p -> save(cityId, p)));
            String origin = "snapshot:" + res.getFilename() + "@" + ts;
            status.snapshotLoaded(SNAPSHOT_SOURCE, origin, "live import failed, using " + origin + ": " + liveError);
            log.info("Imported {} places for {} from offline OSM snapshot ({})", result.size(), cityId, ts);
            return result.size();
        } catch (Exception e) {
            log.warn("OSM snapshot import failed: {}", e.getMessage());
            return 0;
        }
    }

    private void save(String cityId, SourceAdapter.ImportedPlace p) {
        String tags;
        try {
            tags = om.writeValueAsString(p.tags());
        } catch (Exception e) {
            tags = null;
        }
        places.upsertPlace(p.id(), cityId, p.name(), p.category(), p.lat(), p.lng(), p.address(), tags, false);
        for (var f : p.facts()) places.upsertOsmFact(p.id(), f.feature(), f.value(), p.id(), p.fetchedAt());
    }
}
