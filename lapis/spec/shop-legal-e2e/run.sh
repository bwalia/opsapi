#!/usr/bin/env bash
# Shop legal record + survey end to end: one API pod (PROJECT_CODE=all) on a fresh Postgres with every
# migration run for real. check.py drives the shop server's (BFF) routes with a throwaway X-Shop-Key, the
# public contact form, and the back office as the owner, a shop clerk and another workspace's owner:
# only signed-in ("register") acceptances count, a typed email can't accept for someone else, erasure is
# shop.delete only and audited without the email, the survey funnel/report/CSV and survey → CRM lead.
#
#   lapis/spec/shop-legal-e2e/run.sh          # this checkout (uncommitted changes too)
#   KEEP=1 lapis/spec/shop-legal-e2e/run.sh   # leave the stack up afterwards
#
# No real credentials. Needs the lapis-lapis and pgvector/pgvector:pg15 images, and python3.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/shop-legal-e2e"
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/shop-legal-e2e.XXXXXX"); NET=sl-e2e-$$; P=sl-$$
cleanup() { docker rm -f $P-api $P-pg >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/projects"
openssl rand -hex 32 > "$W/jwt_secret"; openssl rand -hex 24 > "$W/bff_key"
docker network create "$NET" >/dev/null
docker run -d --name $P-pg --network "$NET" --network-alias pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
until docker exec $P-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i $P-pg psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE sl OWNER pguser;
SQL
docker exec $P-pg psql -U postgres -d sl -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
docker run -d --name $P-api --network "$NET" -p 127.0.0.1::80 -v "$ROOT/lapis:/app" -v "$W/projects:/app/projects" \
  -e POSTGRES_HOST=pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=sl -e SHOP_BFF_KEY="$(cat "$W/bff_key")" \
  -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production \
  -e OPSAPI_DEPLOY_ENV=test -e REDIS_ENABLED=false \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  lapis-lapis >/dev/null
sleep 7
[ "$(docker inspect -f '{{.State.Running}}' $P-api)" = true ] || { docker logs $P-api 2>&1 | tail -40; exit 1; }
docker exec -w /app $P-api lapis migrate > "$W/migrate.log" 2>&1 || { tail -30 "$W/migrate.log"; exit 1; }
grep -E "zzs3[78]" "$W/migrate.log" | head -10 || true
docker exec $P-api sh -c ': > /var/log/nginx/error.log'
docker restart $P-api >/dev/null
PORT=$(docker port $P-api 80/tcp | head -1 | sed 's/.*://')
until curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do sleep 1; done
rc=0
API="http://127.0.0.1:$PORT" PG_CONTAINER=$P-pg API_CONTAINER=$P-api JWT_SECRET_FILE="$W/jwt_secret" BFF_KEY_FILE="$W/bff_key" \
  python3 -I "$HERE/check.py" || rc=1
echo "== errors logged by the API during the run"
docker exec $P-api sh -c 'grep -E "\[error\]" /var/log/nginx/error.log | grep -v -e "\[Mail\]" -e "context: ngx.timer" \
  | sed -E "s/^[0-9/]+ [0-9:]+ \[error\] [0-9]+#[0-9]+: (\*[0-9]+ )?//; s/, client: .*//" | cut -c1-260 \
  | sort | uniq -c | head -15' || true
if [ -n "${KEEP:-}" ]; then trap - EXIT; echo "kept: containers $P-*, network $NET, files $W (API port $PORT)"; fi
exit $rc
