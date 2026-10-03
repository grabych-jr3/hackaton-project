package pl.krakowbezbarier.api.game;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.ClassPathResource;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.game.GameRules.*;
import pl.krakowbezbarier.api.place.FactValidator;
import pl.krakowbezbarier.api.place.PlaceRepository;

import java.io.IOException;
import java.io.InputStream;
import java.security.SecureRandom;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.*;

@Service
public class GameService {
    private static final Logger log = LoggerFactory.getLogger(GameService.class);

    private final JdbcTemplate jdbc;
    private final ObjectMapper om;
    private final PointsService points;
    private final PlaceRepository places;
    private final JsonNode catalogJson;
    private final Catalog catalog;
    private final SecureRandom random = new SecureRandom();

    public GameService(JdbcTemplate jdbc, ObjectMapper om, PointsService points, PlaceRepository places) throws IOException {
        this.jdbc = jdbc;
        this.om = om;
        this.points = points;
        this.places = places;
        try (InputStream in = new ClassPathResource("game/game.json").getInputStream()) {
            this.catalogJson = om.readTree(in);
        }
        this.catalog = om.treeToValue(catalogJson, Catalog.class);
    }

    public JsonNode catalogJson() { return catalogJson; }

    public Catalog catalog() { return catalog; }

    public record ReportRequest(String placeId, BarrierReport report) {}
    /** points = the creature's sell value; awarded is always 0 (catching no longer adds points). */
    public record ReportResponse(Species species, int points, int awarded, GameState state) {
        public ReportResponse(Species species, int points, GameState state) { this(species, points, 0, state); }
    }
    public record SellRequest(String speciesId, Integer count) {}
    public record SellResponse(int earned, GameState state) {}
    public record VoucherRequest(String offerId) {}
    public record VoucherResponse(Voucher voucher, GameState state) {}

    /** New users get the catalog's initialPoints once (idempotent via the ledger). */
    public void grantInitialPoints(UUID userId) {
        if (catalog.initialPoints() > 0) points.award(userId, catalog.initialPoints(), "initial", userId.toString());
    }

    public GameState state(UUID userId) {
        Integer pts = jdbc.queryForObject("SELECT points FROM app_user WHERE id = ?", Integer.class, userId);
        Map<String, Integer> caught = new LinkedHashMap<>();
        jdbc.query("SELECT species_id, count FROM user_species WHERE user_id = ? ORDER BY species_id",
                rs -> { caught.put(rs.getString(1), rs.getInt(2)); }, userId);
        List<Voucher> vouchers = jdbc.query(
                "SELECT offer_id, code, activated_at FROM game_voucher WHERE user_id = ? ORDER BY activated_at DESC",
                (rs, i) -> new Voucher(rs.getString(1), rs.getString(2), rs.getTimestamp(3).toInstant()), userId);
        return new GameState(pts == null ? 0 : pts, caught, vouchers);
    }

    @Transactional
    public ReportResponse submitReport(UUID userId, ReportRequest req) {
        if (req == null || req.report() == null) throw ApiException.badRequest("report is required");
        BarrierReport report = req.report();
        if (report.stepsOr0() < 0 || report.stepsOr0() > 50) throw ApiException.badRequest("steps must be in 0..50");
        String placeId = req.placeId() != null && !req.placeId().isBlank() ? req.placeId()
                : (report.placeId() != null && !report.placeId().isBlank() ? report.placeId() : null);
        if (placeId != null && !places.exists(placeId)) throw ApiException.notFound("Place " + placeId + " not found");

        int severity = report.severity();
        Species species = rollSpecies(report);
        int pts = species.rarity().points;

        UUID reportId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO game_report (id, user_id, place_id, report, severity, rarity, species_id, points)
                VALUES (?, ?, ?, ?::jsonb, ?, ?, ?, ?)""",
                reportId, userId, placeId, toJson(report), severity, species.rarity().name(), species.id(), pts);
        addCreature(userId, species.id());

        if (placeId != null) {
            Instant now = Instant.now();
            for (var f : GameRules.factsFor(report)) {
                JsonNode v = om.valueToTree(f.getValue());
                try {
                    FactValidator.validate(f.getKey(), v);
                } catch (ApiException e) {
                    log.info("Skipping report fact {}: {}", f.getKey(), e.getMessage());
                    continue;
                }
                places.insertFact(placeId, f.getKey(), v, "user", "report:" + reportId, now, null, 0, 0, userId);
            }
        }
        return new ReportResponse(species, pts, state(userId));
    }

    /** Rarity from the report's severity (+ luck roll), then a random species of that rarity. */
    public Species rollSpecies(BarrierReport report) {
        return GameRules.pickSpecies(catalog, GameRules.rarityFor(report.severity(), random), random);
    }

    /** Adds one creature to the user's collection. Never touches points. */
    public void addCreature(UUID userId, String speciesId) {
        jdbc.update("""
                INSERT INTO user_species (user_id, species_id, count) VALUES (?, ?, 1)
                ON CONFLICT (user_id, species_id) DO UPDATE SET count = user_species.count + 1""",
                userId, speciesId);
    }

    public Optional<Species> species(String id) {
        return id == null ? Optional.empty() : catalog.species().stream().filter(s -> s.id().equals(id)).findFirst();
    }

    @Transactional
    public SellResponse sell(UUID userId, SellRequest req) {
        if (req == null || req.speciesId() == null || req.speciesId().isBlank()) throw ApiException.badRequest("speciesId is required");
        if (req.count() == null || req.count() < 1) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_COUNT", "count must be at least 1");
        }
        Species species = catalog.species().stream().filter(s -> s.id().equals(req.speciesId())).findFirst()
                .orElseThrow(() -> ApiException.notFound("Species " + req.speciesId() + " not found"));
        List<Integer> owned = jdbc.queryForList(
                "SELECT count FROM user_species WHERE user_id = ? AND species_id = ? FOR UPDATE", Integer.class, userId, species.id());
        int have = owned.isEmpty() || owned.get(0) == null ? 0 : owned.get(0);
        int count = req.count();
        if (count > have) {
            throw new ApiException(HttpStatus.CONFLICT, "NOT_ENOUGH_CREATURES", "You own only " + have + " of " + species.id());
        }
        // Keep the row at 0: a species once caught stays discovered in the collection.
        jdbc.update("UPDATE user_species SET count = count - ? WHERE user_id = ? AND species_id = ?", count, userId, species.id());
        int earned = GameRules.sellEarnings(species.rarity(), count);
        points.award(userId, earned, "sell", UUID.randomUUID().toString());
        return new SellResponse(earned, state(userId));
    }

    @Transactional
    public VoucherResponse activateVoucher(UUID userId, String offerId) {
        VoucherOffer offer = catalog.offers().stream().filter(o -> o.id().equals(offerId)).findFirst()
                .orElseThrow(() -> ApiException.notFound("Offer " + offerId + " not found"));
        if (!offer.verifiedAccess()) {
            throw new ApiException(HttpStatus.FORBIDDEN, "OFFER_NOT_VERIFIED", "Partner accessibility is not verified");
        }
        Integer balance = jdbc.queryForObject("SELECT points FROM app_user WHERE id = ? FOR UPDATE", Integer.class, userId);
        if (balance == null || balance < offer.cost()) {
            throw new ApiException(HttpStatus.PAYMENT_REQUIRED, "INSUFFICIENT_POINTS", "Not enough points");
        }
        UUID id = UUID.randomUUID();
        Instant now = Instant.now();
        Voucher v = new Voucher(offer.id(), GameRules.voucherCode(random), now);
        jdbc.update("INSERT INTO game_voucher (id, user_id, offer_id, code, cost, activated_at) VALUES (?, ?, ?, ?, ?, ?)",
                id, userId, v.offerId(), v.code(), offer.cost(), Timestamp.from(now));
        points.award(userId, -offer.cost(), "voucher", id.toString());
        return new VoucherResponse(v, state(userId));
    }

    private String toJson(Object o) {
        try {
            return om.writeValueAsString(o);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
