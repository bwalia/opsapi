#!/usr/bin/env bash
# Runs the SQL of the shop ops pack (purchase invoices, global search, latest deals) against a real, throwaway
# Postgres: check.lua builds a small schema with the columns these queries use, loads fixtures and calls the
# real Lua modules through a tiny lapis.db shim over pgmoon. Nothing touches any other database.
#   From the repo root:  bash lapis/spec/shop-ops-pack-e2e/run.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
NET=opsapi-ops-pack-e2e
PG=opsapi-ops-pack-pg
docker rm -f "$PG" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null
trap 'docker rm -f "$PG" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=test -e POSTGRES_HOST_AUTH_METHOD=trust postgres:15-alpine >/dev/null
for _ in $(seq 1 60); do docker exec "$PG" pg_isready -U postgres -d test >/dev/null 2>&1 && break; sleep 1; done
sleep 1
docker run --rm --network "$NET" -e PGHOST="$PG" -v "$PWD":/w -w /w bwalia/opsapi-base:latest luajit lapis/spec/shop-ops-pack-e2e/check.lua
