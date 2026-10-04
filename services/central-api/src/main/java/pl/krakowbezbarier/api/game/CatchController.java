package pl.krakowbezbarier.api.game;

import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;
import pl.krakowbezbarier.api.auth.CurrentUser;

import java.io.IOException;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
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

    @GetMapping
    public List<Map<String, Object>> list(@RequestParam(required = false) Instant since,
                                          @RequestParam(defaultValue = "20") int limit) {
        return catches.list(CurrentUser.id(), since, limit);
    }

    @GetMapping("/{id}/photo")
    public ResponseEntity<byte[]> photo(@PathVariable UUID id) {
        CatchService.Photo p = catches.photo(id, CurrentUser.id());
        return ResponseEntity.ok().contentType(MediaType.parseMediaType(p.contentType()))
                .cacheControl(CacheControl.maxAge(Duration.ofDays(1)).cachePrivate()).body(p.bytes());
    }

    @GetMapping("/{id}")
    public Map<String, Object> get(@PathVariable UUID id) {
        return catches.get(id, CurrentUser.id());
    }
}
