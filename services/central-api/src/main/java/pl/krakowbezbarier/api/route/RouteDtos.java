package pl.krakowbezbarier.api.route;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;

public final class RouteDtos {
    private RouteDtos() {}

    public record LatLng(double lat, double lng) {}

    /** Thresholds are used only for this call - never stored or logged. */
    public record RouteProfile(Integer maxKerbCm, Integer minWidthCm, Integer maxInclinePct) {}

    public record RouteRequest(@NotNull @Size(min = 2, max = 25) List<@Valid @NotNull LatLng> points,
                               RouteProfile profile, boolean avoidCrowds, boolean optimizeOrder) {
        @Override
        public String toString() { return "RouteRequest[points=" + (points == null ? 0 : points.size()) + "]"; }
    }

    public record Segment(String instruction, double distanceM, List<String> warnings) {}

    /** geometry is a list of [lat, lng] pairs (Flutter order). */
    public record RouteResponse(double distanceM, double durationS, List<double[]> geometry, List<Segment> segments,
                                List<Integer> order, String source, boolean fallback) {}
}
