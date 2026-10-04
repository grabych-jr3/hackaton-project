package pl.krakowbezbarier.api.crowd;

import java.time.DayOfWeek;
import java.time.Instant;
import java.time.LocalDateTime;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Crowd estimate per grid cell, built from open data only (no scraping):
 * {@code crowd = w1·base + w2·survey + w3·live} (BACKEND.md 5.5).
 * <ul>
 *   <li>base: OSM places weighted by category × hour-of-day profile × opening_hours, plus ZTP GTFS departures,
 *       × month seasonality. The profiles and weights are hand-made heuristics, not measurements.</li>
 *   <li>survey: "Jak tłoczno?" answers with exponential decay (half-life 30 min).</li>
 *   <li>live: distinct active app users in the last 15 min, used only when there are at least 3 (privacy).</li>
 * </ul>
 */
public final class CrowdModel {
    private CrowdModel() {}

    public static final double W_BASE = 0.5, W_SURVEY = 0.4, W_LIVE = 0.1;
    public static final double SURVEY_HALF_LIFE_MIN = 30;
    public static final int LIVE_MIN_USERS = 3;
    /** Users in a cell at which "live" saturates to 1. */
    static final double LIVE_FULL_USERS = 20;
    /** Weight of a cell whose stops have the city's busiest departure hour. */
    static final double TRANSIT_WEIGHT = 6;
    /** A place whose opening_hours could not be evaluated counts at this fraction. */
    static final double UNKNOWN_HOURS_FACTOR = 0.7;
    /** Raw base at which a cell counts as fully crowded = REFERENCE_SHARE × the busiest cell's peak potential. */
    static final double REFERENCE_SHARE = 0.6;

    /** Category weight: how many people a place of this kind attracts (heuristic). */
    public static double categoryWeight(String category) {
        if (category == null) return 1;
        return switch (category) {
            case "attraction" -> 5;
            case "museum" -> 4;
            case "church", "bridge" -> 3;
            case "restaurant", "cafe", "park" -> 2;
            default -> 1;
        };
    }

    // Hour-of-day profiles 0..23, 0..1 (heuristic; tourists late morning to evening, bars in the evening).
    private static final double[] TOURIST = {.05, .03, .02, .02, .02, .05, .1, .2, .35, .55, .75, .9, 1, 1, 1, .95, .9, .85, .75, .6, .45, .3, .15, .08};
    private static final double[] MUSEUM = {0, 0, 0, 0, 0, 0, 0, 0, .1, .5, .8, .95, 1, 1, .95, .9, .75, .5, .2, .05, 0, 0, 0, 0};
    private static final double[] FOOD = {.05, .02, 0, 0, 0, 0, .05, .2, .35, .4, .4, .5, .85, 1, .8, .55, .5, .6, .85, 1, .9, .7, .4, .15};
    private static final double[] CHURCH = {0, 0, 0, 0, 0, 0, .15, .3, .4, .5, .55, .55, .5, .45, .4, .4, .4, .45, .5, .3, .1, 0, 0, 0};
    private static final double[] PARK = {0, 0, 0, 0, 0, .05, .15, .25, .3, .35, .45, .55, .65, .7, .75, .8, .85, .85, .75, .55, .3, .15, .05, 0};
    private static final double[] TRANSIT_DAY = {.05, .02, .01, .01, .05, .2, .55, .9, 1, .75, .6, .6, .65, .7, .8, .95, 1, .95, .75, .55, .4, .3, .2, .1};

    static double[] hourProfile(String category) {
        if (category == null) return TOURIST;
        return switch (category) {
            case "museum" -> MUSEUM;
            case "restaurant", "cafe" -> FOOD;
            case "church" -> CHURCH;
            case "park" -> PARK;
            default -> TOURIST;
        };
    }

    /** Multiplier for the weekday: tourist places are busier at weekends, churches on Sunday. */
    static double dayFactor(String category, DayOfWeek d) {
        boolean weekend = d == DayOfWeek.SATURDAY || d == DayOfWeek.SUNDAY;
        if ("church".equals(category)) return d == DayOfWeek.SUNDAY ? 1.6 : 1;
        return weekend ? 1.25 : 1;
    }

    /** Month seasonality of tourism in Kraków (rough shape of GUS/MOT accommodation statistics), peak = 1. */
    private static final double[] SEASON = {.55, .55, .65, .8, .9, .95, 1, 1, .9, .8, .65, .75};

    static double season(int month) { return SEASON[month - 1]; }

    public record Place(String category, String openingHours) {}

    /** Raw (unnormalised) base load of a cell at local time t. transitProfile: 24 values 0..1 or null. */
    public static double rawBase(Collection<Place> places, double[] transitProfile, LocalDateTime t) {
        int h = t.getHour();
        double sum = 0;
        for (Place p : places) {
            Boolean open = OpeningHours.isOpen(p.openingHours(), t);
            double openFactor = open == null ? UNKNOWN_HOURS_FACTOR : (open ? 1 : 0);
            sum += categoryWeight(p.category()) * hourProfile(p.category())[h] * dayFactor(p.category(), t.getDayOfWeek()) * openFactor;
        }
        if (transitProfile != null && transitProfile.length == 24) sum += TRANSIT_WEIGHT * transitProfile[h];
        return sum * season(t.getMonthValue());
    }

    /** Raw base a cell can reach at its busiest (all open, peak hour, weekend): used to normalise. */
    public static double peakPotential(Collection<Place> places, double[] transitProfile) {
        double sum = 0;
        for (Place p : places) sum += categoryWeight(p.category()) * dayFactor(p.category(), DayOfWeek.SUNDAY);
        if (transitProfile != null && transitProfile.length == 24) {
            double max = 0;
            for (double v : transitProfile) max = Math.max(max, v);
            sum += TRANSIT_WEIGHT * max;
        }
        return sum;
    }

    /** base 0..1 for a raw value and the city reference (busiest cell's peak potential). */
    public static double normalise(double raw, double cityPeak) {
        if (cityPeak <= 0) return 0;
        return Math.min(1, raw / (REFERENCE_SHARE * cityPeak));
    }

    /** Demo hotspots {lat, lng, strength 0..1, radius m}: Rynek, Wawel, Kazimierz, Dworzec/Galeria, Planty-Floriańska. */
    static final double[][] DEMO_HOTSPOTS = {
            {50.0617, 19.9373, 1.0, 550}, {50.0540, 19.9355, 0.85, 380}, {50.0515, 19.9450, 0.7, 450},
            {50.0670, 19.9450, 0.75, 380}, {50.0650, 19.9410, 0.6, 300}};

    /**
     * Prototype base for demos (app.crowd.demo): busy Old Town, quieter outskirts, a stable per-cell jitter,
     * scaled by the tourist hour profile. Not data - only so the map looks realistic before real inputs arrive.
     */
    public static double demoBase(String cellId, double lat, double lng, LocalDateTime t) {
        double v = 0.08;
        for (double[] h : DEMO_HOTSPOTS) {
            double d = pl.krakowbezbarier.api.common.GeoUtils.haversineM(lat, lng, h[0], h[1]);
            v = Math.max(v, h[2] * Math.exp(-Math.pow(d / h[3], 2)));
        }
        double jitter = ((cellId.hashCode() & 0xffff) / 65535.0 - 0.5) * 0.2; // stable +-0.1
        double hour = 0.55 + 0.45 * TOURIST[t.getHour()]; // demo stays readable at night too
        return Math.max(0, Math.min(1, (v + jitter) * hour));
    }

    public record Report(int level, Instant at) {}

    /** Survey estimate: weighted mean of level/2 with weight 0.5^(age/half-life), and its total weight. */
    public record Survey(double value, double weight, int count) {}

    public static Survey survey(List<Report> reports, Instant now) {
        double wSum = 0, vSum = 0;
        for (Report r : reports) {
            double ageMin = Math.max(0, (now.toEpochMilli() - r.at().toEpochMilli()) / 60_000.0);
            double w = Math.pow(0.5, ageMin / SURVEY_HALF_LIFE_MIN);
            wSum += w;
            vSum += w * (r.level() / 2.0);
        }
        return new Survey(wSum == 0 ? 0 : vSum / wSum, wSum, reports.size());
    }

    /** Live estimate 0..1, or null when hidden (fewer than LIVE_MIN_USERS users). */
    public static Double live(int activeUsers) {
        if (activeUsers < LIVE_MIN_USERS) return null;
        return Math.min(1, activeUsers / LIVE_FULL_USERS);
    }

    public record Estimate(double crowd, String label, String source, Map<String, Object> mix) {}

    /**
     * Combines the parts. The survey weight scales with its confidence (one fresh answer = half weight, two = full),
     * and the weights of missing parts go to the remaining ones.
     */
    public static Estimate combine(double base, Survey survey, Double live) {
        double surveyConf = survey == null ? 0 : Math.min(1, survey.weight() / 2);
        double wb = W_BASE, ws = W_SURVEY * surveyConf, wl = live == null ? 0 : W_LIVE;
        double total = wb + ws + wl;
        double crowd = (wb * base + ws * (survey == null ? 0 : survey.value()) + wl * (live == null ? 0 : live)) / total;
        crowd = Math.round(crowd * 100) / 100.0;
        String source = ws > wb ? "survey" : (wl > wb ? "live" : "base");
        Map<String, Object> mix = new LinkedHashMap<>();
        mix.put("base", round(wb / total));
        mix.put("survey", round(ws / total));
        mix.put("live", round(wl / total));
        mix.put("reports", survey == null ? 0 : survey.count());
        return new Estimate(crowd, label(crowd), source, mix);
    }

    public static String label(double crowd) {
        if (crowd < 0.34) return "luźno";
        if (crowd < 0.67) return "średnio";
        return "tłoczno";
    }

    private static double round(double v) { return Math.round(v * 100) / 100.0; }
}
