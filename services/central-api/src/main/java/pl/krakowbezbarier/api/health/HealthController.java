package pl.krakowbezbarier.api.health;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

@RestController
public class HealthController {
    private final SourceStatusRepository repo;

    public HealthController(SourceStatusRepository repo) { this.repo = repo; }

    @GetMapping({"/health", "/api/v1/health"})
    public Map<String, String> health() {
        return Map.of("status", "UP");
    }

    @GetMapping("/api/v1/health/sources")
    public Map<String, List<SourceStatusRepository.SourceStatus>> sources() {
        return Map.of("sources", repo.all());
    }
}
