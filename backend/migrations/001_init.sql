-- All personal / message data is stored encrypted (*_enc columns, AES-256-GCM).
-- *_hash / *_key columns are HMAC blind indexes used for lookups, so the
-- database alone does not reveal who a user is or who talks to whom.

CREATE TABLE users (
  id                 UUID PRIMARY KEY,
  email_hash         TEXT NOT NULL UNIQUE,
  email_enc          TEXT NOT NULL,
  username_hash      TEXT NOT NULL UNIQUE,
  username_enc       TEXT NOT NULL,
  password_hash      TEXT NOT NULL,
  about_enc          TEXT,
  avatar_media_id    UUID,
  email_verified     BOOLEAN NOT NULL DEFAULT FALSE,
  pending_email_hash TEXT,
  pending_email_enc  TEXT,
  last_seen_at       TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE user_search_tokens (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token   TEXT NOT NULL,
  PRIMARY KEY (user_id, token)
);
CREATE INDEX user_search_tokens_token_idx ON user_search_tokens(token);

CREATE TABLE email_codes (
  id          UUID PRIMARY KEY,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose     TEXT NOT NULL, -- verify_email | reset_password | change_email
  code_hash   TEXT NOT NULL,
  attempts    INT NOT NULL DEFAULT 0,
  expires_at  TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX email_codes_user_idx ON email_codes(user_id, purpose);

CREATE TABLE sessions (
  id           UUID PRIMARY KEY,
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  refresh_hash TEXT NOT NULL UNIQUE,
  device_enc   TEXT,
  expires_at   TIMESTAMPTZ NOT NULL,
  revoked_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX sessions_user_idx ON sessions(user_id);

CREATE TABLE media (
  id           UUID PRIMARY KEY,
  owner_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL, -- avatar | image | video | audio
  mime         TEXT NOT NULL,
  size         INT NOT NULL,
  storage_path TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE chats (
  id              UUID PRIMARY KEY,
  pair_key        TEXT NOT NULL UNIQUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_message_at TIMESTAMPTZ
);

CREATE TABLE chat_members (
  chat_id    UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  member_key TEXT NOT NULL,  -- HMAC(user id)
  member_enc TEXT NOT NULL,  -- encrypted user id
  archived   BOOLEAN NOT NULL DEFAULT FALSE,
  muted      BOOLEAN NOT NULL DEFAULT FALSE,
  joined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (chat_id, member_key)
);
CREATE INDEX chat_members_member_idx ON chat_members(member_key);

CREATE TABLE messages (
  id           UUID PRIMARY KEY,
  chat_id      UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  client_id    TEXT NOT NULL,
  sender_key   TEXT NOT NULL,
  type         TEXT NOT NULL, -- text | image | video | audio
  body_enc     TEXT,
  media_id     UUID REFERENCES media(id) ON DELETE SET NULL,
  meta_enc     TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at    TIMESTAMPTZ,
  deleted_at   TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  read_at      TIMESTAMPTZ,
  UNIQUE (chat_id, sender_key, client_id)
);
CREATE INDEX messages_chat_created_idx ON messages(chat_id, created_at DESC);

CREATE TABLE invitations (
  id           UUID PRIMARY KEY,
  from_key     TEXT NOT NULL,
  to_key       TEXT NOT NULL,
  from_enc     TEXT NOT NULL,
  to_enc       TEXT NOT NULL,
  pair_key     TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending', -- pending | accepted | declined | cancelled
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  responded_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX invitations_pending_pair_idx ON invitations(pair_key) WHERE status = 'pending';
CREATE INDEX invitations_to_idx ON invitations(to_key, status);
CREATE INDEX invitations_from_idx ON invitations(from_key, status);

CREATE TABLE push_tokens (
  token_hash TEXT PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_enc  TEXT NOT NULL,
  platform   TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX push_tokens_user_idx ON push_tokens(user_id);
