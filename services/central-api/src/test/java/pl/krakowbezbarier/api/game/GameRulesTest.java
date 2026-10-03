package pl.krakowbezbarier.api.game;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import pl.krakowbezbarier.api.game.GameRules.*;
import pl.krakowbezbarier.api.place.FactValidator;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

class GameRulesTest {
    final ObjectMapper om = JsonMapper.builder().findAndAddModules()
            .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS).build();

    BarrierReport parse(String json) throws Exception { return om.readValue(json, BarrierReport.class); }

    @Test
    void severityMatchesDart() throws Exception {
        assertEquals(0, parse("{}").severity());
        assertEquals(1, parse("{\"steps\":2}").severity());
        assertEquals(2, parse("{\"steps\":3}").severity());
        assertEquals(0, parse("{\"curb\":\"low\"}").severity());
        assertEquals(1, parse("{\"curb\":\"mid\"}").severity());
        assertEquals(2, parse("{\"curb\":\"high\"}").severity());
        assertEquals(0, parse("{\"passage\":\"wide\"}").severity());
        assertEquals(1, parse("{\"passage\":\"medium\"}").severity());
        assertEquals(2, parse("{\"passage\":\"narrow\"}").severity());
        // max: 2 + 2 + 2 + 2 + 1 + 1
        assertEquals(10, parse("""
                {"placeId":"wawel","steps":5,"curb":"high","passage":"narrow","noRamp":true,"uneven":true,"obstacles":true}
                """).severity());
    }

    @Test
    void rarityTableMatchesDart() {
        // score = severity + roll(0..3); >=10 legendary, >=6 epic, >=3 rare, else common
        Rarity[] expected = {Rarity.common, Rarity.common, Rarity.common, Rarity.rare, Rarity.rare, Rarity.rare,
                Rarity.epic, Rarity.epic, Rarity.epic, Rarity.epic, Rarity.legendary, Rarity.legendary, Rarity.legendary, Rarity.legendary};
        for (int score = 0; score < expected.length; score++) assertEquals(expected[score], GameRules.rarityForScore(score), "score " + score);
        assertEquals(10, Rarity.common.points);
        assertEquals(25, Rarity.rare.points);
        assertEquals(60, Rarity.epic.points);
        assertEquals(150, Rarity.legendary.points);
        Random r = new Random(1);
        for (int i = 0; i < 200; i++) {
            Rarity x = GameRules.rarityFor(0, r);
            assertTrue(x == Rarity.common || x == Rarity.rare);
            assertEquals(Rarity.legendary, GameRules.rarityFor(10, r));
        }
    }

    @Test
    void catalogParsesAndSpeciesPickedByRarity() throws Exception {
        JsonNode raw = om.readTree(new ClassPathResource("game/game.json").getInputStream());
        for (String k : List.of("dataset", "isDemo", "initialPoints", "species", "offers", "districts")) assertTrue(raw.has(k), k);
        Catalog c = om.treeToValue(raw, Catalog.class);
        assertEquals(120, c.initialPoints());
        Random r = new Random(7);
        for (Rarity rar : Rarity.values()) assertEquals(rar, GameRules.pickSpecies(c, rar, r).rarity());
        assertTrue(c.offers().stream().anyMatch(o -> !o.verifiedAccess()));
    }

    @Test
    void voucherCodeFormat() {
        Random r = new Random();
        for (int i = 0; i < 50; i++) assertTrue(GameRules.voucherCode(r).matches("KBB-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}"));
    }

    @Test
    void reportFactsAreValid() throws Exception {
        var facts = GameRules.factsFor(parse("{\"steps\":3,\"curb\":\"mid\",\"passage\":\"narrow\",\"noRamp\":true,\"uneven\":true}"));
        Map<String, Object> m = new java.util.HashMap<>();
        facts.forEach(e -> m.put(e.getKey(), e.getValue()));
        assertEquals(Map.of("steps", 3, "kerbHeight", "3-7", "doorWidth", "<70", "ramp", false), m);
        facts.forEach(e -> FactValidator.validate(e.getKey(), om.valueToTree(e.getValue())));
        assertTrue(GameRules.factsFor(parse("{}")).isEmpty());
    }

    @Test
    void jsonShapesMatchDart() throws Exception {
        var state = new GameState(130, Map.of("golab", 2),
                List.of(new Voucher("kawa-rynek", "KBB-AB23", Instant.parse("2026-10-03T10:00:00Z"))));
        JsonNode j = om.readTree(om.writeValueAsString(state));
        assertEquals(130, j.get("points").asInt());
        assertEquals(2, j.at("/caught/golab").asInt());
        JsonNode v = j.at("/vouchers/0");
        assertEquals("kawa-rynek", v.get("offerId").asText());
        assertEquals("KBB-AB23", v.get("code").asText());
        assertEquals("2026-10-03T10:00:00Z", v.get("activatedAt").asText());

        JsonNode s = om.readTree(om.writeValueAsString(new Species("smok", "Smok", "x", Rarity.legendary)));
        assertEquals("legendary", s.get("rarity").asText());
        for (String k : List.of("id", "name", "emoji", "rarity")) assertTrue(s.has(k), k);

        var resp = new GameService.ReportResponse(new Species("golab", "Gołąb", "x", Rarity.common), 10, state);
        JsonNode rj = om.readTree(om.writeValueAsString(resp));
        assertTrue(rj.has("species") && rj.has("points") && rj.has("state"));
        JsonNode vj = om.readTree(om.writeValueAsString(new GameService.VoucherResponse(state.vouchers().get(0), state)));
        assertTrue(vj.has("voucher") && vj.has("state"));
    }
}
