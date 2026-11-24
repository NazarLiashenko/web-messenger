-- Group chats.
-- A chat is either 'direct' (1:1, identified by pair_key) or 'group' (title, roles, invitations).

ALTER TABLE chats ADD COLUMN kind TEXT NOT NULL DEFAULT 'direct'; -- direct | group
ALTER TABLE chats ALTER COLUMN pair_key DROP NOT NULL;            -- groups have no pair
ALTER TABLE chats ADD COLUMN title_enc TEXT;                      -- group name (encrypted)

-- Roles: owner (creator: rename, remove members) | member.
ALTER TABLE chat_members ADD COLUMN role TEXT NOT NULL DEFAULT 'member';
-- Members who left / were removed keep their row (so their old messages still show a sender),
-- but lose access to the chat.
ALTER TABLE chat_members ADD COLUMN left_at TIMESTAMPTZ;
-- Per-member read position. In groups a message is "read" once any member has read it,
-- so every member's unread counter is computed from their own last_read_at.
ALTER TABLE chat_members ADD COLUMN last_read_at TIMESTAMPTZ;

-- Group invitations reuse the invitations table: chat_id is set, pair_key is a blind index of (group, invitee).
ALTER TABLE invitations ADD COLUMN chat_id UUID REFERENCES chats(id) ON DELETE CASCADE;
