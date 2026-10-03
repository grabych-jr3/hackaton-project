package pl.krakowbezbarier.api.place;

import java.util.Set;

/** Enum values exactly as in Flutter (camelCase). Stored as varchar. */
public final class Enums {
    private Enums() {}

    public static final Set<String> FEATURES = Set.of(
            "steps", "kerbHeight", "doorWidth", "incline", "ramp", "elevator", "toilet", "bench", "disabledParking");
    public static final Set<String> FLAG_FEATURES = Set.of("ramp", "elevator", "toilet", "bench", "disabledParking");
    public static final Set<String> SOURCES = Set.of("osm", "msip", "otwarteDane", "owner", "user", "ai", "estimate");
    public static final Set<String> CATEGORIES = Set.of(
            "attraction", "museum", "church", "cafe", "restaurant", "park", "bridge");
}
