package pl.krakowbezbarier.api.health;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/health")
public class HealthController {
    private final SourceStatusRepository repo;

    public HealthController(SourceStatusRepository repo) { this.repo = repo; }

    @GetMapping("/sources")
    public Map<String, List<SourceStatusRepository.SourceStatus>> sources() {
        return Map.of("sources", repo.all());
    }
}
