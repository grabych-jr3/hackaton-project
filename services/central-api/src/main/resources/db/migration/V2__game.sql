-- Game v2: survey-based catches (BarrierReport) and vouchers. Points live in app_user.points + points_ledger.
CREATE TABLE user_species (
    user_id    uuid    NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    species_id varchar NOT NULL,
    count      int     NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, species_id)
);

CREATE TABLE game_report (
    id         uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    place_id   varchar REFERENCES place (id) ON DELETE SET NULL,
    report     jsonb NOT NULL,
    severity   int NOT NULL,
    rarity     varchar NOT NULL,
    species_id varchar NOT NULL,
    points     int NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX game_report_user_idx ON game_report (user_id, created_at);

CREATE TABLE game_voucher (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    offer_id     varchar NOT NULL,
    code         varchar NOT NULL,
    cost         int NOT NULL,
    activated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX game_voucher_user_idx ON game_voucher (user_id, activated_at DESC);
