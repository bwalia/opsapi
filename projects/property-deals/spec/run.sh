#!/usr/bin/env bash
# Property Deals end-to-end check in a throwaway Docker sandbox: a fresh
# PROJECT_CODE=property install with its own Postgres, the plugin mounted,
# migrations run twice (and re-run from scratch to prove they are idempotent),
# then api_test.py drives the API as two workspaces and several roles, and
# scenario_test.py runs the SPEC §5 scenario (rules part) with time travel in SQL.
#
#   projects/property-deals/spec/run.sh       # from the repo root; needs the lapis-lapis image
#
# Copies the working tree (tracked + untracked, not ignored), so it tests uncommitted work too.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/projects/property-deals/spec"
# Under $HOME: Docker Desktop/colima share it, not always macOS's /var/folders temp dir.
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/pd-e2e.XXXXXX"); NET=pd-e2e-$$; ID=$$
cleanup() { [ -n "${KEEP:-}" ] && { echo "KEEP: sandbox left running (pd-api-$ID, pd-pg-$ID, $W)"; return; }; docker rm -f pd-api-$ID pd-pg-$ID >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

mkdir -p "$W/src"
(cd "$ROOT" && git ls-files -co --exclude-standard lapis projects/property-deals) | grep -v '^lapis/logs/' \
  | rsync -a --files-from=- "$ROOT/" "$W/src/"
mkdir -p "$W/src/lapis/logs" "$W/src/projects"
JWT_SECRET=$(openssl rand -hex 32)

docker network create "$NET" >/dev/null
docker run -d --name pd-pg-$ID --network "$NET" --network-alias pd-pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
until docker exec pd-pg-$ID pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i pd-pg-$ID psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE e2e OWNER pguser;
SQL
# Extensions a hosted Postgres would pre-install (the app role isn't superuser).
docker exec pd-pg-$ID psql -U postgres -d e2e -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS cube;
  CREATE EXTENSION IF NOT EXISTS earthdistance;'

docker run -d --name pd-api-$ID --network "$NET" -p 127.0.0.1::80 -v "$W/src/lapis:/app" -v "$W/src/projects:/app/projects" \
  -e POSTGRES_HOST=pd-pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=e2e \
  -e JWT_SECRET_KEY="$JWT_SECRET" -e PROJECT_CODE=property -e LAPIS_ENVIRONMENT=production \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  -e REDIS_ENABLED=false lapis-lapis >/dev/null
sleep 6
[ "$(docker inspect -f '{{.State.Running}}' pd-api-$ID)" = true ] || { docker logs pd-api-$ID 2>&1 | tail -40; exit 1; }
migrate() { docker exec -w /app pd-api-$ID lapis migrate > "$W/migrate-$1.log" 2>&1 || { tail -40 "$W/migrate-$1.log"; exit 1; }; }
migrate 1; migrate 2
echo "ok    migrations ran twice"
# Restored-database case: forget the plugin's tracking rows and run them all again.
docker exec pd-pg-$ID psql -U postgres -d e2e -qc "DELETE FROM project_migrations WHERE project_code = 'property_deals'"
migrate 3
echo "ok    plugin migrations re-ran from scratch (idempotent)"
docker exec pd-api-$ID sh -c 'kill -HUP $(cat /app/logs/nginx.pid)'; sleep 3

for u in 'a1111111-0000-4000-8000-000000000001 owner.a@pd.invalid' 'b2222222-0000-4000-8000-000000000002 owner.b@pd.invalid' \
         'c3333333-0000-4000-8000-000000000003 reader.a@pd.invalid' 'd4444444-0000-4000-8000-000000000004 agent.a@pd.invalid' \
         'e5555555-0000-4000-8000-000000000005 operator.a@pd.invalid' 'f6666666-0000-4000-8000-000000000006 owner.s@pd.invalid' \
         'a7777777-0000-4000-8000-000000000007 manager.s@pd.invalid' 'b8888888-0000-4000-8000-000000000008 operator.s@pd.invalid'; do
  set -- $u
  docker exec pd-pg-$ID psql -U postgres -d e2e -qc "INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at)
    VALUES ('$1', 'PD', 'Test', '$2', '${2%%@*}', 'x', true, now(), now())"
done

PORT=$(docker port pd-api-$ID 80/tcp | head -1 | sed 's/.*://')
export PD_API="http://127.0.0.1:$PORT" PD_JWT_SECRET="$JWT_SECRET" PD_PSQL="docker exec -i pd-pg-$ID psql -U postgres -d e2e -tA -c"
{ python3 -I "$HERE/api_test.py" && python3 -I "$HERE/scenario_test.py" && python3 -I "$HERE/contract_test.py"; } || {
  echo "--- server errors ---"
  docker exec pd-api-$ID sh -c 'cat /app/logs/error.log /var/log/nginx/error.log 2>/dev/null' \
    | grep -A2 "\[property_deals\]" | grep -v -E "^\s+/|^--" | sed 's/.*\[property_deals\] //' | cut -c1-400 | sort -u | tail -10
  exit 1; }
