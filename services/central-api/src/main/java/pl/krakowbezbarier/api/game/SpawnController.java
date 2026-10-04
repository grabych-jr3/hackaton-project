package pl.krakowbezbarier.api.game;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import pl.krakowbezbarier.api.auth.CurrentUser;

import java.util.List;

@RestController
@RequestMapping("/api/v1/spawns")
public class SpawnController {
    private final SpawnService spawns;

    public SpawnController(SpawnService spawns) { this.spawns = spawns; }

    /** Public; with a token, caughtByMe is filled for that user. */
    @GetMapping
    public List<SpawnService.SpawnDto> list(@RequestParam(required = false) String bbox) {
        return spawns.list(SpawnService.parseBbox(bbox), CurrentUser.optional());
    }

    @PostMapping("/here")
    @ResponseStatus(HttpStatus.CREATED)
    public SpawnService.SpawnDto here(@RequestBody SpawnService.SpawnHereRequest req) {
        return spawns.spawnHere(CurrentUser.id(), req);
    }
}
