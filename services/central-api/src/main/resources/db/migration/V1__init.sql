CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE city (
    id          varchar PRIMARY KEY,
    name        varchar NOT NULL,
    bbox        geometry(Polygon, 4326),
    timezone    varchar NOT NULL DEFAULT 'Europe/Warsaw',
    grid_size_m int     NOT NULL DEFAULT 250
);
CREATE INDEX city_bbox_gix ON city USING GIST (bbox);

INSERT INTO city (id, name, bbox, timezone, grid_size_m)
VALUES ('krakow', 'Kraków', ST_MakeEnvelope(19.90, 50.04, 19.98, 50.08, 4326), 'Europe/Warsaw', 250);

CREATE TABLE place (
    id         varchar PRIMARY KEY,
    city_id    varchar REFERENCES city (id),
    name       varchar NOT NULL,
    category   varchar NOT NULL,
    geom       geometry(Point, 4326) NOT NULL,
    address    varchar,
    osm_tags   jsonb,
    is_demo    boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX place_geom_gix ON place USING GIST (geom);
CREATE INDEX place_category_idx ON place (category);

CREATE TABLE app_user (
    id          uuid PRIMARY KEY,
    device_hash varchar NOT NULL UNIQUE,
    points      int NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE accessibility_fact (
    id            uuid PRIMARY KEY,
    place_id      varchar NOT NULL REFERENCES place (id) ON DELETE CASCADE,
    feature       varchar NOT NULL,
    value         jsonb NOT NULL,
    source        varchar NOT NULL,
    source_ref    varchar,
    fetched_at    timestamptz NOT NULL,
    confirmed_at  timestamptz,
    confirmations int NOT NULL DEFAULT 0,
    disputes      int NOT NULL DEFAULT 0,
    created_by    uuid REFERENCES app_user (id),
    active        boolean NOT NULL DEFAULT true
);
CREATE INDEX fact_place_feature_idx ON accessibility_fact (place_id, feature);
-- OSM re-import updates instead of duplicating
CREATE UNIQUE INDEX fact_osm_unique_idx ON accessibility_fact (place_id, feature) WHERE source = 'osm';

CREATE TABLE fact_vote (
    fact_id    uuid NOT NULL REFERENCES accessibility_fact (id) ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES app_user (id),
    vote       varchar NOT NULL CHECK (vote IN ('confirm', 'dispute')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (fact_id, user_id)
);

CREATE TABLE points_ledger (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES app_user (id),
    delta      int NOT NULL,
    reason     varchar NOT NULL,
    ref_id     varchar NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX points_ledger_idem_idx ON points_ledger (reason, ref_id);

CREATE TABLE grid_cell (
    id             varchar PRIMARY KEY,
    city_id        varchar REFERENCES city (id),
    geom           geometry(Polygon, 4326) NOT NULL,
    poi_weight     double precision NOT NULL DEFAULT 0,
    difficulty     double precision NOT NULL DEFAULT 0,
    explored_count int NOT NULL DEFAULT 0
);
CREATE INDEX grid_cell_geom_gix ON grid_cell USING GIST (geom);

CREATE TABLE creature_spawn (
    id         uuid PRIMARY KEY,
    cell_id    varchar REFERENCES grid_cell (id),
    geom       geometry(Point, 4326) NOT NULL,
    species    varchar NOT NULL,
    rarity     varchar NOT NULL,
    expires_at timestamptz NOT NULL,
    bait_id    uuid
);
CREATE INDEX creature_spawn_geom_gix ON creature_spawn USING GIST (geom);

CREATE TABLE catch_record (
    id            uuid PRIMARY KEY,
    user_id       uuid NOT NULL REFERENCES app_user (id),
    spawn_id      uuid REFERENCES creature_spawn (id),
    place_id      varchar REFERENCES place (id),
    geom          geometry(Point, 4326) NOT NULL,
    photo_path    varchar NOT NULL,
    status        varchar NOT NULL,
    ai_result     jsonb,
    ai_confidence double precision,
    phash         varchar,
    points        int,
    reason        varchar,
    created_facts jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    analyzed_at   timestamptz
);
CREATE INDEX catch_record_geom_gix ON catch_record USING GIST (geom);
CREATE INDEX catch_record_user_idx ON catch_record (user_id, created_at);

CREATE TABLE source_status (
    source          varchar PRIMARY KEY,
    last_success_at timestamptz,
    last_error_at   timestamptz,
    last_error      varchar,
    stale           boolean NOT NULL DEFAULT false
);
