-- Encrypted media bytes kept in the database (MEDIA_STORAGE=db), for hosts without a persistent disk
-- (e.g. Render's free tier). With the default MEDIA_STORAGE=fs the files stay on the data volume.
CREATE TABLE media_blobs (
  media_id UUID PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,
  data     BYTEA NOT NULL
);
