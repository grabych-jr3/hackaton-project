package pl.krakowbezbarier.api.crowd;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.common.GeoUtils.BBox;
import pl.krakowbezbarier.api.crowd.CrowdModel.*;
import pl.krakowbezbarier.api.game.PointsService;

import java.sql.Timestamp;
import java.time.*;
import java.util.*;

/** Keeps the latest crowd estimate per grid cell in memory (recomputed every 5 min) and stores snapshots. */
@Service
public class CrowdService {
    private static final Logger log = LoggerFactory.getLogger(CrowdService.class);
    static final int REPORT_POINTS = 5;
    static final Duration REPORT_COOLDOWN = Duration.ofMinutes(30);
    static final Duration SURVEY_WINDOW = Duration.ofHours(3);
    static final Duration LIVE_WINDOW = Duration.ofMinutes(15);
    static final double NEAR_GRID_M = 3000;

    private final JdbcTemplate jdbc;
    private final ObjectMapper om;
    private final PointsService points;
    private final boolean demo;
    private final int cellM;

    /** One city's grid and its static inputs (places, transit), reloaded on every recompute. */
    record City(CrowdGrid grid, ZoneId zone, Map<String, List<Place>> places, Map<String, double[]> transit, double peak) {}

    public record CellCrowd(String id, int x, int y, double crowd, String label, String source, int reports, Instant updatedAt) {}

    private volatile List<City> cities = List.of();
    private volatile Map<String, CellCrowd> latest = Map.of();

    public CrowdService(JdbcTemplate jdbc, ObjectMapper om, PointsService points) { this(jdbc, om, points, false, 100); }

    @org.springframework.beans.factory.annotation.Autowired
    public CrowdService(JdbcTemplate jdbc, ObjectMapper om, PointsService points,
                        @org.springframework.beans.factory.annotation.Value("${app.crowd.demo:false}") boolean demo,
                        @org.springframework.beans.factory.annotation.Value("${app.crowd.cell-m:100}") int cellM) {
        this.demo = demo;
        this.cellM = cellM;
        this.jdbc = jdbc;
        this.om = om;
        this.points = points;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void init() {
        try {
            ensureGrid();
            recompute();
        } catch (Exception e) {
            log.warn("Crowd init failed: {}", e.getMessage());
        }
    }

    /** Inserts missing grid cells for every city (ids are stable, so this is idempotent). */
    @Transactional
    public void ensureGrid() {
        for (CrowdGrid g : loadGrids()) {
            List<Object[]> rows = new ArrayList<>();
            for (int[] c : g.allCells()) {
                StringJoiner wkt = new StringJoiner(",", "POLYGON((", "))");
                for (double[] p : g.polygon(c[0], c[1])) wkt.add(p[1] + " " + p[0]);
                rows.add(new Object[]{g.id(c[0], c[1]), g.cityId(), wkt.toString()});
            }
            jdbc.batchUpdate("""
                    INSERT INTO crowd_cell (id, city_id, geom) VALUES (?, ?, ST_GeomFromText(?, 4326))
                    ON CONFLICT (id) DO NOTHING""", rows);
            log.info("Crowd grid {}: {} hex cells of {} m", g.cityId(), g.allCells().size(), (int) g.sizeM());
        }
    }

    /** For callers that may run before {@link #init()} (e.g. the GTFS import thread). */
    public void ensureLoaded() {
        if (!cities.isEmpty()) return;
        ensureGrid();
        recompute();
    }

    /**
     * Cells with crowd >= threshold, most crowded first, skipping cells that contain any of the given points
     * (the user must be able to start/stop there). Each as a [lat, lng] ring.
     */
    public List<List<double[]>> crowdedPolygons(double threshold, List<double[]> keepPoints, int limit) {
        Set<String> keep = new HashSet<>();
        for (double[] p : keepPoints) {
            String id = cellAt(p[0], p[1]);
            if (id != null) keep.add(id);
        }
        return latest.values().stream()
                .filter(c -> c.crowd() >= threshold && !keep.contains(c.id()))
                .sorted(Comparator.comparingDouble(CellCrowd::crowd).reversed())
                .limit(limit)
                .map(c -> polygon(c.id()))
                .filter(Objects::nonNull)
                .toList();
    }

    List<CrowdGrid> loadGrids() {
        return jdbc.query("""
                SELECT id, ST_XMin(bbox) a, ST_YMin(bbox) b, ST_XMax(bbox) c, ST_YMax(bbox) d
                FROM city WHERE bbox IS NOT NULL""", (rs, i) -> CrowdGrid.of(rs.getString("id"),
                new BBox(rs.getDouble("a"), rs.getDouble("b"), rs.getDouble("c"), rs.getDouble("d")), cellM));
    }

    @Scheduled(fixedRateString = "${app.crowd.recompute-ms:300000}", initialDelayString = "${app.crowd.recompute-ms:300000}")
    public void scheduled() {
        try {
            recompute();
        } catch (Exception e) {
            log.warn("Crowd recompute failed: {}", e.getMessage());
        }
    }

    /** Reloads inputs, recomputes every cell, keeps the result in memory and appends a snapshot. */
    public synchronized void recompute() {
        Instant now = Instant.now();
        List<City> loaded = loadCities();
        Map<String, List<Report>> reports = loadReports(now);
        Map<String, Integer> live = loadLive(loaded, now);
        Map<String, CellCrowd> out = new HashMap<>();
        List<Object[]> snap = new ArrayList<>();
        for (City c : loaded) {
            LocalDateTime local = LocalDateTime.ofInstant(now, c.zone());
            for (int[] xy : c.grid().allCells()) {
                String id = c.grid().id(xy[0], xy[1]);
                double base = base(c, xy[0], xy[1], local);
                List<Report> rs = reports.getOrDefault(id, List.of());
                Survey survey = rs.isEmpty() ? null : CrowdModel.survey(rs, now);
                Estimate e = CrowdModel.combine(base, survey, CrowdModel.live(live.getOrDefault(id, 0)));
                out.put(id, new CellCrowd(id, xy[0], xy[1], e.crowd(), e.label(), e.source(), rs.size(), now));
                snap.add(new Object[]{id, Timestamp.from(now), e.crowd(), json(e.mix())});
            }
        }
        cities = loaded;
        latest = out;
        jdbc.batchUpdate("INSERT INTO crowd_snapshot (cell_id, ts, crowd, source_mix) VALUES (?, ?, ?, ?::jsonb)", snap);
        jdbc.update("DELETE FROM crowd_snapshot WHERE ts < now() - interval '1 day'");
    }

    /** Open-data base of a cell; in demo mode at least the prototype Old Town hotspot shape. */
    private double base(City c, int x, int y, LocalDateTime local) {
        String id = c.grid().id(x, y);
        double real = CrowdModel.normalise(
                CrowdModel.rawBase(c.places().getOrDefault(id, List.of()), c.transit().get(id), local), c.peak());
        if (!demo) return real;
        double[] ctr = c.grid().center(x, y);
        return Math.max(real, CrowdModel.demoBase(id, ctr[0], ctr[1], local));
    }

    List<City> loadCities() {
        Map<String, ZoneId> zones = new HashMap<>();
        jdbc.query("SELECT id, timezone FROM city", rs -> { zones.put(rs.getString(1), ZoneId.of(rs.getString(2))); });
        List<CrowdGrid> grids = loadGrids();
        Map<String, double[]> transit = new HashMap<>();
        jdbc.query("SELECT id, transit_profile::text t FROM crowd_cell WHERE transit_profile IS NOT NULL", rs -> {
            double[] p = parseProfile(rs.getString("t"));
            if (p != null) transit.put(rs.getString("id"), p);
        });
        Map<String, Map<String, List<Place>>> placesByCity = new HashMap<>();
        Map<String, CrowdGrid> gridByCity = new HashMap<>();
        grids.forEach(g -> gridByCity.put(g.cityId(), g));
        jdbc.query("""
                SELECT city_id, category, ST_Y(geom) lat, ST_X(geom) lng, osm_tags->>'opening_hours' oh
                FROM place WHERE city_id IS NOT NULL""", rs -> {
            CrowdGrid g = gridByCity.get(rs.getString("city_id"));
            if (g == null) return;
            String cell = g.cellAt(rs.getDouble("lat"), rs.getDouble("lng"));
            if (cell == null) return;
            placesByCity.computeIfAbsent(g.cityId(), k -> new HashMap<>())
                    .computeIfAbsent(cell, k -> new ArrayList<>()).add(new Place(rs.getString("category"), rs.getString("oh")));
        });
        List<City> out = new ArrayList<>();
        for (CrowdGrid g : grids) {
            Map<String, List<Place>> places = placesByCity.getOrDefault(g.cityId(), Map.of());
            double peak = 0;
            for (int[] xy : g.allCells()) {
                String id = g.id(xy[0], xy[1]);
                peak = Math.max(peak, CrowdModel.peakPotential(places.getOrDefault(id, List.of()), transit.get(id)));
            }
            out.add(new City(g, zones.getOrDefault(g.cityId(), ZoneId.of("Europe/Warsaw")), places, transit, peak));
        }
        return out;
    }

    private Map<String, List<Report>> loadReports(Instant now) {
        Map<String, List<Report>> m = new HashMap<>();
        jdbc.query("SELECT cell_id, level, created_at FROM crowd_report WHERE created_at > ?",
                rs -> {
                    m.computeIfAbsent(rs.getString("cell_id"), k -> new ArrayList<>())
                            .add(new Report(rs.getInt("level"), rs.getTimestamp("created_at").toInstant()));
                }, Timestamp.from(now.minus(SURVEY_WINDOW)));
        return m;
    }

    /** Distinct users with a crowd report or a photo catch in the cell within the last 15 min. */
    private Map<String, Integer> loadLive(List<City> cs, Instant now) {
        Map<String, Set<UUID>> users = new HashMap<>();
        Timestamp since = Timestamp.from(now.minus(LIVE_WINDOW));
        jdbc.query("SELECT cell_id, user_id FROM crowd_report WHERE created_at > ?", rs -> {
            users.computeIfAbsent(rs.getString(1), k -> new HashSet<>()).add(rs.getObject(2, UUID.class));
        }, since);
        jdbc.query("SELECT user_id, ST_Y(geom) lat, ST_X(geom) lng FROM catch_record WHERE created_at > ?", rs -> {
            for (City c : cs) {
                String cell = c.grid().cellAt(rs.getDouble("lat"), rs.getDouble("lng"));
                if (cell != null) users.computeIfAbsent(cell, k -> new HashSet<>()).add(rs.getObject("user_id", UUID.class));
            }
        }, since);
        Map<String, Integer> out = new HashMap<>();
        users.forEach((k, v) -> out.put(k, v.size()));
        return out;
    }

    /** Current estimates of cells intersecting the bbox (null bbox = all). */
    public List<CellCrowd> current(BBox bbox) {
        List<CellCrowd> out = new ArrayList<>();
        for (City c : cities) {
            for (CellCrowd cell : latest.values()) {
                if (!cell.id().startsWith(c.grid().cityId() + ":")) continue;
                if (bbox == null || intersects(c.grid(), cell.x(), cell.y(), bbox)) out.add(cell);
            }
        }
        out.sort(Comparator.comparing(CellCrowd::id));
        return out;
    }

    /** Base-only forecast for a future moment (surveys and live activity are not predictable). */
    public List<CellCrowd> forecast(BBox bbox, Instant at) {
        List<CellCrowd> out = new ArrayList<>();
        for (City c : cities) {
            LocalDateTime local = LocalDateTime.ofInstant(at, c.zone());
            for (int[] xy : c.grid().allCells()) {
                if (bbox != null && !intersects(c.grid(), xy[0], xy[1], bbox)) continue;
                String id = c.grid().id(xy[0], xy[1]);
                double base = base(c, xy[0], xy[1], local);
                Estimate e = CrowdModel.combine(base, null, null);
                out.add(new CellCrowd(id, xy[0], xy[1], e.crowd(), e.label(), "forecast", 0, at));
            }
        }
        out.sort(Comparator.comparing(CellCrowd::id));
        return out;
    }

    /** Crowd 0..1 at a point now, or null outside every grid / before the first computation. */
    public Double crowdAt(double lat, double lng) {
        String id = cellAt(lat, lng);
        CellCrowd c = id == null ? null : latest.get(id);
        return c == null ? null : c.crowd();
    }

    /** Edge cell for a point just outside the grid (the grid covers only the centre), within maxM metres. */
    String nearestCell(double lat, double lng, double maxM) {
        for (City c : cities) {
            BBox b = c.grid().bbox();
            double cLat = Math.max(b.minLat(), Math.min(b.maxLat() - 1e-9, lat));
            double cLng = Math.max(b.minLng(), Math.min(b.maxLng() - 1e-9, lng));
            if (pl.krakowbezbarier.api.common.GeoUtils.haversineM(lat, lng, cLat, cLng) <= maxM) {
                String id = c.grid().cellAt(cLat, cLng);
                if (id != null) return id;
            }
        }
        return null;
    }

    public String cellAt(double lat, double lng) {
        for (City c : cities) {
            String id = c.grid().cellAt(lat, lng);
            if (id != null) return id;
        }
        return null;
    }

    /** Polygon ([lat, lng] ring) of a cell id. */
    public List<double[]> polygon(String cellId) {
        int[] xy = CrowdGrid.xy(cellId);
        for (City c : cities) if (cellId.startsWith(c.grid().cityId() + ":")) return c.grid().polygon(xy[0], xy[1]);
        return null;
    }

    public record ReportResult(String cellId, CellCrowd cell, int awarded) {}

    /** "Jak tłoczno?" answer: 1 per user and cell per 30 min, +5 points. */
    @Transactional
    public ReportResult report(UUID userId, double lat, double lng, int level) {
        if (level < 0 || level > 2) throw ApiException.badRequest("level must be 0, 1 or 2");
        String cell = cellAt(lat, lng);
        if (cell == null) cell = nearestCell(lat, lng, NEAR_GRID_M);
        if (cell == null) throw ApiException.badRequest("Punkt poza obszarem miasta");
        Integer recent = jdbc.queryForObject("""
                SELECT count(*) FROM crowd_report WHERE user_id = ? AND cell_id = ? AND created_at > ?""",
                Integer.class, userId, cell, Timestamp.from(Instant.now().minus(REPORT_COOLDOWN)));
        if (recent != null && recent > 0) {
            throw new ApiException(HttpStatus.TOO_MANY_REQUESTS, "RATE_LIMIT", "Już oceniłeś to miejsce w ciągu ostatnich 30 minut");
        }
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO crowd_report (id, cell_id, user_id, level) VALUES (?, ?, ?, ?)", id, cell, userId, level);
        boolean awarded = points.award(userId, REPORT_POINTS, "crowd_report", id.toString());
        recompute(); // same transaction, so the new answer is already visible; the map updates right away
        return new ReportResult(cell, latest.get(cell), awarded ? REPORT_POINTS : 0);
    }

    private static boolean intersects(CrowdGrid g, int q, int r, BBox b) {
        return g.intersects(q, r, b);
    }

    private double[] parseProfile(String json) {
        try {
            JsonNode n = om.readTree(json);
            if (!n.isArray() || n.size() != 24) return null;
            double[] p = new double[24];
            for (int i = 0; i < 24; i++) p[i] = n.get(i).asDouble();
            return p;
        } catch (Exception e) {
            return null;
        }
    }

    private String json(Object o) {
        try {
            return om.writeValueAsString(o);
        } catch (Exception e) {
            return "{}";
        }
    }
}
