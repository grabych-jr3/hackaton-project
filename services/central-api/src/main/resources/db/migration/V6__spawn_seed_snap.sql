-- Cache of seed spawn coordinates snapped to an outdoor walkable point (so ORS/Overpass are not hit every 10 min).
CREATE TABLE spawn_seed_snap (
    seed_key   varchar PRIMARY KEY,
    orig_lat   double precision NOT NULL,
    orig_lng   double precision NOT NULL,
    lat        double precision NOT NULL,
    lng        double precision NOT NULL,
    method     varchar NOT NULL,
    snapped_at timestamptz NOT NULL DEFAULT now()
);
