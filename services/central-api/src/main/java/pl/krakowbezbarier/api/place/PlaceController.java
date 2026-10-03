package pl.krakowbezbarier.api.place;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import pl.krakowbezbarier.api.auth.CurrentUser;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.common.GeoUtils;
import pl.krakowbezbarier.api.health.SourceStatusRepository;
import pl.krakowbezbarier.api.place.Dtos.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1")
public class PlaceController {
    private final PlaceRepository places;
    private final FactService facts;
    private final SourceStatusRepository sources;

    public PlaceController(PlaceRepository places, FactService facts, SourceStatusRepository sources) {
        this.places = places;
        this.facts = facts;
        this.sources = sources;
    }

    /** bbox = minLng,minLat,maxLng,maxLat (optional); max 500 places. */
    @GetMapping("/places")
    public PlacesResponse list(@RequestParam(required = false) String bbox,
                               @RequestParam(required = false) String category) {
        if (category != null && !category.isBlank() && !Enums.CATEGORIES.contains(category)) {
            throw ApiException.badRequest("Unknown category: " + category);
        }
        return new PlacesResponse(places.find(GeoUtils.parseBbox(bbox), category), sources.summary());
    }

    @GetMapping("/places/{id}")
    public PlaceDto get(@PathVariable String id) {
        return places.findById(id).orElseThrow(() -> ApiException.notFound("Place " + id + " not found"));
    }

    @PostMapping("/places/{id}/facts")
    @ResponseStatus(HttpStatus.CREATED)
    public FactDto addFact(@PathVariable String id, @RequestBody NewFactRequest req) {
        return facts.addUserFact(id, req, CurrentUser.id());
    }

    @PostMapping("/facts/{factId}/confirm")
    public FactDto confirm(@PathVariable UUID factId) {
        return facts.vote(factId, CurrentUser.id(), true);
    }

    @PostMapping("/facts/{factId}/dispute")
    public FactDto dispute(@PathVariable UUID factId) {
        return facts.vote(factId, CurrentUser.id(), false);
    }
}
