#!/usr/bin/env bash
# My tasks end to end: one API pod (PROJECT_CODE=all) on a fresh Postgres.
# check.py seeds two workspaces with projects, tasks and assignees, then drives
# GET /api/v2/kanban/my-tasks (every due value against a fixed date, priority /
# status / project / search filters, order, item fields, 400s, paging cap,
# workspace + user isolation), the assistant's list_my_tasks on the real DB and
# the My Tasks menu migration (re-run, idempotent).
#
#   lapis/spec/my-tasks-e2e/run.sh            # this checkout (uncommitted changes too)
#   KEEP=1 lapis/spec/my-tasks-e2e/run.sh     # leave the stack up afterwards
#
# No real credentials. Needs the lapis-lapis and pgvector/pgvector:pg15 images, and python3.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/my-tasks-e2e"
# Under $HOME: Docker Desktop/colima share it, not always macOS's /var/folders temp dir.
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/mt-e2e.XXXXXX"); NET=mt-e2e-$$; P=mt-$$
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
CREATE DATABASE mt OWNER pguser;
SQL
docker exec $P-pg psql -U postgres -d mt -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
docker run -d --name $P-api --network "$NET" -p 127.0.0.1::80 -v "$ROOT/lapis:/app" -v "$W/projects:/app/projects" \
  -e POSTGRES_HOST=pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=mt \
  -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production \
  -e OPSAPI_DEPLOY_ENV=test -e REDIS_ENABLED=false \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" lapis-lapis >/dev/null
sleep 7
[ "$(docker inspect -f '{{.State.Running}}' $P-api)" = true ] || { docker logs $P-api 2>&1 | tail -40; exit 1; }
# Twice: the second run must be a clean no-op.
for i in 1 2; do
  docker exec -w /app $P-api lapis migrate > "$W/migrate$i.log" 2>&1 || { tail -30 "$W/migrate$i.log"; exit 1; }
done
grep -q "Registered the My Tasks menu item" "$W/migrate1.log" || { echo "FAIL zzmt1 did not run"; exit 1; }
! grep -q "Registered the My Tasks menu item" "$W/migrate2.log" || { echo "FAIL zzmt1 ran twice"; exit 1; }
docker exec $P-api sh -c ': > /var/log/nginx/error.log'
docker restart $P-api >/dev/null
PORT=$(docker port $P-api 80/tcp | head -1 | sed 's/.*://')
until curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do sleep 1; done
rc=0
API="http://127.0.0.1:$PORT" PG_CONTAINER=$P-pg API_CONTAINER=$P-api JWT_SECRET_FILE="$W/jwt_secret" \
  python3 -I "$HERE/check.py" || rc=1
echo "== errors logged by the API during the run"
docker exec $P-api sh -c 'grep -E "\[error\]" /var/log/nginx/error.log \
  | sed -E "s/^[0-9/]+ [0-9:]+ \[error\] [0-9]+#[0-9]+: (\*[0-9]+ )?//; s/, client: .*//" | cut -c1-220 \
  | sort | uniq -c | head -15' || true
if [ -n "${KEEP:-}" ]; then trap - EXIT; echo "kept: containers $P-*, network $NET, files $W"; fi
exit $rc
