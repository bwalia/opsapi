#!/usr/bin/env bash
# Supplier portal end to end: one API pod (PROJECT_CODE=all: shop, purchase orders, CRM) on a fresh Postgres 16,
# MinIO for the private documents and an SMTP sink (the mail catcher). check.py replays a real purchase with made-up
# sample PDFs: staff create PO-000001 for 1 x NVIDIA DGX Spark (GBP 5,256.65 + VAT 1,051.33 = 6,307.98) and send it,
# the supplier's portal login acknowledges it and uploads the proforma (PRF-...-012 sample), staff record the Faster
# Payment with the bank's confirmation, the supplier downloads that proof, enters the dispatch and tracking, marks it
# delivered with a proof of delivery and uploads the final VAT invoice, and staff close the PO. Along the way: supplier
# A can't reach supplier B's POs, documents or payments (every id-taking route), supplier logins can't use staff
# routes, no customer details reach the supplier, links expire, upload type/size checks, wrong stage moves, the
# balance maths - and the mail catcher stays empty while supplier emails are off.
#
#   lapis/spec/supplier-portal-e2e/run.sh                         # this checkout, bwalia/opsapi:latest as the runtime
#   API_IMAGE=lapis-lapis lapis/spec/supplier-portal-e2e/run.sh   # a local build
#   KEEP=1 lapis/spec/supplier-portal-e2e/run.sh                  # leave the stack up afterwards
#
# No real credentials and no real documents. Needs docker (pgvector/pgvector:pg16, minio/minio, python:3.12-alpine,
# the API image) and python3.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/supplier-portal-e2e"
API_IMAGE=${API_IMAGE:-bwalia/opsapi:latest}
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/sp-e2e.XXXXXX"); NET=sp-e2e-$$; P=sp-$$
cleanup() { docker rm -f $P-api $P-pg $P-smtp $P-minio >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/projects" "$W/mail"
openssl rand -hex 32 > "$W/jwt_secret"
MINIO_PW=$(openssl rand -hex 12)
docker network create "$NET" >/dev/null
docker run -d --name $P-pg --network "$NET" --network-alias pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg16 >/dev/null
docker run -d --name $P-minio --network "$NET" --network-alias minio -e MINIO_ROOT_USER=e2eadmin \
  -e MINIO_ROOT_PASSWORD="$MINIO_PW" minio/minio:latest server /data >/dev/null
docker run -d --name $P-smtp --network "$NET" --network-alias smtp -v "$W:/w" \
  -v "$ROOT/lapis/spec/forms-e2e/smtp_sink.py:/sink.py:ro" python:3.12-alpine python -I /sink.py >/dev/null
until docker exec $P-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i $P-pg psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE sp OWNER pguser;
SQL
docker exec $P-pg psql -U postgres -d sp -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
docker run -d --name $P-api --network "$NET" -p 127.0.0.1::80 -v "$ROOT/lapis:/app" -v "$W/projects:/app/projects" \
  -e POSTGRES_HOST=pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=sp \
  -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production \
  -e OPSAPI_DEPLOY_ENV=test -e REDIS_ENABLED=false -e OPSAPI_MAIL_ALLOW_PRIVATE=true \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  -e MINIO_ENDPOINT=http://minio:9000 -e MINIO_ACCESS_KEY=e2eadmin -e MINIO_SECRET_KEY="$MINIO_PW" \
  -e MINIO_BUCKET=opsapi-e2e -e SUPPLIER_PORTAL_BUCKET=supplier-portal-private -e MINIO_REGION=us-east-1 \
  -e SMTP_HOST=smtp -e SMTP_PORT=2525 -e SMTP_USER=platform -e SMTP_PASSWORD=platform \
  -e SMTP_FROM_EMAIL=noreply@platform.test -e FRONTEND_URL=http://dashboard.invalid "$API_IMAGE" >/dev/null
sleep 7
[ "$(docker inspect -f '{{.State.Running}}' $P-api)" = true ] || { docker logs $P-api 2>&1 | tail -40; exit 1; }
docker exec -w /app $P-api lapis migrate > "$W/migrate.log" 2>&1 || { tail -40 "$W/migrate.log"; exit 1; }
grep -E 'SupplierPortal|zzs6[01]' "$W/migrate.log" | head -5 || true
docker exec -w /app $P-api lapis migrate > "$W/migrate2.log" 2>&1 || { echo "second migrate failed"; tail -20 "$W/migrate2.log"; exit 1; }
echo "  migrations ran twice (idempotent)"
docker exec $P-api sh -c ': > /var/log/nginx/error.log' || true
docker restart $P-api >/dev/null
PORT=$(docker port $P-api 80/tcp | head -1 | sed 's/.*://')
until curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do sleep 1; done
rc=0
API="http://127.0.0.1:$PORT" PG_CONTAINER=$P-pg API_CONTAINER=$P-api JWT_SECRET_FILE="$W/jwt_secret" \
  MAIL_DIR="$W/mail" python3 -I "$HERE/check.py" || rc=1
echo "== errors logged by the API during the run (mail timers to the sink not shown)"
docker exec $P-api sh -c 'grep -E "\[error\]" /var/log/nginx/error.log | grep -v -e "\[Mail\]" -e "context: ngx.timer" \
  | sed -E "s/^[0-9/]+ [0-9:]+ \[error\] [0-9]+#[0-9]+: (\*[0-9]+ )?//; s/, client: .*//" | cut -c1-220 \
  | sort | uniq -c | head -15' || true
if [ -n "${KEEP:-}" ]; then trap - EXIT; echo "kept: containers $P-*, network $NET, files $W"; fi
exit $rc
