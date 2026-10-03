package pl.krakowbezbarier.api.game;

import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;
import pl.krakowbezbarier.api.auth.CurrentUser;

import java.io.IOException;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/catches")
public class CatchController {
    private final CatchService catches;

    public CatchController(CatchService catches) { this.catches = catches; }

    @PostMapping(consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @ResponseStatus(HttpStatus.ACCEPTED)
    public CatchService.SubmitResult submit(@RequestPart("photo") MultipartFile photo,
                                            @RequestParam double lat, @RequestParam double lng,
                                            @RequestParam(required = false) UUID spawnId,
                                            @RequestParam(required = false) String placeId,
                                            @RequestParam Instant takenAt)
            throws IOException {
        return catches.submit(CurrentUser.id(), photo, lat, lng, spawnId, placeId, takenAt);
    }

    @GetMapping("/{id}")
    public Map<String, Object> get(@PathVariable UUID id) {
        return catches.get(id, CurrentUser.id());
    }
}
