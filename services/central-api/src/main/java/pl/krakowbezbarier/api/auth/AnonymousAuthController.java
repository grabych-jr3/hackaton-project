package pl.krakowbezbarier.api.auth;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.annotation.Transactional;
import pl.krakowbezbarier.api.game.GameService;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/auth")
public class AnonymousAuthController {
    private final JdbcTemplate jdbc;
    private final JwtService jwt;
    private final GameService game;

    public AnonymousAuthController(JdbcTemplate jdbc, JwtService jwt, GameService game) {
        this.jdbc = jdbc;
        this.jwt = jwt;
        this.game = game;
    }

    public record AnonymousRequest(@NotBlank @Size(max = 200) String deviceId) {}
    public record AuthResponse(String token, String userId, int points) {}

    /** The raw deviceId is never stored - only its SHA-256. */
    @PostMapping("/anonymous")
    @Transactional
    public AuthResponse anonymous(@Valid @RequestBody AnonymousRequest req) {
        String hash = JwtService.sha256Hex(req.deviceId());
        UUID newId = UUID.randomUUID();
        int created = jdbc.update("INSERT INTO app_user (id, device_hash) VALUES (?, ?) ON CONFLICT (device_hash) DO NOTHING",
                newId, hash);
        if (created == 1) game.grantInitialPoints(newId);
        var row = jdbc.queryForMap("SELECT id, points FROM app_user WHERE device_hash = ?", hash);
        UUID id = (UUID) row.get("id");
        return new AuthResponse(jwt.issue(id), id.toString(), ((Number) row.get("points")).intValue());
    }
}
