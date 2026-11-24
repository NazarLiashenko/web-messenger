# Production image: the Flutter web app + the Node.js API in one container (one URL, no CORS).
# Used by Render (render.yaml). Local development keeps using backend/Dockerfile via docker-compose.yml.
#
#   docker build -t messenger .
#   docker run -p 3000:3000 -e DATABASE_URL=... -e MASTER_KEY=... -e MEDIA_STORAGE=db messenger

# ---------- 1. Build the Flutter web app ----------
FROM debian:bookworm-slim AS web
ARG FLUTTER_VERSION=3.50.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Build as a normal user: as root, tar tries to keep the archive's file owners, which build sandboxes
# such as Render's refuse ("Cannot change ownership ... Invalid argument").
ENV TAR_OPTIONS=--no-same-owner
RUN useradd --create-home --uid 1000 builder && mkdir /opt/flutter && chown builder:builder /opt/flutter
USER builder
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter config --no-analytics --no-cli-animations >/dev/null && flutter precache --web

# Created by the builder user (a plain WORKDIR may be created as root and be read-only for the build).
RUN mkdir -p /home/builder/app
WORKDIR /home/builder/app
COPY --chown=builder:builder app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY --chown=builder:builder app/ ./
# No API_URL: the web build talks to the server it was loaded from.
# --no-web-resources-cdn: CanvasKit is served by us, not from gstatic.com (matches the CSP).
RUN flutter build web --release --no-web-resources-cdn --no-wasm-dry-run

# ---------- 2. API + static web ----------
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY backend/package.json backend/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY backend/src ./src
COPY backend/migrations ./migrations
COPY backend/scripts ./scripts
COPY --from=web /home/builder/app/build/web ./public
ENV WEB_DIR=/app/public \
    DATA_DIR=/data
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -qO- http://localhost:${PORT:-3000}/api/health || exit 1
CMD ["node", "src/index.js"]
