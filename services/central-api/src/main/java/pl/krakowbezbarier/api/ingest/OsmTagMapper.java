package pl.krakowbezbarier.api.ingest;

import com.fasterxml.jackson.databind.node.BooleanNode;
import com.fasterxml.jackson.databind.node.IntNode;
import pl.krakowbezbarier.api.ingest.SourceAdapter.ImportedFact;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** OSM tags -> category and accessibility facts (BACKEND.md section 7). */
public final class OsmTagMapper {
    private OsmTagMapper() {}

    private static final Pattern NUMBER = Pattern.compile("(-?\\d+(?:[.,]\\d+)?)");

    public static String category(Map<String, String> t) {
        String tourism = t.getOrDefault("tourism", "");
        String amenity = t.getOrDefault("amenity", "");
        if (tourism.equals("museum") || tourism.equals("gallery")) return "museum";
        if (amenity.equals("place_of_worship")) return "church";
        if (amenity.equals("cafe")) return "cafe";
        if (amenity.equals("restaurant")) return "restaurant";
        if ("park".equals(t.get("leisure"))) return "park";
        if ("bridge".equals(t.get("man_made")) || "yes".equals(t.get("bridge"))) return "bridge";
        if (tourism.equals("attraction") || tourism.equals("viewpoint") || t.containsKey("historic")) return "attraction";
        return null; // e.g. unnamed toilets - not imported as a place
    }

    public static List<ImportedFact> facts(Map<String, String> t) {
        List<ImportedFact> out = new ArrayList<>();
        Integer steps = null;
        if (t.containsKey("step_count")) steps = parseInt(t.get("step_count"));
        if (steps == null) {
            steps = switch (t.getOrDefault("wheelchair", "")) {
                case "yes" -> 0;
                case "limited" -> 1;
                case "no" -> 3;
                default -> null;
            };
        }
        if (steps != null && steps >= 0 && steps <= 50) out.add(new ImportedFact("steps", IntNode.valueOf(steps)));

        String width = t.containsKey("door:width") ? t.get("door:width") : t.get("width");
        Integer widthCm = widthCm(width);
        if (widthCm != null && widthCm >= 30 && widthCm <= 300) out.add(new ImportedFact("doorWidth", IntNode.valueOf(widthCm)));

        String toilets = t.get("toilets:wheelchair");
        if ("yes".equals(toilets) || "no".equals(toilets)) out.add(new ImportedFact("toilet", BooleanNode.valueOf("yes".equals(toilets))));

        if ("yes".equals(t.get("ramp")) || "yes".equals(t.get("ramp:wheelchair"))) out.add(new ImportedFact("ramp", BooleanNode.TRUE));
        if ("yes".equals(t.get("elevator"))) out.add(new ImportedFact("elevator", BooleanNode.TRUE));

        String incline = t.get("incline");
        if (incline != null && incline.contains("%")) {
            Integer pct = parseInt(incline);
            if (pct != null && Math.abs(pct) <= 40) out.add(new ImportedFact("incline", IntNode.valueOf(Math.abs(pct))));
        }
        return out;
    }

    /** "0.9", "0.9 m", "90 cm" -> 90. Plain numbers are metres per OSM convention. */
    static Integer widthCm(String v) {
        if (v == null) return null;
        Matcher m = NUMBER.matcher(v);
        if (!m.find()) return null;
        double d = Double.parseDouble(m.group(1).replace(',', '.'));
        return v.contains("cm") ? (int) Math.round(d) : (int) Math.round(d * 100);
    }

    static Integer parseInt(String v) {
        if (v == null) return null;
        Matcher m = NUMBER.matcher(v);
        return m.find() ? (int) Math.round(Double.parseDouble(m.group(1).replace(',', '.'))) : null;
    }
}
