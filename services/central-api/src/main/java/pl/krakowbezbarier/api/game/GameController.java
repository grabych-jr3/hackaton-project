package pl.krakowbezbarier.api.game;

import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.web.bind.annotation.*;
import pl.krakowbezbarier.api.auth.CurrentUser;
import pl.krakowbezbarier.api.common.ApiException;
import pl.krakowbezbarier.api.game.GameRules.GameState;

@RestController
@RequestMapping("/api/v1/game")
public class GameController {
    private final GameService game;

    public GameController(GameService game) { this.game = game; }

    /** Same structure as mobile/assets/demo/game.json. Public. */
    @GetMapping("/catalog")
    public JsonNode catalog() { return game.catalogJson(); }

    @GetMapping("/state")
    public GameState state() { return game.state(CurrentUser.id()); }

    @PostMapping("/reports")
    public GameService.ReportResponse report(@RequestBody GameService.ReportRequest req) {
        return game.submitReport(CurrentUser.id(), req);
    }

    @PostMapping("/sell")
    public GameService.SellResponse sell(@RequestBody GameService.SellRequest req) {
        return game.sell(CurrentUser.id(), req);
    }

    @PostMapping("/vouchers")
    public GameService.VoucherResponse voucher(@RequestBody GameService.VoucherRequest req) {
        if (req == null || req.offerId() == null || req.offerId().isBlank()) throw ApiException.badRequest("offerId is required");
        return game.activateVoucher(CurrentUser.id(), req.offerId());
    }
}
