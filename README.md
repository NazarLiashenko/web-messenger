# Mobile Messenger 📲

A full-stack messenger: a **Flutter** app (Android / iOS, web-ready) and a **Node.js** backend with
**PostgreSQL**, realtime **WebSockets** and **encryption at rest** for all sensitive data.

<p>
Registration with email verification · password recovery · persistent sessions · profiles with photos ·
user search · chat invitations · text / photo / video / voice messages · sent / delivered / read receipts ·
edit & delete · typing indicators · archive · mute · notifications
</p>

---

## Contents

- [Reviewer Guide (quick start)](#reviewer-guide-quick-start)
- [Features](#features)
- [Architecture](#architecture)
- [Data encryption](#data-encryption)
- [Setup & installation (developers)](#setup--installation-developers)
- [Usage guide](#usage-guide)
- [Push notifications (optional Firebase)](#push-notifications-optional-firebase)
- [API overview](#api-overview)
- [Bonus features](#bonus-features)
- [Project structure](#project-structure)

---

## Reviewer Guide (quick start)

You need **Docker** (Docker Desktop on Windows/macOS) — nothing else. No Node, Flutter or Android Studio.

### 1. Start the backend — one command

```bash
docker compose up -d --build
```

| What | Where |
|---|---|
| API + WebSocket | `http://localhost:3000` (health check: `/api/health`) |
| **Mailbox** — all verification / password-reset emails land here | **http://localhost:8025** |

Everything (database, mail server, encryption keys) is created automatically on the first start.
Stop with `docker compose down` (add `-v` to wipe all data).

> Verification codes are also printed in the backend log: `docker compose logs api | grep code`.

### 2. Get the APK

Download **`messenger.apk`** from the
[Releases page](https://gitea.kood.tech/nazarliashenko/mobile-messenger/releases) of this repository
(the APK is ~55 MB, so it is not committed to git).

### 3. Point the app at your backend

The app talks to the server URL shown under the **server icon (top-right of the login screen)**.
Tap it, enter the URL, press **Test**, then **Save**.

| Where the app runs | Server URL to enter |
|---|---|
| Android Studio emulator (AVD) | `http://10.0.2.2:3000` *(default — nothing to change)* |
| BlueStacks / NoxPlayer on the same PC | `http://<your PC's LAN IP>:3000` (e.g. `http://192.168.1.20:3000`) |
| Physical phone on the same Wi-Fi | `http://<your PC's LAN IP>:3000` |
| appetize.io or a phone outside your network | the public tunnel URL (see below) |

Find your LAN IP with `ipconfig` (Windows) or `ip addr` / `ifconfig` (Linux / macOS).
If the phone can't connect, allow port 3000 through the PC firewall.

**Public URL (for appetize.io / remote devices)** — start the backend with the built-in Cloudflare tunnel:

```bash
docker compose --profile tunnel up -d --build
docker compose logs tunnel | grep trycloudflare      # → https://something-random.trycloudflare.com
```

Use that `https://….trycloudflare.com` address as the server URL in the app.

### Option A — Install on an Android device

1. Copy `messenger.apk` to the phone (USB, cloud drive, or download it on the phone).
2. Open it and allow *Install unknown apps* when Android asks.
3. Open **Messenger** → server icon → enter `http://<PC LAN IP>:3000` → **Save**.

### Option B — Lightweight emulator (BlueStacks / NoxPlayer)

1. Install BlueStacks (https://www.bluestacks.com) or NoxPlayer (https://www.bignox.com).
2. Drag & drop `messenger.apk` onto the emulator window (or use its *Install APK* button).
3. Open **Messenger** → server icon → `http://<PC LAN IP>:3000` → **Save**.
   (These emulators don't support `10.0.2.2`; use the PC's LAN IP.)

### Option C — Browser-based emulator (appetize.io)

1. Start the backend **with the tunnel** (see above) and copy the `https://….trycloudflare.com` URL.
2. Go to https://appetize.io/upload, upload `messenger.apk`, open the generated link.
3. In the app: server icon → paste the tunnel URL → **Test** → **Save**.

### Trying it alone — a scripted second user

Chatting needs two people. A demo user **dave** can play the other side: it accepts invites,
shows "typing…", reads your messages and replies automatically.

```bash
docker compose exec api node scripts/demo-peer.js <your-username>
```

It registers `dave` (password `Demo!pass1`), sends *you* a chat invitation and keeps running.
Alternatively register a second account on another emulator / device.

> **Tip for old Android Studio emulator images:** the system file picker (DocumentsUI) on some AVDs ignores
> taps on files. Use its 🔍 search or the keyboard (Tab / arrows / Enter) to pick a photo or video. Real devices,
> BlueStacks and appetize are not affected. Test media can be pushed with `adb push file.mp4 /sdcard/Movies/`.

### Suggested review path

1. **Sign up** – try a weak password (live checklist, button disabled), an existing email/username (inline error).
2. Open **http://localhost:8025**, read the code, **verify** the email.
3. Close & reopen the app → you are still logged in.
4. **Profile** tab → set a photo (JPEG/PNG ≤ 5 MB) and *About me*; default picture is shown until then.
5. **Invites** tab → accept dave's invitation (or search a user and **Invite**).
6. Chat: send text, photo, video, voice; watch ✓ sent → ✓✓ delivered → blue ✓✓ read; see "typing…".
7. Long-press your message → **Edit** / **Delete**.
8. Long-press / swipe a chat → **Archive**, **Mute**. Archived chats sit under *Archived chats*.
9. Stop the server (`docker compose stop api`) and send something → "Connecting…" banner, red ⚠ *Not sent*;
   start it again (`docker compose start api`) → the message is delivered automatically.
10. *Forgot password?* on the login screen → code by email → new password.

---

## Features

### Registration & authentication
- Sign up with **email, username, password**; log in with email + password.
- Duplicate **email / username** rejected (checked live while typing and again on submit, inline error under the field).
- **Password strength** (≥ 8 chars, lower, upper, digit, special) — live checklist + strength bar on the client, enforced again on the server.
- **Email verification** with a 6-digit code (15 min validity, 5 attempts, resend with cooldown).
- **Password recovery** by email code; a reset logs out every device.
- **Persistent session**: short-lived JWT access token (15 min) + rotating refresh token (30 days, sliding)
  kept in the platform keystore (Android Keystore / iOS Keychain). The user stays logged in until they log out
  or the session expires/is revoked — then they're sent to the login screen with a message.

### Profile
- Profile picture, username, About me (+ email, password). First login shows a **default picture** and empty About me.
- Profile picture: **JPEG and PNG**, up to **5 MB** (validated by magic bytes on the server, size on both sides).
- Everything is editable: photo (gallery / camera / remove), username, About me, email (re-verified by code), password.
- Profile changes propagate to contacts in real time.

### Search & invitations
- Search by **username prefix** or **exact email** (case-insensitive) — works on encrypted data via blind indexes.
- Send / accept / decline / cancel **chat invitations**; list of **pending** invitations (received & sent) with a badge.
- No invite needed when the person is already in your chat list (button becomes **Message**). If they invited you
  already, "Invite" accepts their invitation.

### Chat list
- Sorted by time of the last sent/received message; shows last message preview, its status, unread count,
  online dot, typing indicator, muted icon.
- **Archive / unarchive** (swipe or long-press, with *Undo*), **mute** notifications per chat.

### Messaging
- **Text, images, videos, voice messages** (record with the microphone, play inline with seek).
- Images are resized & re-compressed on the device; videos are **transcoded on the device** (H.264, 960×540) —
  e.g. a 15.5 MB 1080p clip becomes ~2.7 MB. The **20 MB limit** applies after compression
  (checked on the client and enforced by the server). Videos get a preview frame and duration.
- **Status indicators**: 🕓 sending → ✓ sent → ✓✓ delivered → blue ✓✓ read, and red ⚠ **failed** with *tap to retry*.
  Sending is idempotent (client-generated id), so retries never duplicate messages.
- **Edit** and **delete** your own messages (for everyone; "edited" label / "This message was deleted").
- **Typing indicators**, online status & "last seen".
- Paginated history (infinite scroll), day separators, full-screen image viewer and video player.

### Notifications
- New messages and invitations raise **system notifications** while the app is in the background;
  tapping opens the right chat / the invitations tab. Muted chats stay silent.
- Optional **FCM push** for when the app is fully closed (see below).

### Error handling
- Every API error has a stable code and a human-readable message shown as inline field errors or snackbars.
- Network loss → "Connecting…" banner, automatic reconnect & resync (missed messages, statuses, invites).
- Optimistic UI with rollback: failed edits, archive/mute toggles revert to the last stable state; unsent
  messages stay in the chat marked as failed and are **re-sent automatically when the connection returns**
  (or manually with *tap to retry*).
- Offline start: the chat list and the last 50 messages of each chat are cached on the device (encrypted by the
  platform keystore), so the app opens to the last known state even when the server is unreachable.
- Expired access tokens are refreshed transparently (single-flight); an expired session leads back to login.

---

## Architecture

```
┌──────────────────────────┐        REST (JSON, multipart)        ┌──────────────────────────────┐
│ Flutter app              │ ───────────────────────────────────▶ │ Node.js 22 · Express 5        │
│  provider (state)        │ ◀── Socket.IO (realtime events) ───▶ │ Socket.IO · zod validation    │
│  dio · socket_io_client  │                                       │ AES-256-GCM encryption layer  │
│  secure storage (tokens) │                                       └──────┬───────────┬────────────┘
└──────────────────────────┘                                              │           │
                                                               PostgreSQL 17     encrypted media files
                                                               (encrypted cols)  (Docker volume)
                                                                          │
                                                                    SMTP → Mailpit (dev) / any SMTP
```

- **Backend** (`backend/`): stateless REST API + Socket.IO. Postgres for data, encrypted files on a volume for
  media. Migrations run automatically on start.
- **Realtime**: server → client events `message:new`, `message:updated`, `message:status`, `typing`, `presence`,
  `chat:new|updated`, `invite:new|updated`, `user:updated`; client → server `typing`, `message:delivered`.
- **Delivery receipts**: *delivered* when the recipient's device receives the message (socket ack, or when it
  fetches the chat list after being offline); *read* when the chat is open on screen.
- **App** (`app/`): `core/` (API client, socket, notifications, config), `state/` (ChangeNotifier controllers),
  `screens/`, `widgets/`. Platform-specific code is isolated so the same codebase builds for **web**
  (the planned web version will reuse the API and this code).

## Data encryption

All sensitive data is encrypted **before** it is written to the database or disk:

| Data | Storage |
|---|---|
| Email, username, About me | AES-256-GCM ciphertext (`*_enc` columns) |
| Message text and metadata | AES-256-GCM |
| Photos, videos, voice messages, profile pictures | AES-256-GCM encrypted files |
| Contacts / chat list (chat membership, invitation parties, message senders) | user ids stored encrypted; lookups use HMAC-SHA256 **blind indexes**, so the database alone does not reveal who talks to whom |
| Push tokens, device names | AES-256-GCM |
| On-device cache (tokens, chat list, recent messages) | Android Keystore / iOS Keychain (flutter_secure_storage), wiped on logout |
| Passwords | scrypt (salted, memory-hard) — hashed, never encrypted |
| Refresh tokens, email codes | SHA-256 / HMAC hashes only |

- Independent sub-keys (encryption, file encryption, blind index, URL signing, JWT) are derived from one
  256-bit **master key** with HKDF-SHA256. Every value gets a random 96-bit IV and an authentication tag.
- The master key comes from `MASTER_KEY` (base64, 32 bytes) or is generated on first start and stored in the
  `api-data` volume (`/data/master.key`). **Back it up** — without it the data can't be decrypted.
- Media is served through **signed, expiring URLs** and decrypted on the fly (with HTTP Range support for seeking).
- Search works on encrypted data: exact email via a blind index, username via blind-indexed prefixes.

Check it yourself:

```bash
docker compose exec db psql -U messenger -c "SELECT username_enc, about_enc FROM users LIMIT 3;"
docker compose exec db psql -U messenger -c "SELECT type, body_enc FROM messages LIMIT 3;"
```

---

## Setup & installation (developers)

### Backend

```bash
docker compose up -d --build            # Postgres + Mailpit + API
cd backend && npm install && npm run smoke   # end-to-end API test suite against the running stack
```

Without Docker for the API itself (Postgres still required):

```bash
cd backend
npm install
DATABASE_URL=postgres://messenger:messenger@localhost:5432/messenger npm start
```

Configuration (environment variables, all optional):

| Variable | Default | Meaning |
|---|---|---|
| `MASTER_KEY` | generated | base64 32-byte master encryption key |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_SECURE` / `SMTP_USER` / `SMTP_PASS` | Mailpit | real SMTP (e.g. Gmail app password) |
| `MAIL_FROM` | `Messenger <no-reply@messenger.local>` | sender address |
| `ACCESS_TOKEN_TTL_SEC` | `900` | access token lifetime |
| `REFRESH_TOKEN_TTL_DAYS` | `30` | session lifetime (sliding) |
| `FIREBASE_SERVICE_ACCOUNT` | `/data/firebase-service-account.json` | enables FCM push |
| `LOG_EMAIL_CODES` | `true` | print verification codes in the log |

To send real emails, put the SMTP settings in a `.env` file next to `docker-compose.yml` (see `.env.example`).

### Flutter app

Requirements: Flutter 3.50+ (Dart 3.14), Android SDK 37.

```bash
cd app
flutter pub get
flutter run                                         # emulator uses http://10.0.2.2:3000 by default
flutter build apk --release                         # → build/app/outputs/flutter-apk/app-release.apk
flutter build apk --release --dart-define=API_URL=https://my-server.example.com   # bake in a server URL
```

iOS: `flutter build ios` (permissions for camera, microphone and photos are already declared in `Info.plist`).

---

## Usage guide

| Task | How |
|---|---|
| Create an account | Login screen → **Sign up** → enter the 6-digit code from the email |
| Reset the password | Login screen → **Forgot password?** |
| Change the server | Server icon in the top-right corner of the login screens |
| Find people | Chats → 🔍 (or the ✏️ button) → type a username or an email |
| Invite / accept | Search result → **Invite**; incoming invites are in the **Invites** tab |
| Send media | 📎 → photo / video (gallery or camera); 🎤 → record → ➤ (🗑 cancels) |
| Edit / delete / copy | Long-press your message |
| Retry a failed message | Tap it → **Retry** (or **Remove**) |
| Archive / mute | Swipe a chat left, long-press it, or use ⋮ inside the chat |
| Edit profile | **Profile** tab → tap the photo / any field |
| Log out | Profile → **Log out** |

## Push notifications (optional Firebase)

Out of the box, notifications are delivered over the realtime connection while the app process is alive
(foreground or background). For push while the app is **closed**, enable Firebase Cloud Messaging:

1. Create a Firebase project, add an Android app with package `com.nazarliashenko.messenger`.
2. Backend: download a service-account JSON and copy it into the API volume:
   `docker compose cp firebase.json api:/data/firebase-service-account.json && docker compose restart api`
3. App: build with your Firebase web/app config:

   ```bash
   flutter build apk --release \
     --dart-define=FIREBASE_API_KEY=... --dart-define=FIREBASE_APP_ID=... \
     --dart-define=FIREBASE_SENDER_ID=... --dart-define=FIREBASE_PROJECT_ID=...
   ```

The server then sends FCM pushes for new messages (unless the chat is muted) and invitations to users who are offline.

## API overview

All endpoints are JSON under `/api` and (except auth) need `Authorization: Bearer <accessToken>`.
Errors look like `{"error": {"code": "USERNAME_TAKEN", "message": "...", "field": "username"}}`.

| Area | Endpoints |
|---|---|
| Auth | `POST /auth/register`, `/auth/verify-email`, `/auth/resend-verification`, `/auth/login`, `/auth/refresh`, `/auth/logout`, `/auth/forgot-password`, `/auth/reset-password`, `GET /auth/availability` |
| Me | `GET/PATCH /me`, `PUT/DELETE /me/avatar`, `POST /me/password`, `POST /me/email`, `POST /me/email/confirm`, `POST /me/push-token` |
| Users | `GET /users/search?q=`, `GET /users/:id` |
| Invites | `GET /invites`, `POST /invites`, `POST /invites/:id/accept`, `POST /invites/:id/decline`, `DELETE /invites/:id` |
| Chats | `GET /chats`, `GET/PATCH /chats/:id`, `GET/POST /chats/:id/messages`, `POST /chats/:id/read` |
| Messages | `PATCH /messages/:id`, `DELETE /messages/:id` |
| Media | `POST /media` (multipart, `kind=image|video|audio`), `GET /media/:id?exp&sig` |

## Bonus features

- Live username / email availability check during sign-up.
- Change email (verified by a code to the new address) and change password (logs out other devices).
- Online / last-seen presence.
- Swipe-to-archive with Undo; unread counters and badges.
- Dark theme (follows the system).
- Idempotent message sending with retry; optimistic UI with rollback.
- Built-in public tunnel (`--profile tunnel`) for remote testing.
- Demo peer bot (`scripts/demo-peer.js`) and an end-to-end API smoke test (`npm run smoke`).
- Rate limiting on auth endpoints.

None of these change the required default behaviour.

## Project structure

```
docker-compose.yml        backend stack (db, mail, api, optional tunnel)
backend/
  src/                    Express app, routes, services, crypto, realtime, push
  migrations/             SQL schema
  scripts/                smoke-test.js, demo-peer.js
app/
  lib/core/               API client, socket, session storage, notifications, push, validators
  lib/state/              auth, chats, invites, chat room controllers
  lib/screens/            auth, home / chat list, chat, search, invites, profiles, media viewer
  lib/widgets/            message bubble, audio player, avatar, shared UI
```
