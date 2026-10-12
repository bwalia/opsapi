#!/usr/bin/env bash
# Purchase orders end to end: one API pod (PROJECT_CODE=all, so Bookkeeping and
# CRM are on) on a fresh Postgres, plus an SMTP sink. check.py drives the real
# API: create -> lines -> email -> receive part -> bill part -> receive rest ->
# bill rest, close short, void a bill, rounding, concurrency, idempotency,
# metadata forgery, cross-workspace denial, and the zzpo6 data migration.
#
#   lapis/spec/purchase-orders-e2e/run.sh            # this checkout (uncommitted changes too)
#   KEEP=1 lapis/spec/purchase-orders-e2e/run.sh     # leave the stack up afterwards
#
# No real credentials. Needs the lapis-lapis, pgvector/pgvector:pg15 and
# python:3.12-alpine images, and python3. Reuses the forms e2e's SMTP sink.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/purchase-orders-e2e"
# Under $HOME: Docker Desktop/colima share it, not always macOS's /var/folders temp dir.
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/po-e2e.XXXXXX"); NET=po-e2e-$$; P=po-$$
cleanup() { docker rm -f $P-api $P-pg $P-smtp >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/projects" "$W/mail"
openssl rand -hex 32 > "$W/jwt_secret"
docker network create "$NET" >/dev/null
docker run -d --name $P-pg --network "$NET" --network-alias pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
docker run -d --name $P-smtp --network "$NET" --network-alias smtp -v "$W:/w" \
  -v "$ROOT/lapis/spec/forms-e2e/smtp_sink.py:/sink.py:ro" python:3.12-alpine python -I /sink.py >/dev/null
until docker exec $P-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i $P-pg psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE po OWNER pguser;
SQL
docker exec $P-pg psql -U postgres -d po -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
# Platform SMTP points at the sink too (it can't STARTTLS, so platform sends
# fail in the background: the API only promises "queued").
docker run -d --name $P-api --network "$NET" -p 127.0.0.1::80 -v "$ROOT/lapis:/app" -v "$W/projects:/app/projects" \
  -e POSTGRES_HOST=pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=po \
  -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production \
  -e OPSAPI_DEPLOY_ENV=test -e REDIS_ENABLED=false -e OPSAPI_MAIL_ALLOW_PRIVATE=true \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  -e SMTP_HOST=smtp -e SMTP_PORT=2525 -e SMTP_USER=platform -e SMTP_PASSWORD=platform \
  -e SMTP_FROM_EMAIL=noreply@platform.test lapis-lapis >/dev/null
sleep 7
[ "$(docker inspect -f '{{.State.Running}}' $P-api)" = true ] || { docker logs $P-api 2>&1 | tail -40; exit 1; }
docker exec -w /app $P-api lapis migrate > "$W/migrate.log" 2>&1 || { tail -30 "$W/migrate.log"; exit 1; }
docker exec $P-api sh -c ': > /var/log/nginx/error.log'
docker restart $P-api >/dev/null
PORT=$(docker port $P-api 80/tcp | head -1 | sed 's/.*://')
until curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do sleep 1; done
rc=0
API="http://127.0.0.1:$PORT" PG_CONTAINER=$P-pg API_CONTAINER=$P-api JWT_SECRET_FILE="$W/jwt_secret" \
  MAIL_DIR="$W/mail" python3 -I "$HERE/check.py" || rc=1
echo "== errors logged by the API during the run (platform mail timers can't STARTTLS to the sink: not shown)"
docker exec $P-api sh -c 'grep -E "\[error\]" /var/log/nginx/error.log | grep -v -e "\[Mail\]" -e "context: ngx.timer" \
  | sed -E "s/^[0-9/]+ [0-9:]+ \[error\] [0-9]+#[0-9]+: (\*[0-9]+ )?//; s/, client: .*//" | cut -c1-220 \
  | sort | uniq -c | head -15' || true
if [ -n "${KEEP:-}" ]; then trap - EXIT; echo "kept: containers $P-*, network $NET, files $W"; fi
exit $rc
