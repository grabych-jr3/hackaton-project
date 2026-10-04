-- Crowds move from 250 m squares (grid_cell) to a 100 m honeycomb in its own table; grid_cell stays for the game.
CREATE TABLE crowd_cell (
    id              varchar PRIMARY KEY,
    city_id         varchar REFERENCES city (id),
    geom            geometry(Polygon, 4326) NOT NULL,
    transit_profile jsonb -- 24 numbers 0..1: relative departures per hour of day
);
CREATE INDEX crowd_cell_geom_gix ON crowd_cell USING GIST (geom);

-- old reports/snapshots point at square cells: drop them (short-lived data anyway)
TRUNCATE crowd_report, crowd_snapshot;
ALTER TABLE crowd_report DROP CONSTRAINT crowd_report_cell_id_fkey;
ALTER TABLE crowd_report ADD CONSTRAINT crowd_report_cell_id_fkey FOREIGN KEY (cell_id) REFERENCES crowd_cell (id) ON DELETE CASCADE;
ALTER TABLE crowd_snapshot DROP CONSTRAINT crowd_snapshot_cell_id_fkey;
ALTER TABLE crowd_snapshot ADD CONSTRAINT crowd_snapshot_cell_id_fkey FOREIGN KEY (cell_id) REFERENCES crowd_cell (id) ON DELETE CASCADE;
ALTER TABLE grid_cell DROP COLUMN transit_profile;
