package pl.krakowbezbarier.api.auth;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/auth")
public class AnonymousAuthController {
    private final JdbcTemplate jdbc;
    private final JwtService jwt;

    public AnonymousAuthController(JdbcTemplate jdbc, JwtService jwt) {
        this.jdbc = jdbc;
        this.jwt = jwt;
    }

    public record AnonymousRequest(@NotBlank @Size(max = 200) String deviceId) {}
    public record AuthResponse(String token, String userId, int points) {}

    /** The raw deviceId is never stored - only its SHA-256. */
    @PostMapping("/anonymous")
    public AuthResponse anonymous(@Valid @RequestBody AnonymousRequest req) {
        String hash = JwtService.sha256Hex(req.deviceId());
        jdbc.update("INSERT INTO app_user (id, device_hash) VALUES (?, ?) ON CONFLICT (device_hash) DO NOTHING",
                UUID.randomUUID(), hash);
        var row = jdbc.queryForMap("SELECT id, points FROM app_user WHERE device_hash = ?", hash);
        UUID id = (UUID) row.get("id");
        return new AuthResponse(jwt.issue(id), id.toString(), ((Number) row.get("points")).intValue());
    }
}
