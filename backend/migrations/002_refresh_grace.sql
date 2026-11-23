-- Refresh-token rotation grace period: if the client never received the response of a refresh
-- (app killed, network drop), the previous token stays usable for a short time instead of logging out.
ALTER TABLE sessions ADD COLUMN prev_refresh_hash TEXT;
ALTER TABLE sessions ADD COLUMN rotated_at TIMESTAMPTZ;
CREATE INDEX sessions_prev_refresh_idx ON sessions(prev_refresh_hash);
