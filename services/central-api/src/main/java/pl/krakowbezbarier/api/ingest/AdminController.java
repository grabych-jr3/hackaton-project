package pl.krakowbezbarier.api.ingest;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import pl.krakowbezbarier.api.common.ApiException;

import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/** Manual import trigger: POST /api/v1/admin/import with header X-Admin-Token: $ADMIN_TOKEN. */
@RestController
@RequestMapping("/api/v1/admin")
public class AdminController {
    private final ImportJob job;
    private final String adminToken;

    public AdminController(ImportJob job, @Value("${app.admin-token:}") String adminToken) {
        this.job = job;
        this.adminToken = adminToken;
    }

    @PostMapping("/import")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public Map<String, String> runImport(@RequestHeader(value = "X-Admin-Token", required = false) String token) {
        if (adminToken.isBlank() || token == null
                || !MessageDigest.isEqual(adminToken.getBytes(StandardCharsets.UTF_8), token.getBytes(StandardCharsets.UTF_8))) {
            throw new ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Invalid admin token");
        }
        Thread.ofVirtual().start(job::runAll);
        return Map.of("status", "STARTED");
    }
}
