#!/usr/bin/env bash
# Self-service personal API keys end to end: one API pod (PROJECT_CODE=all) on a
# fresh Postgres. check.py drives the real API: a member mints a key and uses it
# on /kanban/my-tasks; scope, namespace and key-mints-key refusals; expiry;
# demotion and removal take effect on the next request; revoke; cross-workspace
# and cross-user denial; admin-minted keys unchanged; cap + rate limit; the
# zzak1 migration re-runs cleanly.
#
#   lapis/spec/api-keys-e2e/run.sh            # this checkout (uncommitted changes too)
#   KEEP=1 lapis/spec/api-keys-e2e/run.sh     # leave the stack up afterwards
#
# No real credentials (keys are minted at runtime). Needs the lapis-lapis and
# pgvector/pgvector:pg15 images, and python3.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/api-keys-e2e"
# Under $HOME: Docker Desktop/colima share it, not always macOS's /var/folders temp dir.
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/ak-e2e.XXXXXX"); NET=ak-e2e-$$; P=ak-$$
cleanup() { docker rm -f $P-api $P-pg >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/projects"
openssl rand -hex 32 > "$W/jwt_secret"
docker network create "$NET" >/dev/null
docker run -d --name $P-pg --network "$NET" --network-alias pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
until docker exec $P-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i $P-pg psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE ak OWNER pguser;
SQL
docker exec $P-pg psql -U postgres -d ak -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
# REDIS_ENABLED=false: the permission cache is off, so the e2e proves the DB
# path; the cache's busting on role change is covered by permission-cache_spec.
docker run -d --name $P-api --network "$NET" -p 127.0.0.1::80 -v "$ROOT/lapis:/app" -v "$W/projects:/app/projects" \
  -e POSTGRES_HOST=pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=ak \
  -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production \
  -e OPSAPI_DEPLOY_ENV=test -e REDIS_ENABLED=false \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  lapis-lapis >/dev/null
sleep 7
[ "$(docker inspect -f '{{.State.Running}}' $P-api)" = true ] || { docker logs $P-api 2>&1 | tail -40; exit 1; }
docker exec -w /app $P-api lapis migrate > "$W/migrate.log" 2>&1 || { tail -30 "$W/migrate.log"; exit 1; }
docker exec $P-api sh -c ': > /var/log/nginx/error.log'
docker restart $P-api >/dev/null
PORT=$(docker port $P-api 80/tcp | head -1 | sed 's/.*://')
until curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do sleep 1; done
rc=0
API="http://127.0.0.1:$PORT" PG_CONTAINER=$P-pg API_CONTAINER=$P-api JWT_SECRET_FILE="$W/jwt_secret" \
  python3 -I "$HERE/check.py" || rc=1
echo "== errors logged by the API during the run"
docker exec $P-api sh -c 'grep -E "\[error\]" /var/log/nginx/error.log | grep -v "context: ngx.timer" \
  | sed -E "s/^[0-9/]+ [0-9:]+ \[error\] [0-9]+#[0-9]+: (\*[0-9]+ )?//; s/, client: .*//" | cut -c1-220 \
  | sort | uniq -c | head -15' || true
if [ -n "${KEEP:-}" ]; then trap - EXIT; echo "kept: containers $P-*, network $NET, files $W"; fi
exit $rc
