# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# OpsAPI Dashboard (Next.js, standalone output) — cache-optimised multi-stage.
#
# Speed comes from three things (all rely on BuildKit / buildx):
#   1. A dedicated `deps` stage that only re-runs `npm ci` when the lockfile
#      changes — with the CI registry cache, unchanged deps skip entirely.
#   2. A persistent npm cache mount (fast even on a cache miss).
#   3. A persistent Next.js build cache mount (incremental rebuilds).
# The runner is the Next standalone server run directly with `node` — no pm2
# (k8s already does restarts + scaling via the Deployment).
# ---------------------------------------------------------------------------

# 1) deps — install node_modules once, keyed on the lockfile only
FROM node:24.14-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# 2) builder — compile the app
FROM node:24.14-alpine AS builder
WORKDIR /app
ARG NEXT_PUBLIC_API_URL=http://127.0.0.1:4010
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_TELEMETRY_DISABLED=1 \
    NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Cache the Next.js compiler cache across builds for incremental speedups.
RUN --mount=type=cache,target=/app/.next/cache \
    npm run build

# 3) runner — minimal standalone image
FROM node:24.14-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=8039 \
    HOSTNAME=0.0.0.0

RUN addgroup -S -g 1001 nodejs && adduser -S -u 1001 nextjs

# Standalone output ships its own minimal node_modules + server.js.
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 8039

# k8s handles restarts/replicas; run the standalone server directly.
CMD ["node", "server.js"]
