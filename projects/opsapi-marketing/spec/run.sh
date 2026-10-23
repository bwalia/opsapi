#!/usr/bin/env bash
# Marketing Cloud Phase 0 e2e in a throwaway Docker sandbox.
#   projects/opsapi-marketing/spec/run.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/projects/opsapi-marketing/spec"
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/mkt-e2e.XXXXXX"); NET=mkt-e2e-$$; ID=$$
cleanup() { [ -n "${KEEP:-}" ] && { echo "KEEP: $W"; return; }; docker rm -f mkt-api-$ID mkt-pg-$ID mkt-minio-$ID >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/src"
if command -v rsync >/dev/null; then
  (cd "$ROOT" && git ls-files -co --exclude-standard lapis projects/opsapi-marketing projects/helpdesk) | grep -v '^lapis/logs/' \
    | rsync -a --files-from=- "$ROOT/" "$W/src/"
else
  (cd "$ROOT" && git ls-files -co --exclude-standard lapis projects/opsapi-marketing projects/helpdesk | grep -v '^lapis/logs/' \
    | tar -cf - -T -) | tar -xf - -C "$W/src"
fi
# Include untracked marketing plugin files
rsync -a "$ROOT/projects/opsapi-marketing/" "$W/src/projects/opsapi-marketing/" 2>/dev/null || true
mkdir -p "$W/src/lapis/logs" "$W/src/projects"
JWT_SECRET=$(openssl rand -hex 32); MINIO_PW=$(openssl rand -hex 16)

docker network create "$NET" >/dev/null
docker run -d --name mkt-pg-$ID --network "$NET" --network-alias mkt-pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
until docker exec mkt-pg-$ID pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
# Email images are stored in MinIO.
docker run -d --name mkt-minio-$ID --network "$NET" --network-alias mkt-minio -e MINIO_ROOT_USER=mktminio \
  -e MINIO_ROOT_PASSWORD="$MINIO_PW" quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z server /data >/dev/null
docker exec -i mkt-pg-$ID psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE e2e OWNER pguser;
SQL
docker exec mkt-pg-$ID psql -U postgres -d e2e -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'

docker run -d --name mkt-api-$ID --network "$NET" -p 127.0.0.1::80 --add-host=host.docker.internal:host-gateway \
  -v "$W/src/lapis:/app" -v "$W/src/projects:/app/projects" \
  -e POSTGRES_HOST=mkt-pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=e2e \
  -e JWT_SECRET_KEY="$JWT_SECRET" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=development \
  -e OPSAPI_PUBLIC_URL=http://mkt-api.invalid -e OPSAPI_MAIL_ALLOW_PRIVATE=true \
  -e MINIO_ENDPOINT=http://mkt-minio:9000 -e MINIO_ACCESS_KEY=mktminio -e MINIO_SECRET_KEY="$MINIO_PW" \
  -e MINIO_BUCKET=mkt-e2e \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  -e REDIS_ENABLED=false -e AI_FALLBACK_PROVIDER=none \
  lapis-lapis >/dev/null
sleep 8
[ "$(docker inspect -f '{{.State.Running}}' mkt-api-$ID)" = true ] || { docker logs mkt-api-$ID 2>&1 | tail -50; exit 1; }

migrate() { docker exec -w /app mkt-api-$ID lapis migrate > "$W/migrate-$1.log" 2>&1 || { tail -60 "$W/migrate-$1.log"; exit 1; }; }
migrate 1
migrate 2
echo "ok    migrations ran twice"
docker exec mkt-pg-$ID psql -U postgres -d e2e -qc "DELETE FROM project_migrations WHERE project_code = 'opsapi_marketing'"
migrate 3
echo "ok    plugin migrations re-ran (idempotent)"
docker exec mkt-api-$ID sh -c 'kill -HUP $(cat /app/logs/nginx.pid 2>/dev/null || cat /usr/local/openresty/nginx/logs/nginx.pid)' 2>/dev/null || true
sleep 3

for u in 'a1111111-0000-4000-8000-000000000001 owner.a@mkt.invalid' 'b2222222-0000-4000-8000-000000000002 owner.b@mkt.invalid' \
         'c3333333-0000-4000-8000-000000000003 approver@mkt.invalid'; do
  set -- $u
  docker exec mkt-pg-$ID psql -U postgres -d e2e -qc "INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at)
    VALUES ('$1', 'Mkt', 'Test', '$2', '${2%%@*}', 'x', true, now(), now())"
done

PORT=$(docker port mkt-api-$ID 80/tcp | head -1 | sed 's/.*://')
export MKT_API="http://127.0.0.1:$PORT" MKT_JWT_SECRET="$JWT_SECRET"
export MKT_PSQL="docker exec -i mkt-pg-$ID psql -U postgres -d e2e -tA -c"

SUITES=${ONLY:-phase0_test phase2_test phase3_test phase4_test phase5_test phase6_test phase7_test phase8_test phase9_test phase10_test phase11_test phase12_test}
( cd "$HERE" && for s in $SUITES; do python3 -I "$s.py" || exit 1; done ) || {
  echo "--- errors ---"
  docker exec mkt-api-$ID sh -c 'cat /app/logs/error.log /var/log/nginx/error.log 2>/dev/null' | tail -40
  exit 1
}
