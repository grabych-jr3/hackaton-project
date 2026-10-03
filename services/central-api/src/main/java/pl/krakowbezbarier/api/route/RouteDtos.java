package pl.krakowbezbarier.api.route;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;

public final class RouteDtos {
    private RouteDtos() {}

    public record LatLng(double lat, double lng) {}

    /** Thresholds are used only for this call - never stored or logged.
     *  maxSteps: 0 = no steps at all (wheelchair), >0 = a few steps OK (stroller), null = not given. */
    public record RouteProfile(Integer maxSteps, Integer maxKerbCm, Integer minWidthCm, Integer maxInclinePct) {
        public RouteProfile(Integer maxKerbCm, Integer minWidthCm, Integer maxInclinePct) {
            this(null, maxKerbCm, minWidthCm, maxInclinePct);
        }
    }

    public record RouteRequest(@NotNull @Size(min = 2, max = 25) List<@Valid @NotNull LatLng> points,
                               RouteProfile profile, boolean avoidCrowds, boolean optimizeOrder) {
        @Override
        public String toString() { return "RouteRequest[points=" + (points == null ? 0 : points.size()) + "]"; }
    }

    /** warning: single nullable string (contract v2). */
    public record Segment(String instruction, double distanceM, String warning) {}

    /** Index span [fromIndex, toIndex] into the route's geometry that is not passable for the profile.
     *  type: steps | steep | surface | narrow. */
    public record Barrier(int fromIndex, int toIndex, String type, String label, String detail) {}

    /**
     * geometry is a list of [lat, lng] pairs (Flutter order).
     * profile: "foot-walking" (primary) or "wheelchair" (alternative).
     * relaxed = wheelchair restrictions were dropped to find a route;
     * fallbackReason = Polish explanation when fallback=true, else null.
     * accessible = barriers empty and route data available (false on fallback).
     * alternative = wheelchair route when the primary has barriers, else null (its own barriers are reported too).
     * note = Polish remark, e.g. "Brak trasy bez barier do samego celu — ostatnie N m może wymagać pomocy".
     */
    public record RouteResponse(String profile, double distanceM, double durationS, List<double[]> geometry,
                                List<Segment> segments, List<Integer> order, String source, boolean fallback,
                                boolean relaxed, String fallbackReason, List<Barrier> barriers, boolean accessible,
                                RouteResponse alternative, String note) {
        public RouteResponse(String profile, double distanceM, double durationS, List<double[]> geometry,
                             List<Segment> segments, List<Integer> order, String source, boolean fallback,
                             boolean relaxed, String fallbackReason, List<Barrier> barriers, boolean accessible,
                             RouteResponse alternative) {
            this(profile, distanceM, durationS, geometry, segments, order, source, fallback, relaxed, fallbackReason,
                    barriers, accessible, alternative, null);
        }

        public RouteResponse withBarriers(List<Barrier> b, boolean acc) {
            return new RouteResponse(profile, distanceM, durationS, geometry, segments, order, source, fallback,
                    relaxed, fallbackReason, b, acc, alternative, note);
        }

        public RouteResponse withAlternative(RouteResponse alt) {
            return new RouteResponse(profile, distanceM, durationS, geometry, segments, order, source, fallback,
                    relaxed, fallbackReason, barriers, accessible, alt, note);
        }

        /** Polish note shown with the route (e.g. the accessible route stops short of the destination). */
        public RouteResponse withNote(String n) {
            return new RouteResponse(profile, distanceM, durationS, geometry, segments, order, source, fallback,
                    relaxed, fallbackReason, barriers, accessible, alternative, n);
        }
    }
}
