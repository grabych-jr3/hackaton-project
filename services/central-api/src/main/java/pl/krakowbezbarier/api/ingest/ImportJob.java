package pl.krakowbezbarier.api.ingest;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;
import pl.krakowbezbarier.api.common.GeoUtils.BBox;
import pl.krakowbezbarier.api.health.SourceStatusRepository;
import pl.krakowbezbarier.api.place.PlaceRepository;

import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/** One Overpass request per city bbox; retries 5/15/45 s, then marks the source stale. */
@Component
public class ImportJob {
    private static final Logger log = LoggerFactory.getLogger(ImportJob.class);
    private static final long[] RETRY_DELAYS_MS = {5_000, 15_000, 45_000};

    private final List<SourceAdapter> adapters;
    private final PlaceRepository places;
    private final SourceStatusRepository status;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate tx;
    private final ObjectMapper om;
    private final AtomicBoolean running = new AtomicBoolean(false);

    public ImportJob(List<SourceAdapter> adapters, PlaceRepository places, SourceStatusRepository status,
                     JdbcTemplate jdbc, TransactionTemplate tx, ObjectMapper om) {
        this.adapters = adapters;
        this.places = places;
        this.status = status;
        this.jdbc = jdbc;
        this.tx = tx;
        this.om = om;
    }

    @Scheduled(cron = "${app.overpass.cron}")
    public void scheduled() { runAll(); }

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

    private void importCity(SourceAdapter adapter, String cityId, BBox bbox) {
        Exception last = null;
        for (int attempt = 0; attempt <= RETRY_DELAYS_MS.length; attempt++) {
            try {
                List<SourceAdapter.ImportedPlace> result = adapter.fetch(bbox);
                tx.executeWithoutResult(s -> result.forEach(p -> save(cityId, p)));
                status.success(adapter.sourceId());
                log.info("Imported {} places from {} for {}", result.size(), adapter.sourceId(), cityId);
                return;
            } catch (Exception e) {
                last = e;
                log.warn("Import {} attempt {} failed: {}", adapter.sourceId(), attempt + 1, e.getMessage());
                status.error(adapter.sourceId(), e.getMessage(), false);
                if (attempt < RETRY_DELAYS_MS.length) {
                    try {
                        Thread.sleep(RETRY_DELAYS_MS[attempt]);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            }
        }
        status.error(adapter.sourceId(), last == null ? "interrupted" : last.getMessage(), true);
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
