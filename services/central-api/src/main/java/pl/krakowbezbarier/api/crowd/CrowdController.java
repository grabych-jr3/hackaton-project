package pl.krakowbezbarier.api.crowd;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import org.springframework.web.bind.annotation.*;
import pl.krakowbezbarier.api.auth.CurrentUser;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.common.GeoUtils;
import pl.krakowbezbarier.api.crowd.CrowdService.CellCrowd;

import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.List;

@RestController
@RequestMapping("/api/v1/crowd")
public class CrowdController {
    private final CrowdService crowd;

    public CrowdController(CrowdService crowd) { this.crowd = crowd; }

    /** polygon: closed ring of [lat, lng] pairs (Flutter order). */
    public record CellDto(String id, List<double[]> polygon, double crowd, String label, String source, int reports,
                          Instant updatedAt) {}

    public record CrowdResponse(List<CellDto> cells) {}

    public record ReportRequest(@NotNull Double lat, @NotNull Double lng, @NotNull Integer level) {}

    public record ReportResponse(String cellId, Double crowd, String label, int awarded) {}

    /** Current crowd per cell; with {@code at} a base-only forecast (e.g. for planning a visit later today). */
    @GetMapping
    public CrowdResponse get(@RequestParam(required = false) String bbox, @RequestParam(required = false) String at) {
        GeoUtils.BBox b = GeoUtils.parseBbox(bbox);
        List<CellCrowd> cells;
        if (at == null || at.isBlank()) {
            cells = crowd.current(b);
        } else {
            try {
                cells = crowd.forecast(b, Instant.parse(at));
            } catch (DateTimeParseException e) {
                throw ApiException.badRequest("at must be an ISO-8601 instant");
            }
        }
        return new CrowdResponse(cells.stream().map(c -> new CellDto(c.id(), crowd.polygon(c.id()), c.crowd(), c.label(),
                c.source(), c.reports(), c.updatedAt())).toList());
    }

    @PostMapping("/reports")
    public ReportResponse report(@Valid @RequestBody ReportRequest req) {
        var r = crowd.report(CurrentUser.id(), req.lat(), req.lng(), req.level());
        return new ReportResponse(r.cellId(), r.cell() == null ? null : r.cell().crowd(),
                r.cell() == null ? null : r.cell().label(), r.awarded());
    }
}
