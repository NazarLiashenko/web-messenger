-- Polls in group chats. A poll is posted as a message of type 'poll' (body = question, so it is searchable);
-- the options and votes live here. Everything identifying is encrypted or blind-indexed.

CREATE TABLE polls (
  id          UUID PRIMARY KEY,
  message_id  UUID NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
  chat_id     UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  creator_key TEXT NOT NULL,           -- HMAC(user id)
  options_enc TEXT NOT NULL,           -- encrypted JSON array of option texts
  anonymous   BOOLEAN NOT NULL,        -- chosen by the creator: hide who voted for what
  multiple    BOOLEAN NOT NULL DEFAULT FALSE,
  closed_at   TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE poll_votes (
  poll_id      UUID NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
  voter_key    TEXT NOT NULL,          -- HMAC(user id): one vote per person (per option for multiple choice)
  voter_enc    TEXT,                   -- encrypted user id, only stored for public polls
  option_index INT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (poll_id, voter_key, option_index)
);
