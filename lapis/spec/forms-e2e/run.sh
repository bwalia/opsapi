#!/usr/bin/env bash
# Forms end to end: two API pods (a, b) on one Postgres + Redis, a pod without
# the forms feature (c), and an SMTP sink. check.py builds, publishes and fills
# in forms, then checks the records, links, emails, isolation, limits,
# concurrency, invitations and the agent tools (docs/FORM_BUILDER_PLAN.md §16).
#
#   lapis/spec/forms-e2e/run.sh              # this checkout (HEAD + uncommitted changes)
#   lapis/spec/forms-e2e/run.sh origin/main  # the same checks against main (fails: no forms there)
#
# Fresh database, no real credentials. Needs the lapis-lapis,
# pgvector/pgvector:pg15, redis:7-alpine, python:3.12-alpine and quay.io/minio/minio
# images, and python3. stubs.py stands in for the AI model and Cloudflare Turnstile.
set -euo pipefail
REF=${1:-}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/forms-e2e"
W=$(mktemp -d); NET=forms-e2e-$$; P=forms-$$
cleanup() { docker rm -f $P-a $P-b $P-c $P-pg $P-redis $P-smtp $P-stubs $P-minio >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [ -n "$REF" ] && git -C "$ROOT" worktree remove --force "$W/src" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
if [ -n "$REF" ]; then git -C "$ROOT" worktree add -q --detach "$W/src" "$REF"; SRC="$W/src/lapis"; else SRC="$ROOT/lapis"; fi
mkdir -p "$W/projects" "$W/mail"
openssl rand -hex 32 > "$W/jwt_secret"; openssl rand -hex 16 > "$W/enc_key"; openssl rand -hex 8 > "$W/enc_iv"
docker network create "$NET" >/dev/null
docker run -d --name $P-pg --network "$NET" --network-alias pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
docker run -d --name $P-redis --network "$NET" --network-alias redis redis:7-alpine >/dev/null
docker run -d --name $P-smtp --network "$NET" --network-alias smtp -v "$W:/w" -v "$HERE/smtp_sink.py:/sink.py:ro" \
  python:3.12-alpine python -I /sink.py >/dev/null
docker run -d --name $P-stubs --network "$NET" --network-alias stubs -v "$W:/w" -v "$HERE/stubs.py:/stubs.py:ro" \
  python:3.12-alpine python -I /stubs.py >/dev/null
docker run -d --name $P-minio --network "$NET" --network-alias minio -e MINIO_ROOT_USER=formsminio \
  -e MINIO_ROOT_PASSWORD="$(cat "$W/jwt_secret" | cut -c1-24)" quay.io/minio/minio server /data >/dev/null
until docker exec $P-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i $P-pg psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE forms OWNER pguser;
SQL
docker exec $P-pg psql -U postgres -d forms -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
api() { # name project_code
  docker run -d --name $P-$1 --network "$NET" --network-alias api-$1 -p 127.0.0.1::80 -v "$SRC:/app" -v "$W/projects:/app/projects" \
    -e POSTGRES_HOST=pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=forms \
    -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE="$2" -e LAPIS_ENVIRONMENT=production -e OPSAPI_DEPLOY_ENV=test \
    -e REDIS_ENABLED=true -e REDIS_HOST=redis -e FRONTEND_URL=http://localhost:8039 -e OPSAPI_MAIL_ALLOW_PRIVATE=true \
    -e OPENSSL_SECRET_KEY="$(cat "$W/enc_key")" -e OPENSSL_SECRET_IV="$(cat "$W/enc_iv")" \
    -e AI_PROVIDER=openai -e AI_BASE_URL=http://stubs:8080/v1 -e AI_API_KEY=stub -e AI_MODEL=stub \
    -e AI_FALLBACK_PROVIDER=none -e TURNSTILE_VERIFY_URL=http://stubs:8080/turnstile \
    -e MINIO_ENDPOINT=http://minio:9000 -e MINIO_ENDPOINT_WEB_EXTERNAL=http://minio:9000 -e MINIO_BUCKET=forms-e2e \
    -e MINIO_ACCESS_KEY=formsminio -e MINIO_SECRET_KEY="$(cat "$W/jwt_secret" | cut -c1-24)" -e MINIO_REGION=us-east-1 \
    lapis-lapis >/dev/null
}
api a all; api b all; api c tax_copilot,services
sleep 7; docker exec -w /app $P-a lapis migrate > "$W/migrate.log" 2>&1 || { tail -30 "$W/migrate.log"; exit 1; }
# Logged before the tables existed: not part of the run.
for p in a b c; do docker exec $P-$p sh -c ': > /var/log/nginx/error.log'; done
docker restart $P-a $P-b $P-c >/dev/null
port() { docker port $P-$1 80/tcp | head -1 | sed 's/.*://'; }
for p in a b c; do until curl -fs "http://127.0.0.1:$(port $p)/health" >/dev/null 2>&1; do sleep 1; done; done
rc=0
API_A="http://127.0.0.1:$(port a)" API_B="http://127.0.0.1:$(port b)" API_C="http://127.0.0.1:$(port c)" \
  PG_CONTAINER=$P-pg API_CONTAINER=$P-a API_CONTAINER_B=$P-b JWT_SECRET_FILE="$W/jwt_secret" MAIL_DIR="$W/mail" \
  STUB_DIR="$W/stub" \
  python3 -I "$HERE/check.py" || rc=1
echo "== errors and form warnings logged by the pods during the run"
for p in a b; do docker exec $P-$p sh -c 'grep -E "\[error\]|\[warn\].*\[(forms|invitations)\]" /var/log/nginx/error.log | sed -E "s/^[0-9/]+ [0-9:]+ \[error\] [0-9]+#[0-9]+: (\*[0-9]+ )?//; s/, client: .*//" | cut -c1-220 | sort | uniq -c | head -10' || true; done
# KEEP=1: leave the stack up for debugging (remove it with: docker rm -f $P-a $P-b $P-c $P-pg $P-redis $P-smtp).
if [ -n "${KEEP:-}" ]; then trap - EXIT; echo "kept: containers $P-*, network $NET, files $W"; fi
exit $rc
