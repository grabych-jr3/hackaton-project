package pl.krakowbezbarier.api.place;

import com.fasterxml.jackson.databind.JsonNode;
import pl.krakowbezbarier.api.common.ApiException;

import java.util.regex.Pattern;

/** Validation rules from BACKEND.md 5.3. */
public final class FactValidator {
    private FactValidator() {}

    /** "3-7", ">7", "<70". */
    static final Pattern RANGE = Pattern.compile("^(\\d{1,3}-\\d{1,3}|[<>]\\d{1,3})$");

    public static void validate(String feature, JsonNode value) {
        if (feature == null || !Enums.FEATURES.contains(feature)) {
            throw ApiException.badRequest("Unknown feature: " + feature);
        }
        if (value == null || value.isNull() || value.isMissingNode()) {
            throw ApiException.badRequest("value is required");
        }
        switch (feature) {
            case "steps" -> requireNumber(feature, value, 0, 50, true);
            case "kerbHeight" -> {
                if (value.isTextual()) {
                    if (!RANGE.matcher(value.asText()).matches()) {
                        throw ApiException.badRequest("kerbHeight range must look like 3-7, >7 or <3");
                    }
                } else {
                    requireNumber(feature, value, 0, 50, false);
                }
            }
            case "doorWidth" -> {
                if (value.isTextual()) {
                    if (!RANGE.matcher(value.asText()).matches()) {
                        throw ApiException.badRequest("doorWidth range must look like 70-90, >90 or <70");
                    }
                } else {
                    requireNumber(feature, value, 30, 300, false);
                }
            }
            case "incline" -> requireNumber(feature, value, 0, 40, false);
            default -> {
                if (!value.isBoolean()) throw ApiException.badRequest(feature + " must be boolean");
            }
        }
    }

    private static void requireNumber(String feature, JsonNode v, double min, double max, boolean integer) {
        if (!v.isNumber()) throw ApiException.badRequest(feature + " must be a number");
        if (integer && !v.canConvertToInt() || integer && v.isFloatingPointNumber() && v.asDouble() % 1 != 0) {
            throw ApiException.badRequest(feature + " must be an integer");
        }
        double d = v.asDouble();
        if (d < min || d > max) throw ApiException.badRequest(feature + " must be in " + (int) min + ".." + (int) max);
    }
}
