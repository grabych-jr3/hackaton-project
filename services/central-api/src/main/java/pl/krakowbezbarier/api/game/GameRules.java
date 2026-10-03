package pl.krakowbezbarier.api.game;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonInclude;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.random.RandomGenerator;

/**
 * Port of mobile/lib/features/game/game_models.dart (GameRules, BarrierReport, rarityFor, voucherCode).
 * JSON field names equal the Dart toJson/fromJson keys.
 */
public final class GameRules {
    private GameRules() {}

    public static final Duration VOUCHER_VALIDITY = Duration.ofHours(2);
    static final String CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    public enum Rarity {
        common(10), rare(25), epic(60), legendary(150);
        public final int points;
        Rarity(int points) { this.points = points; }
    }

    public enum CurbRange { none, low, mid, high }

    public enum PassageWidth { none, wide, medium, narrow }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Species(String id, String name, String emoji, Rarity rarity) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record VoucherOffer(String id, String partner, String placeId, String discount, int cost, boolean verifiedAccess) {}

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Catalog(int initialPoints, List<Species> species, List<VoucherOffer> offers) {}

    /** Same fields and defaults as Dart BarrierReport. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    @JsonInclude(JsonInclude.Include.ALWAYS)
    public record BarrierReport(String placeId, Integer steps, CurbRange curb, PassageWidth passage,
                                Boolean noRamp, Boolean uneven, Boolean obstacles) {
        public int stepsOr0() { return steps == null ? 0 : steps; }
        public CurbRange curbOrNone() { return curb == null ? CurbRange.none : curb; }
        public PassageWidth passageOrNone() { return passage == null ? PassageWidth.none : passage; }

        public int severity() {
            int s = 0;
            int st = stepsOr0();
            if (st > 0) s += st >= 3 ? 2 : 1;
            s += switch (curbOrNone()) { case none, low -> 0; case mid -> 1; case high -> 2; };
            s += switch (passageOrNone()) { case none, wide -> 0; case medium -> 1; case narrow -> 2; };
            if (Boolean.TRUE.equals(noRamp)) s += 2;
            if (Boolean.TRUE.equals(uneven)) s += 1;
            if (Boolean.TRUE.equals(obstacles)) s += 1;
            return s;
        }
    }

    public record Voucher(String offerId, String code, Instant activatedAt) {
        /** Extra convenience field; the client computes activatedAt + 2h itself. */
        public Instant getExpiresAt() { return activatedAt == null ? null : activatedAt.plus(VOUCHER_VALIDITY); }
    }

    public record GameState(int points, Map<String, Integer> caught, List<Voucher> vouchers) {}

    /** Rarity grows with severity; the roll adds a bit of luck (0..3). */
    public static Rarity rarityForScore(int score) {
        if (score >= 10) return Rarity.legendary;
        if (score >= 6) return Rarity.epic;
        if (score >= 3) return Rarity.rare;
        return Rarity.common;
    }

    public static Rarity rarityFor(int severity, RandomGenerator random) {
        return rarityForScore(severity + random.nextInt(4));
    }

    public static Species pickSpecies(Catalog catalog, Rarity rarity, RandomGenerator random) {
        List<Species> pool = catalog.species().stream().filter(s -> s.rarity() == rarity).toList();
        if (pool.isEmpty()) pool = catalog.species();
        return pool.get(random.nextInt(pool.size()));
    }

    public static String voucherCode(RandomGenerator random) {
        StringBuilder sb = new StringBuilder("KBB-");
        for (int i = 0; i < 4; i++) sb.append(CODE_CHARS.charAt(random.nextInt(CODE_CHARS.length())));
        return sb.toString();
    }

    /** Barrier report -> user facts (feature, value) for a place; only fields the report sets. */
    public static List<Map.Entry<String, Object>> factsFor(BarrierReport r) {
        var out = new java.util.ArrayList<Map.Entry<String, Object>>();
        if (r.stepsOr0() > 0) out.add(Map.entry("steps", r.stepsOr0()));
        switch (r.curbOrNone()) {
            case low -> out.add(Map.entry("kerbHeight", "0-3"));
            case mid -> out.add(Map.entry("kerbHeight", "3-7"));
            case high -> out.add(Map.entry("kerbHeight", ">7"));
            default -> { }
        }
        switch (r.passageOrNone()) {
            case wide -> out.add(Map.entry("doorWidth", ">90"));
            case medium -> out.add(Map.entry("doorWidth", "70-90"));
            case narrow -> out.add(Map.entry("doorWidth", "<70"));
            default -> { }
        }
        if (Boolean.TRUE.equals(r.noRamp())) out.add(Map.entry("ramp", false));
        return out;
    }
}
