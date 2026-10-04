package pl.krakowbezbarier.api.crowd;

import java.time.DayOfWeek;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.util.EnumSet;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Minimal parser for the OSM {@code opening_hours} tag, covering the common forms:
 * {@code 24/7}, {@code Mo-Fr 09:00-17:00; Sa 10:00-14:00; Su off}, {@code Mo,We 10:00-12:00,14:00-18:00},
 * rules without days ({@code 10:00-18:00}) and ranges past midnight ({@code 22:00-02:00}).
 * Later rules override earlier ones for their days (as in the spec). Anything else (PH, months, sunrise…) -> unknown.
 */
public final class OpeningHours {
    private OpeningHours() {}

    private static final Pattern RULE = Pattern.compile(
            "^(?:([A-Za-z]{2}(?:\\s*-\\s*[A-Za-z]{2})?(?:\\s*,\\s*[A-Za-z]{2}(?:\\s*-\\s*[A-Za-z]{2})?)*)\\s+)?(.+)$");
    private static final Pattern RANGE = Pattern.compile("^(\\d{1,2}):(\\d{2})\\s*-\\s*(\\d{1,2}):(\\d{2})\\+?$");
    private static final String[] DAYS = {"Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"};

    /** true/false when the tag could be evaluated, null when it is missing or not understood. */
    public static Boolean isOpen(String spec, LocalDateTime t) {
        if (spec == null || spec.isBlank()) return null;
        String s = spec.trim();
        if (s.equals("24/7")) return true;
        Boolean result = null;
        boolean anyRuleForToday = false;
        DayOfWeek today = t.getDayOfWeek(), yesterday = today.minus(1);
        LocalTime now = t.toLocalTime();
        for (String rawRule : s.split(";")) {
            String rule = rawRule.trim();
            if (rule.isEmpty()) continue;
            Matcher m = RULE.matcher(rule);
            if (!m.matches()) return null;
            Set<DayOfWeek> days;
            try {
                days = m.group(1) == null ? EnumSet.allOf(DayOfWeek.class) : days(m.group(1));
            } catch (IllegalArgumentException e) {
                return null; // PH, SH, month names…
            }
            String times = m.group(2).trim();
            boolean appliesToday = days.contains(today);
            if (times.equals("off") || times.equals("closed")) {
                if (appliesToday) { result = false; anyRuleForToday = true; }
                continue;
            }
            boolean openToday = false, openFromYesterday = false;
            for (String r : times.split(",")) {
                Matcher rm = RANGE.matcher(r.trim());
                if (!rm.matches()) return null;
                LocalTime from = time(rm.group(1), rm.group(2)), to = time(rm.group(3), rm.group(4));
                boolean overnight = !to.isAfter(from);
                if (overnight) {
                    if (!now.isBefore(from)) openToday = true;
                    if (days.contains(yesterday) && now.isBefore(to)) openFromYesterday = true;
                } else if (!now.isBefore(from) && now.isBefore(to)) {
                    openToday = true;
                }
            }
            if (appliesToday) { result = openToday; anyRuleForToday = true; }
            if (openFromYesterday) result = true;
        }
        if (result == null && !anyRuleForToday) return false; // rules exist, none for today
        return result;
    }

    private static LocalTime time(String h, String m) {
        int hh = Integer.parseInt(h);
        return hh >= 24 ? LocalTime.MAX : LocalTime.of(hh, Integer.parseInt(m));
    }

    private static Set<DayOfWeek> days(String spec) {
        Set<DayOfWeek> out = EnumSet.noneOf(DayOfWeek.class);
        for (String part : spec.split(",")) {
            String[] ab = part.trim().split("\\s*-\\s*");
            int a = day(ab[0]), b = ab.length > 1 ? day(ab[1]) : a;
            for (int i = a; ; i = (i + 1) % 7) {
                out.add(DayOfWeek.of(i + 1));
                if (i == b) break;
            }
        }
        return out;
    }

    private static int day(String d) {
        for (int i = 0; i < DAYS.length; i++) if (DAYS[i].equalsIgnoreCase(d)) return i;
        throw new IllegalArgumentException(d);
    }
}
