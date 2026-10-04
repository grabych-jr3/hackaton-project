package pl.krakowbezbarier.api.crowd;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import pl.krakowbezbarier.api.health.SourceStatusRepository;

import java.io.*;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.*;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Open data from ZTP Kraków (GTFS feeds, trams + buses): departures per stop and hour of day, summed per grid cell
 * and stored as {@code grid_cell.transit_profile} (24 values 0..1, relative to the busiest cell-hour).
 * All service days are counted together: only the shape over the day matters.
 */
@Component
public class GtfsTransitImporter {
    private static final Logger log = LoggerFactory.getLogger(GtfsTransitImporter.class);
    static final String SOURCE = "gtfs";

    private final JdbcTemplate jdbc;
    private final CrowdService crowd;
    private final SourceStatusRepository status;
    private final List<String> urls;
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10))
            .followRedirects(HttpClient.Redirect.NORMAL).build();

    public GtfsTransitImporter(JdbcTemplate jdbc, CrowdService crowd, SourceStatusRepository status,
                               @Value("${app.gtfs.urls:}") String urls) {
        this.jdbc = jdbc;
        this.crowd = crowd;
        this.status = status;
        this.urls = Arrays.stream(urls.split(",")).map(String::trim).filter(s -> !s.isEmpty()).toList();
    }

    /** First start: import in the background if no cell has a transit profile yet. */
    @EventListener(ApplicationReadyEvent.class)
    public void initial() {
        if (urls.isEmpty()) return;
        Integer n = jdbc.queryForObject("SELECT count(*) FROM grid_cell WHERE transit_profile IS NOT NULL", Integer.class);
        if (n != null && n > 0) return;
        Thread t = new Thread(this::runSafe, "gtfs-import");
        t.setDaemon(true);
        t.start();
    }

    @Scheduled(cron = "${app.gtfs.cron:0 30 4 * * MON}")
    public void runSafe() {
        if (urls.isEmpty()) return;
        try {
            run();
            status.success(SOURCE);
        } catch (Exception e) {
            log.warn("GTFS import failed: {}", e.getMessage());
            status.error(SOURCE, e.getMessage(), true);
        }
    }

    synchronized void run() throws Exception {
        crowd.ensureLoaded();
        Map<String, double[]> perCell = new HashMap<>();
        for (String url : urls) {
            Path tmp = Files.createTempFile("gtfs", ".zip");
            try {
                HttpRequest req = HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofMinutes(3))
                        .header("User-Agent", "krakow-bez-barier/0.1 (hackathon)").build();
                HttpResponse<Path> res = http.send(req, HttpResponse.BodyHandlers.ofFile(tmp));
                if (res.statusCode() != 200) throw new IOException("HTTP " + res.statusCode() + " for " + url);
                try (ZipFile zip = new ZipFile(tmp.toFile())) {
                    Map<String, String> stopCell = stopCells(zip);
                    countDepartures(zip, stopCell, perCell);
                }
            } finally {
                Files.deleteIfExists(tmp);
            }
        }
        Map<String, double[]> profiles = normalise(perCell);
        List<Object[]> rows = new ArrayList<>();
        profiles.forEach((cell, p) -> rows.add(new Object[]{toJson(p), cell}));
        jdbc.batchUpdate("UPDATE grid_cell SET transit_profile = ?::jsonb WHERE id = ?", rows);
        log.info("GTFS: transit profile for {} cells", rows.size());
        crowd.recompute();
    }

    private Map<String, String> stopCells(ZipFile zip) throws IOException {
        Map<String, String> out = new HashMap<>();
        readCsv(zip, "stops.txt", (h, r) -> {
            try {
                double lat = Double.parseDouble(r.get(h.get("stop_lat"))), lng = Double.parseDouble(r.get(h.get("stop_lon")));
                String cell = crowd.cellAt(lat, lng);
                if (cell != null) out.put(r.get(h.get("stop_id")), cell);
            } catch (RuntimeException ignored) { }
        });
        return out;
    }

    private void countDepartures(ZipFile zip, Map<String, String> stopCell, Map<String, double[]> perCell) throws IOException {
        readCsv(zip, "stop_times.txt", (h, r) -> {
            String cell = stopCell.get(r.get(h.get("stop_id")));
            if (cell == null) return;
            int hour = hour(r.get(h.get("departure_time")));
            if (hour >= 0) perCell.computeIfAbsent(cell, k -> new double[24])[hour]++;
        });
    }

    /** "25:10:00" (GTFS times may pass midnight) -> 1; -1 when unparseable. */
    static int hour(String time) {
        if (time == null) return -1;
        int colon = time.indexOf(':');
        if (colon <= 0) return -1;
        try {
            return Integer.parseInt(time.substring(0, colon).trim()) % 24;
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    static Map<String, double[]> normalise(Map<String, double[]> counts) {
        double max = 0;
        for (double[] c : counts.values()) for (double v : c) max = Math.max(max, v);
        Map<String, double[]> out = new HashMap<>();
        if (max == 0) return out;
        for (var e : counts.entrySet()) {
            double[] p = new double[24];
            for (int i = 0; i < 24; i++) p[i] = Math.round(e.getValue()[i] / max * 1000) / 1000.0;
            out.put(e.getKey(), p);
        }
        return out;
    }

    private static String toJson(double[] p) {
        StringJoiner j = new StringJoiner(",", "[", "]");
        for (double v : p) j.add(Double.toString(v));
        return j.toString();
    }

    interface RowHandler { void row(Map<String, Integer> header, List<String> row); }

    private static void readCsv(ZipFile zip, String name, RowHandler handler) throws IOException {
        ZipEntry e = zip.getEntry(name);
        if (e == null) throw new IOException(name + " missing in GTFS");
        try (BufferedReader in = new BufferedReader(new InputStreamReader(zip.getInputStream(e), StandardCharsets.UTF_8))) {
            String first = in.readLine();
            if (first == null) return;
            if (first.startsWith("﻿")) first = first.substring(1);
            Map<String, Integer> header = new HashMap<>();
            List<String> cols = splitCsv(first);
            for (int i = 0; i < cols.size(); i++) header.put(cols.get(i).trim(), i);
            String line;
            while ((line = in.readLine()) != null) {
                if (line.isEmpty()) continue;
                List<String> row = splitCsv(line);
                try {
                    handler.row(header, row);
                } catch (IndexOutOfBoundsException | NullPointerException ignored) { }
            }
        }
    }

    /** Splits one CSV line, honouring double quotes ("" = literal quote). */
    static List<String> splitCsv(String line) {
        List<String> out = new ArrayList<>();
        StringBuilder sb = new StringBuilder();
        boolean quoted = false;
        for (int i = 0; i < line.length(); i++) {
            char ch = line.charAt(i);
            if (quoted) {
                if (ch == '"') {
                    if (i + 1 < line.length() && line.charAt(i + 1) == '"') { sb.append('"'); i++; }
                    else quoted = false;
                } else sb.append(ch);
            } else if (ch == '"') quoted = true;
            else if (ch == ',') { out.add(sb.toString()); sb.setLength(0); }
            else sb.append(ch);
        }
        out.add(sb.toString());
        return out;
    }
}
