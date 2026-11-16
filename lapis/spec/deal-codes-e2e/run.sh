#!/usr/bin/env bash
# Deal codes end to end: one API pod (PROJECT_CODE=all: shop, CRM and purchase orders) on a fresh Postgres 16,
# plus an SMTP sink. check.py drives the real API as a shop owner, a member without shop rights and the shop's
# BFF (the customer side): the backfill run twice on legacy rows (incl. a legacy drop-ship PO), public quote ->
# lead -> revision -> Order Authorisation -> bank transfer order -> paid, supplier POs (to us / drop-ship with
# and without the tick box), supplier price requests, the email draft, the compare table, search by every
# reference, linking by hand, and that no customer-facing page, PDF source or email carries the deal code while
# no supplier-facing PO, request or email carries the customer.
#
#   lapis/spec/deal-codes-e2e/run.sh                      # this checkout
#   API_IMAGE=bwalia/opsapi:latest lapis/spec/deal-codes-e2e/run.sh   # without a local lapis-lapis build
#   KEEP=1 lapis/spec/deal-codes-e2e/run.sh               # leave the stack up afterwards
#
# No real credentials. Needs the API image, pgvector/pgvector:pg16 (Postgres 16) and python:3.12-alpine, and python3.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/deal-codes-e2e"
API_IMAGE=${API_IMAGE:-lapis-lapis}
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/deal-e2e.XXXXXX"); NET=deal-e2e-$$; P=deal-$$
cleanup() { docker rm -f $P-api $P-pg $P-smtp >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/projects" "$W/mail"
openssl rand -hex 32 > "$W/jwt_secret"
BFF_KEY=$(openssl rand -hex 16)
docker network create "$NET" >/dev/null
docker run -d --name $P-pg --network "$NET" --network-alias pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg16 >/dev/null
docker run -d --name $P-smtp --network "$NET" --network-alias smtp -v "$W:/w" \
  -v "$ROOT/lapis/spec/forms-e2e/smtp_sink.py:/sink.py:ro" python:3.12-alpine python -I /sink.py >/dev/null
until docker exec $P-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i $P-pg psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE deal OWNER pguser;
SQL
docker exec $P-pg psql -U postgres -d deal -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
docker run -d --name $P-api --network "$NET" -p 127.0.0.1::80 -v "$ROOT/lapis:/app" -v "$W/projects:/app/projects" \
  -e POSTGRES_HOST=pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=deal \
  -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production \
  -e OPSAPI_DEPLOY_ENV=test -e REDIS_ENABLED=false -e OPSAPI_MAIL_ALLOW_PRIVATE=true \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  -e SHOP_BFF_KEY="$BFF_KEY" -e SHOP_PUBLIC_URL=http://shop.invalid -e SHOP_ALLOWED_ORIGINS=http://shop.invalid \
  -e SMTP_HOST=smtp -e SMTP_PORT=2525 -e SMTP_USER=platform -e SMTP_PASSWORD=platform \
  -e SMTP_FROM_EMAIL=noreply@platform.test "$API_IMAGE" >/dev/null
sleep 7
[ "$(docker inspect -f '{{.State.Running}}' $P-api)" = true ] || { docker logs $P-api 2>&1 | tail -40; exit 1; }
docker exec -w /app $P-api lapis migrate > "$W/migrate.log" 2>&1 || { tail -40 "$W/migrate.log"; exit 1; }
grep -E 'ShopDealCodes|zzs5[5-7]' "$W/migrate.log" | head -5 || true
docker exec $P-api sh -c ': > /var/log/nginx/error.log' || true
docker restart $P-api >/dev/null
PORT=$(docker port $P-api 80/tcp | head -1 | sed 's/.*://')
until curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do sleep 1; done
rc=0
API="http://127.0.0.1:$PORT" PG_CONTAINER=$P-pg API_CONTAINER=$P-api JWT_SECRET_FILE="$W/jwt_secret" \
  MAIL_DIR="$W/mail" BFF_KEY="$BFF_KEY" python3 -I "$HERE/check.py" || rc=1
echo "== errors logged by the API during the run (mail timers to the sink not shown)"
docker exec $P-api sh -c 'grep -E "\[error\]" /var/log/nginx/error.log | grep -v -e "\[Mail\]" -e "context: ngx.timer" \
  | sed -E "s/^[0-9/]+ [0-9:]+ \[error\] [0-9]+#[0-9]+: (\*[0-9]+ )?//; s/, client: .*//" | cut -c1-220 \
  | sort | uniq -c | head -15' || true
if [ -n "${KEEP:-}" ]; then trap - EXIT; echo "kept: containers $P-*, network $NET, files $W"; fi
exit $rc
