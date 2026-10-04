package pl.krakowbezbarier.api.place;

import java.util.*;

/**
 * Curated "~50 places across the city" selection for GET /places.
 * Demo places always first; then OSM places ranked by usefulness (accessibility facts, tourist relevance, name),
 * picked greedily so that no two picks are closer than {@code minDistanceM}. Deterministic (ties broken by id).
 */
public final class PlaceSelector {
    public static final int DEFAULT_LIMIT = 50;
    public static final int MAX_LIMIT = 200;
    public static final int CANDIDATES = 500;
    public static final double MIN_DISTANCE_M = 300;

    public record Candidate(String id, String name, String category, double lat, double lng, boolean demo, int factCount) {}

    private PlaceSelector() {}

    static int categoryRank(String c) {
        if (c == null) return 0;
        return switch (c) {
            case "attraction", "museum", "church", "park" -> 3;
            case "bridge" -> 2;
            case "cafe", "restaurant" -> 1;
            default -> 0;
        };
    }

    /** Higher = more useful. Accessibility facts dominate, then tourist relevance, fact count, being named. */
    public static int score(Candidate c) {
        int s = 0;
        if (c.factCount() > 0) s += 1000;
        s += categoryRank(c.category()) * 100;
        s += Math.min(c.factCount(), 9) * 10;
        if (c.name() != null && !c.name().isBlank()) s += 5;
        return s;
    }

    public static final Comparator<Candidate> RANKING = Comparator
            .comparing((Candidate c) -> !c.demo())
            .thenComparing(Comparator.comparingInt(PlaceSelector::score).reversed())
            .thenComparing(Candidate::id);

    public static List<Candidate> select(Collection<Candidate> candidates, int limit, double minDistanceM) {
        List<Candidate> sorted = new ArrayList<>(candidates);
        sorted.sort(RANKING);
        List<Candidate> picked = new ArrayList<>();
        for (Candidate c : sorted) {
            if (picked.size() >= limit) break;
            if (c.demo()) { picked.add(c); continue; }
            boolean tooClose = false;
            for (Candidate p : picked) {
                if (distanceM(p.lat(), p.lng(), c.lat(), c.lng()) < minDistanceM) { tooClose = true; break; }
            }
            if (!tooClose) picked.add(c);
        }
        return picked;
    }

    public static int clampLimit(Integer limit, int def) {
        int l = limit == null ? def : limit;
        return Math.max(1, Math.min(MAX_LIMIT, l));
    }

    /** Haversine distance in metres. */
    public static double distanceM(double lat1, double lng1, double lat2, double lng2) {
        double r = 6_371_000, dLat = Math.toRadians(lat2 - lat1), dLng = Math.toRadians(lng2 - lng1);
        double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
        return 2 * r * Math.asin(Math.sqrt(a));
    }
}
