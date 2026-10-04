-- Spawns: kind ('seed' | 'user' | 'auto'), stable seed key for the demo seeder, owner of user spawns, per-user catches.
ALTER TABLE creature_spawn ADD COLUMN kind varchar NOT NULL DEFAULT 'auto' CHECK (kind IN ('seed', 'user', 'auto'));
ALTER TABLE creature_spawn ADD COLUMN seed_key varchar UNIQUE;
ALTER TABLE creature_spawn ADD COLUMN created_by uuid REFERENCES app_user (id) ON DELETE CASCADE;
ALTER TABLE creature_spawn ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
CREATE INDEX creature_spawn_expires_idx ON creature_spawn (expires_at);
CREATE INDEX creature_spawn_user_idx ON creature_spawn (created_by, created_at) WHERE kind = 'user';

CREATE TABLE spawn_catch (
    user_id   uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    spawn_id  uuid NOT NULL REFERENCES creature_spawn (id) ON DELETE CASCADE,
    caught_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, spawn_id)
);
