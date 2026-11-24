# Web Messenger 💬

A full-stack, end-to-end-tested messenger that runs **in the browser** and on **Android / iOS** from one
**Flutter** codebase, backed by a **Node.js** API with **PostgreSQL**, realtime **WebSockets** and
**encryption at rest** for all sensitive data.

**Live app: <https://DEPLOY-URL>** — open it in any modern browser, sign up, done.

<p>
Group chats with invitations · search inside messages with highlighting · polls in groups ·
adaptive web layout · registration with email verification · password recovery · persistent sessions ·
profiles with photos · user search · chat invitations · text / photo / video / voice messages ·
sent / delivered / read receipts · edit & delete · typing indicators · archive · mute · notifications
</p>

This project continues the [Mobile Messenger](https://gitea.kood.tech/nazarliashenko/mobile-messenger):
the same Flutter code and the same database schema (extended with migrations), now built for the web and deployed.

---

## Contents

- [Reviewer guide](#reviewer-guide)
- [Features](#features)
- [Usage guide](#usage-guide)
- [Architecture](#architecture)
- [Data encryption](#data-encryption)
- [Design choices & challenges](#design-choices--challenges)
- [Setup & installation (developers)](#setup--installation-developers)
- [Deployment](#deployment)
- [API overview](#api-overview)
- [Bonus features](#bonus-features)
- [Project structure](#project-structure)

---

## Reviewer guide

### Option 1 — the deployed app (nothing to install)

1. Open **<https://DEPLOY-URL>**.
   The server runs on a free plan and sleeps after 15 minutes without visitors: the **first load can take ~50 s**.
2. **Sign up** with a real email address — the 6-digit code arrives by email (check *Spam*).
3. Open a second browser (or a private window) and sign up a second account, so you can chat with yourself.

### Option 2 — run everything locally (Docker only)

```bash
docker compose up -d --build          # Postgres + Mailpit + API on http://localhost:3000
```

| What | Where |
|---|---|
| API + WebSocket | `http://localhost:3000` (health check: `/api/health`) |
| **Mailbox** — every verification / reset email lands here | **http://localhost:8025** |

The web app is then served by Flutter (`cd app && flutter run -d chrome`) or as the full production image:

```bash
docker build -t messenger .            # Flutter web build + API in one image (takes a few minutes)
docker run -p 8080:3000 --network web-messenger_default \
  -e DATABASE_URL=postgres://messenger:messenger@db:5432/messenger \
  -e MASTER_KEY=<base64 of 32 random bytes> -e SMTP_HOST=mail -e SMTP_PORT=1025 messenger
# → http://localhost:8080
```

> Verification codes are also printed in the server log: `docker compose logs api | grep code`.

### A scripted second user

A demo user **dave** can play the other side: it accepts chat and group invitations, shows "typing…",
reads your messages, replies, and votes in new polls.

```bash
cd backend && npm install
node scripts/demo-peer.js <your-username> [apiUrl] [mailpitUrl]     # local: defaults; deployed: pass the URL
```

(Against the deployed app dave needs a real mailbox to verify his email, so use it locally,
or simply register a second account in another browser.)

### Suggested review path

1. **Sign up** — try a weak password (live checklist) and an existing username (inline error); verify the email.
2. **Adaptive layout** — make the window wide (chat list + open chat side by side, navigation rail) and narrow
   (phone layout with bottom navigation). Reload the page: you stay logged in.
3. **1:1 chat** — invite the second account (🔍 → *Invite*), accept in *Invites*, send text / photo / voice.
   Watch ✓ → ✓✓ → blue ✓✓, "typing…". Right-click a message → *Edit* / *Delete*. **Enter** sends, **Shift+Enter** = new line.
4. **Group chat** — *New group* (👥 icon in the chat list) → name + people → they receive an **invitation**
   (*Invites* tab → accept / decline). Open the group: member count, sender names, "Bob is typing…",
   group events ("Bob joined the group"). Group info (click the title): invite more people, rename / remove (owner), leave.
5. **Search in a chat** — 🔍 in the chat header (or **Ctrl/⌘+F**) → matches are **highlighted**, "3 of 12",
   **↑ / ↓** (or Enter / Shift+Enter) jump between them, older history loads automatically. Esc closes.
6. **Polls (bonus)** — in a group: 📎 → *Poll* → question, options, *Anonymous voting*, *Multiple answers*.
   Vote, change the vote, *Retract*; in a public poll click a vote count to see who voted;
   the author closes the poll (right-click → *Close poll*).
7. **Errors** — stop the network (DevTools → Offline) and send a message: "Connecting…" banner, red ⚠ *Not sent*,
   automatic re-send when you are back online. Invalid actions show a message and roll back to the last good state.

---

## Features

### Web version
- The same Flutter app compiled for the browser; all mobile features work (media uses the browser's file picker,
  voice messages are recorded with the browser microphone).
- **Adaptive layout**: phones get the mobile UI (bottom navigation, full-screen chats); from 900 px the app switches to a
  desktop layout — navigation rail, chat list and the open chat **side by side**; pages keep a readable width on big screens.
- **Desktop habits**: Enter to send / Shift+Enter for a new line, Esc to cancel editing, right-click context menus on
  messages and chats, Ctrl/⌘+F to search the open chat, the unread count in the browser tab title ("(2) Messenger"),
  tooltips on every icon button, loading splash, web manifest.
- Served from the **same origin** as the API (no CORS, no configuration) with a strict **Content-Security-Policy**.

### Group chats
- Create a group with a name and pick people from your contacts or by search.
- **Invitations**: picked people receive a group invitation (realtime + notification) and join only after **accepting**;
  they can also **decline**; the inviter can **cancel** a pending invitation. Any member can invite more people.
- Roles: the creator is the **owner** — can rename the group and remove members. Anyone can leave; when the owner leaves,
  ownership passes to the longest-standing member.
- Group events appear in the history ("Anna created the group", "Bob joined the group (invited by Anna)", "Anna removed Bob").
- Per-member unread counters, "Bob is typing…", sender names and colours, member list with online status.
- Members who leave lose access to the group (and to searching it), but their old messages keep their name.

### Search inside chats
- Search the text of messages (and media captions / poll questions) in any 1:1 or group chat.
- Case-insensitive; all matches **highlighted**; the current one is outlined; counter "n of N".
- **Navigate** between matches (newest → oldest and back); the chat scrolls precisely to the message and loads
  older history on the way.
- Works although message bodies are **encrypted in the database** — see [Design choices](#design-choices--challenges).

### Everything from the mobile version
- **Accounts**: sign up (email, username, password with live strength checklist), email verification by a 6-digit code,
  login, password recovery by email, persistent sessions (short-lived JWT + rotating refresh token), logout.
- **Profile**: picture (JPEG / PNG ≤ 5 MB, default picture until set), username, About me, change email / password.
- **People**: search by username prefix or exact email, chat invitations (send / accept / decline / cancel).
- **Chat list** sorted by the last message, previews, unread badges, online dots, typing, archive (swipe or menu, with Undo), mute.
- **Messages**: text, images, videos, voice messages (≤ 20 MB after compression), sent / delivered / read status,
  edit & delete for everyone, typing indicators, last seen, infinite scroll, day separators, image / video viewer.
- **Notifications** for new messages and invitations (system notifications on mobile; tab title on the web).

### Error handling
- Every API error has a stable code and a readable message (inline under form fields or as a snackbar).
- Optimistic UI with rollback: edits, archive / mute, votes return to the last stable state if the server refuses.
- Network loss → "Connecting…" banner, automatic reconnect and resync; unsent messages are marked ⚠ and re-sent
  automatically when the connection is back (or manually: tap → *Retry*). Sending is idempotent (no duplicates).
- Removed from a group while it is open → the chat closes with an explanation.

---

## Usage guide

| Task | How |
|---|---|
| Create an account | *Sign up* → enter the 6-digit code from the email |
| Reset the password | Login screen → *Forgot password?* |
| Find people / start a 1:1 chat | Chats → 🔍 → type a username or email → *Invite*; accept in *Invites* |
| Create a group | Chats → 👥 (*New group*) → name + people → *Create* |
| Accept / decline a group invitation | *Invites* tab → ✓ / ✕ |
| Invite to / manage a group | Open the group → click its name → *Invite people*, ✏️ rename, ⋮ remove member, *Leave group* |
| Search in a chat | 🔍 in the chat header or **Ctrl/⌘+F** → type; **Enter** / ↑ older, **Shift+Enter** / ↓ newer, **Esc** closes |
| Create a poll (groups) | 📎 → *Poll* |
| Vote / change / retract | Tap an option; in multiple-choice polls tick options → *Vote*; *Change*, *Retract* |
| See who voted (public poll) | Click the number of votes next to an option |
| Close a poll (author) | Right-click / long-press the poll → *Close poll* |
| Send media | 📎 → photo / video; 🎤 → record → ➤ |
| Edit / delete / copy | Right-click (web) or long-press (mobile) your message |
| Archive / mute | Right-click / swipe a chat, or ⋮ inside the chat |
| Change the server (mobile app) | Server icon on the login screen |

---

## Architecture

```
            Browser / Android / iOS — one Flutter codebase
┌────────────────────────────────────────────────────────────────┐
│ provider (state) · dio (REST) · socket_io_client (realtime)     │
│ adaptive layout · super_sliver_list (jump to a message)         │
└───────────────┬────────────────────────────────┬───────────────┘
                │ HTTPS (REST, JSON / multipart) │ WSS (Socket.IO)
┌───────────────▼────────────────────────────────▼───────────────┐
│ Node.js 22 · Express 5 · Socket.IO · zod validation · helmet    │
│ serves the built web app from the same origin                   │
│ AES-256-GCM encryption layer + HMAC blind indexes               │
└───────────────┬────────────────────────────────┬───────────────┘
                │                                │
        PostgreSQL 17 (Neon)            Brevo HTTP API / SMTP
   encrypted columns + media blobs        (verification emails)
```

- **Backend** (`backend/`): stateless REST API + Socket.IO; SQL migrations run automatically on start
  (`001_init` … `005_media_blobs`).
- **Realtime events** (server → client): `message:new`, `message:updated`, `message:status`, `typing`, `presence`,
  `chat:new`, `chat:updated`, `chat:removed`, `invite:new`, `invite:updated`, `poll:updated`, `user:updated`.
  Each member receives *their own* view where it differs (archived / muted flags, own poll votes).
- **App** (`app/`): `core/` (API client, socket, navigation, config), `state/` (ChangeNotifier controllers:
  auth, chats, invites, chat room, chat search), `screens/`, `widgets/`. Platform-specific code (keystore, notifications,
  video compression) is isolated so the web build uses browser equivalents.

## Data encryption

All sensitive data is encrypted **before** it is written to the database:

| Data | Storage |
|---|---|
| Email, username, About me | AES-256-GCM ciphertext |
| Message text and metadata, group names, group events | AES-256-GCM |
| Poll options | AES-256-GCM; votes of **anonymous** polls store only a blind index of the voter (no user id at all) |
| Photos, videos, voice messages, avatars | AES-256-GCM encrypted bytes (file volume locally, `media_blobs` table in the cloud) |
| Who talks to whom (chat members, invitation parties, senders) | encrypted user ids + HMAC-SHA256 **blind indexes** for lookups |
| On-device cache / tokens | platform keystore on mobile, WebCrypto-encrypted storage on the web; wiped on logout |
| Passwords | scrypt (salted, memory-hard) |
| Refresh tokens, email codes | SHA-256 / HMAC hashes only |

- Sub-keys for encryption, blind indexes, URL signing and JWT are derived with HKDF-SHA256 from one 256-bit
  **master key** (`MASTER_KEY`). Every value gets a random IV and an authentication tag.
- Media is served through signed, expiring URLs and decrypted on the fly (HTTP Range supported for seeking).

Check it yourself (locally):

```bash
docker compose exec db psql -U messenger -c "SELECT type, body_enc FROM messages LIMIT 3;"
docker compose exec db psql -U messenger -c "SELECT kind, title_enc FROM chats WHERE kind='group';"
```

---

## Design choices & challenges

- **Searching encrypted messages.** The database only has ciphertext, so `LIKE` is impossible, and blind-indexed word
  tokens would only allow whole-word search. The server therefore decrypts the messages of *one* chat in memory when a
  member searches it, matches case-insensitively and returns only message ids (newest first). Nothing decrypted is ever
  written anywhere; non-members get 404. The client then highlights matches in the bubbles it already has and loads
  older pages until the selected match is in memory, then scrolls to it precisely (`super_sliver_list`, because a
  normal `ListView` cannot jump to an item of unknown height).
- **Groups on top of 1:1 chats.** The existing `chats` / `chat_members` tables got a `kind`, roles, `left_at` and a
  per-member `last_read_at`, instead of a separate group model. Members who leave keep their row, so old messages still
  show a sender; group invitations reuse the `invitations` table (with `chat_id`). In groups a message counts as *read*
  when any member read it, while every member keeps their own unread counter.
- **Polls are messages.** A poll is a message of type `poll` (so it appears in history, previews, search and realtime
  delivery like everything else) plus `polls` / `poll_votes` tables. The server builds a per-viewer view (own votes,
  voters only for public polls).
- **One deployment unit.** The production `Dockerfile` builds the Flutter web app and serves it from the API process.
  One URL, no CORS, and the web app needs no configuration — it talks to the server it was loaded from.
- **Free hosting constraints.** Render's free instance has no persistent disk → encrypted media is stored in Postgres
  (`MEDIA_STORAGE=db`). It also blocks outbound SMTP → emails go through Brevo's HTTPS API. The server refuses to start on
  Render without `MASTER_KEY`, because a generated key would be lost on the next deploy and the data with it.
- **Web specifics.** Keyboard and right-click interactions, same-origin serving, a strict CSP (no inline scripts — the
  splash screen logic lives in `splash.js`), self-hosted CanvasKit (`--no-web-resources-cdn`).

---

## Setup & installation (developers)

### Backend

```bash
docker compose up -d --build                  # Postgres + Mailpit + API
cd backend && npm install && npm run smoke    # end-to-end API test suite against the running stack
```

`npm run smoke` covers registration, invitations, messaging and receipts, media, archive/mute, token rotation,
password reset, **groups** (invites, roles, leave, per-member unread), **search** and **polls**.

Configuration (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | local Postgres | Postgres connection string |
| `MASTER_KEY` | generated in the data volume | base64 32-byte master key (**required on Render**) |
| `MEDIA_STORAGE` | `fs` | `fs` = encrypted files on the data volume, `db` = encrypted blobs in Postgres |
| `WEB_DIR` | – | folder with the built web app to serve (set in the production image) |
| `BREVO_API_KEY` | – | send emails through Brevo's HTTPS API instead of SMTP |
| `MAIL_FROM` | `Messenger <no-reply@messenger.local>` | sender (must be verified in Brevo when using it) |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_SECURE` / `SMTP_USER` / `SMTP_PASS` | Mailpit | SMTP server |
| `ACCESS_TOKEN_TTL_SEC` / `REFRESH_TOKEN_TTL_DAYS` | `900` / `30` | session lifetimes |
| `DB_POOL_MAX` | `20` | Postgres connections |
| `LOG_EMAIL_CODES` | `true` | print verification codes in the log |

### Flutter app

Requirements: Flutter 3.50 (Dart 3.14).

```bash
cd app
flutter pub get
flutter run -d chrome --dart-define=API_URL=http://localhost:3000    # web against the local API
flutter build web --release --no-web-resources-cdn                   # → app/build/web
flutter build apk --release                                          # Android (emulator default: http://10.0.2.2:3000)
```

---

## Deployment

The live app runs on **Render** (free web service, Docker) with a free **Neon** Postgres database and **Brevo** for email.

1. Create a Postgres database (e.g. Neon) and copy its connection string (`…?sslmode=require`).
2. Create a Brevo account, verify a sender address and create an API key.
3. Generate a master key and **keep a copy**:
   `node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"`
4. Render → *New → Blueprint* → this repository (`render.yaml`) → fill in `DATABASE_URL`, `MASTER_KEY`,
   `BREVO_API_KEY`, `MAIL_FROM` → deploy. Every push to `main` redeploys.

The `Dockerfile` builds the web app with Flutter 3.50 (as a non-root user — Render's build sandbox does not allow
changing file owners), then copies it next to the API. Migrations run on start.

---

## API overview

All endpoints are JSON under `/api` and (except auth) need `Authorization: Bearer <accessToken>`.
Errors look like `{"error": {"code": "USERNAME_TAKEN", "message": "...", "field": "username"}}`.

| Area | Endpoints |
|---|---|
| Auth | `POST /auth/register`, `/auth/verify-email`, `/auth/resend-verification`, `/auth/login`, `/auth/refresh`, `/auth/logout`, `/auth/forgot-password`, `/auth/reset-password`, `GET /auth/availability` |
| Me | `GET/PATCH /me`, `PUT/DELETE /me/avatar`, `POST /me/password`, `POST /me/email`, `POST /me/email/confirm`, `POST /me/push-token` |
| Users | `GET /users/search?q=`, `GET /users/:id` |
| Invites (1:1 and group) | `GET /invites`, `POST /invites`, `POST /invites/:id/accept`, `POST /invites/:id/decline`, `DELETE /invites/:id` |
| Groups | `POST /groups`, `GET/PATCH /groups/:id`, `POST /groups/:id/invites`, `POST /groups/:id/leave`, `DELETE /groups/:id/members/:userId` |
| Chats | `GET /chats`, `GET/PATCH /chats/:id`, `GET/POST /chats/:id/messages`, `POST /chats/:id/read`, `GET /chats/:id/search?q=` |
| Messages | `PATCH /messages/:id`, `DELETE /messages/:id` |
| Polls | `POST /chats/:id/polls`, `PUT/DELETE /polls/:id/vote`, `POST /polls/:id/close` |
| Media | `POST /media` (multipart), `GET /media/:id?exp&sig` |

## Bonus features

- **Polls in group chats** — anonymous or public (chosen by the author), single or multiple answers, vote / change /
  retract, results with percentages, voters list for public polls, closing by the author, realtime updates,
  searchable questions. Anonymous polls don't even store voter ids.
- Desktop-grade web UX: keyboard shortcuts (Enter / Shift+Enter / Esc / Ctrl+F), right-click menus, unread count in the
  tab title, strict Content-Security-Policy, loading splash.
- Group roles (owner can rename / remove; ownership passes on), group events in the history, re-joining keeps history.
- From the mobile version: live username / email availability, change email & password, online / last-seen presence,
  swipe-to-archive with Undo, dark theme, idempotent sending with retry, demo bot and an end-to-end smoke test suite.

None of these change the required default behaviour: polls are only an extra item in the attachment menu of groups.

## Project structure

```
Dockerfile                production image: Flutter web build + API (used by Render)
render.yaml               Render blueprint
docker-compose.yml        local stack (Postgres, Mailpit, API, optional tunnel)
backend/
  src/                    Express app, routes (auth, me, users, invites, groups, chats, polls, media), crypto, realtime
  migrations/             SQL schema 001–005
  scripts/                smoke-test.js, demo-peer.js
app/
  lib/core/               API client, socket, chat navigation, session storage, notifications, validators
  lib/state/              auth, chats, invites, chat room, chat search controllers
  lib/screens/            auth, home (adaptive layout), chat (search, polls), groups, invites, search, profiles
  lib/widgets/            message bubble (highlighting), poll card, avatars, shared UI
  web/                    index.html, splash.js, manifest, icons
```
