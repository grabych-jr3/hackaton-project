package pl.krakowbezbarier.api.route;

import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.*;
import pl.krakowbezbarier.api.route.RouteDtos.RouteRequest;
import pl.krakowbezbarier.api.route.RouteDtos.RouteResponse;

@RestController
@RequestMapping("/api/v1/routes")
public class RouteController {
    private final RouteService routes;

    public RouteController(RouteService routes) { this.routes = routes; }

    @PostMapping
    public RouteResponse route(@Valid @RequestBody RouteRequest req) {
        return routes.route(req);
    }
}
