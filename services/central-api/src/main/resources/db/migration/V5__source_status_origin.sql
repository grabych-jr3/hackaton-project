-- Which upstream endpoint (Overpass mirror URL, or "snapshot:...") served the last successful import.
ALTER TABLE source_status ADD COLUMN IF NOT EXISTS last_origin varchar;
