-- Photo catches grant a creature (same rules as /game/reports) and no points.
ALTER TABLE catch_record ADD COLUMN species_id varchar;
