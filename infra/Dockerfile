# Multi-stage build for the ezsync API + sync-worker (they share this one image and
# differ only in the CMD each runs). Build context is the REPO ROOT, not infra/:
#
#   docker build -f infra/Dockerfile -t ezsync-api .
#
# Targets the npm-workspaces monorepo settled in docs/decisions/architecture.md:
#   apps/api  (Express 5 + TS)   -> compiled to apps/api/dist
#   packages/db, packages/shared (TS libs the api imports) -> compiled to their dist/
#   apps/web (Next.js) is deployed separately and is intentionally NOT in this image.
#
# NOTE: this expects the scaffold (workspace package.json files, tsconfig, a root
# `build` script, and the src trees) to exist. It will not build until that phase
# lands; it is committed now as the source of truth for the image layout so the
# scaffold conforms to it. Node 22 matches .nvmrc / package.json engines.

# ---- Build stage: install all workspaces, compile TS, drop dev deps ----
FROM node:22-alpine AS build

WORKDIR /app

# Copy the lockfile + every workspace manifest first so `npm ci` is cached until a
# package.json actually changes (not on every source edit).
COPY package.json package-lock.json ./
COPY apps/api/package.json ./apps/api/
COPY packages/db/package.json ./packages/db/
COPY packages/shared/package.json ./packages/shared/

RUN npm ci

# Now the sources, then build shared -> db -> api (dependency order).
COPY . .
RUN npm run build --workspace @ezsync/shared \
                  --workspace @ezsync/db \
                  --workspace @ezsync/api

# Strip devDependencies so only production deps ship in the runtime image.
RUN npm prune --omit=dev

# ---- Runtime stage: production deps + compiled output only, non-root ----
FROM node:22-alpine AS runtime

# Tini for correct signal handling (graceful SIGTERM shutdown of the poll loop / server).
RUN apk add --no-cache tini \
  && addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app
ENV NODE_ENV=production

# Hoisted production node_modules from the build stage.
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json

# Compiled workspaces (+ their manifests so Node resolves the @ezsync/* packages).
COPY --from=build /app/packages/shared/dist ./packages/shared/dist
COPY --from=build /app/packages/shared/package.json ./packages/shared/package.json
COPY --from=build /app/packages/db/dist ./packages/db/dist
COPY --from=build /app/packages/db/package.json ./packages/db/package.json
COPY --from=build /app/packages/db/migrations ./packages/db/migrations
COPY --from=build /app/apps/api/dist ./apps/api/dist
COPY --from=build /app/apps/api/package.json ./apps/api/package.json

USER appuser

EXPOSE 3000

# Container-level healthcheck — hits the GET /health route the API exposes.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

# tini as PID 1; default command runs the API server. The `sync-worker` service in
# docker-compose.yml reuses this exact image and overrides the command with
# ["node", "apps/api/dist/worker/sync.js"].
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "apps/api/dist/index.js"]
