package pl.krakowbezbarier.api.place;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;
import pl.krakowbezbarier.api.common.GeoUtils.BBox;
import pl.krakowbezbarier.api.place.Dtos.FactDto;
import pl.krakowbezbarier.api.place.Dtos.PlaceDto;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.*;

/** Plain JDBC + PostGIS functions (no Hibernate Spatial needed). */
@Repository
public class PlaceRepository {
    public static final int MAX_PLACES = 2500;
    private final JdbcTemplate jdbc;
    private final ObjectMapper om;

    public PlaceRepository(JdbcTemplate jdbc, ObjectMapper om) {
        this.jdbc = jdbc;
        this.om = om;
    }

    private record PlaceRow(String id, String name, String category, double lat, double lng, String address, boolean demo) {}

    private static final RowMapper<PlaceRow> PLACE_ROW = (rs, i) -> new PlaceRow(
            rs.getString("id"), rs.getString("name"), rs.getString("category"),
            rs.getDouble("lat"), rs.getDouble("lng"), rs.getString("address"), rs.getBoolean("is_demo"));

    private static final String PLACE_SELECT =
            "SELECT id, name, category, ST_Y(geom) AS lat, ST_X(geom) AS lng, address, is_demo FROM place ";

    public List<PlaceDto> find(BBox bbox, String category) {
        StringBuilder sql = new StringBuilder(PLACE_SELECT).append("WHERE 1=1 ");
        List<Object> args = new ArrayList<>();
        if (bbox != null) {
            sql.append("AND geom && ST_MakeEnvelope(?, ?, ?, ?, 4326) ");
            args.addAll(List.of(bbox.minLng(), bbox.minLat(), bbox.maxLng(), bbox.maxLat()));
        }
        if (category != null && !category.isBlank()) {
            sql.append("AND category = ? ");
            args.add(category);
        }
        sql.append("ORDER BY name LIMIT ").append(MAX_PLACES);
        return withFacts(jdbc.query(sql.toString(), PLACE_ROW, args.toArray()));
    }

    public Optional<PlaceDto> findById(String id) {
        List<PlaceRow> rows = jdbc.query(PLACE_SELECT + "WHERE id = ?", PLACE_ROW, id);
        return withFacts(rows).stream().findFirst();
    }

    public boolean exists(String id) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM place WHERE id = ?)", Boolean.class, id));
    }

    public long count() {
        Long c = jdbc.queryForObject("SELECT count(*) FROM place", Long.class);
        return c == null ? 0 : c;
    }

    private List<PlaceDto> withFacts(List<PlaceRow> rows) {
        if (rows.isEmpty()) return List.of();
        String[] ids = rows.stream().map(PlaceRow::id).toArray(String[]::new);
        Map<String, List<FactDto>> facts = new HashMap<>();
        jdbc.query(con -> {
            var ps = con.prepareStatement(FACT_SELECT + "WHERE place_id = ANY(?) AND active ORDER BY fetched_at DESC");
            ps.setArray(1, con.createArrayOf("varchar", ids));
            return ps;
        }, rs -> {
            facts.computeIfAbsent(rs.getString("place_id"), k -> new ArrayList<>()).add(factMapper.mapRow(rs, 0));
        });
        return rows.stream().map(r -> new PlaceDto(r.id(), r.name(), r.category(), r.lat(), r.lng(), r.address(),
                r.demo(), facts.getOrDefault(r.id(), List.of()))).toList();
    }

    static final String FACT_SELECT = "SELECT id, place_id, feature, value::text AS value, source, source_ref, "
            + "fetched_at, confirmed_at, confirmations, disputes FROM accessibility_fact ";

    private final RowMapper<FactDto> factMapper = (rs, i) -> new FactDto(
            rs.getString("id"), rs.getString("feature"), parse(rs.getString("value")), rs.getString("source"),
            rs.getString("source_ref"), instant(rs.getTimestamp("fetched_at")), instant(rs.getTimestamp("confirmed_at")),
            rs.getInt("confirmations"), rs.getInt("disputes"));

    public Optional<FactDto> findFact(UUID id) {
        return jdbc.query(FACT_SELECT + "WHERE id = ?", factMapper, id).stream().findFirst();
    }

    private JsonNode parse(String json) {
        try {
            return om.readTree(json);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static Instant instant(Timestamp ts) {
        return ts == null ? null : ts.toInstant();
    }

    public void upsertPlace(String id, String cityId, String name, String category, double lat, double lng,
                            String address, String osmTagsJson, boolean demo) {
        jdbc.update("""
                INSERT INTO place (id, city_id, name, category, geom, address, osm_tags, is_demo, updated_at)
                VALUES (?, ?, ?, ?, ST_SetSRID(ST_MakePoint(?, ?), 4326), ?, ?::jsonb, ?, now())
                ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category,
                  geom = EXCLUDED.geom, address = COALESCE(EXCLUDED.address, place.address),
                  osm_tags = EXCLUDED.osm_tags, updated_at = now()
                """, id, cityId, name, category, lng, lat, address, osmTagsJson, demo);
    }

    public UUID insertFact(String placeId, String feature, JsonNode value, String source, String sourceRef,
                           Instant fetchedAt, Instant confirmedAt, int confirmations, int disputes, UUID createdBy) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO accessibility_fact (id, place_id, feature, value, source, source_ref, fetched_at,
                  confirmed_at, confirmations, disputes, created_by)
                VALUES (?, ?, ?, ?::jsonb, ?, ?, ?, ?, ?, ?, ?)
                """, id, placeId, feature, value.toString(), source, sourceRef, Timestamp.from(fetchedAt),
                confirmedAt == null ? null : Timestamp.from(confirmedAt), confirmations, disputes, createdBy);
        return id;
    }

    /** OSM re-import: same (place, feature, source=osm) is updated, never duplicated. */
    public void upsertOsmFact(String placeId, String feature, JsonNode value, String sourceRef, Instant fetchedAt) {
        jdbc.update("""
                INSERT INTO accessibility_fact (id, place_id, feature, value, source, source_ref, fetched_at)
                VALUES (?, ?, ?, ?::jsonb, 'osm', ?, ?)
                ON CONFLICT (place_id, feature) WHERE source = 'osm'
                DO UPDATE SET value = EXCLUDED.value, source_ref = EXCLUDED.source_ref, fetched_at = EXCLUDED.fetched_at
                """, UUID.randomUUID(), placeId, feature, value.toString(), sourceRef, Timestamp.from(fetchedAt));
    }
}
