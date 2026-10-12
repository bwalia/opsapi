#!/usr/bin/env bash
# AI Runs end-to-end check in a throwaway Docker sandbox: a fresh PROJECT_CODE=all install with its own Postgres,
# only this plugin mounted, migrations run twice (and the plugin's re-run from scratch to prove they are
# idempotent), then ai_runner_test.py drives the API as users of two workspaces and as a fake runner.
#
#   projects/ai-runner/spec/run.sh            # from anywhere; needs the local lapis-lapis image
#   KEEP=1 projects/ai-runner/spec/run.sh     # leave the sandbox running (prints how to reach it)
#   ONLY=ai_runner_test projects/ai-runner/spec/run.sh
#   PROMPTPILOT_BIN=…/promptpilot PROMPTPILOT_DIR=…/promptpilot projects/ai-runner/spec/run.sh   # + the real runner
#
# Copies the working tree (tracked + untracked, not ignored), so it tests uncommitted work too.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/projects/ai-runner/spec"
# Under $HOME: Docker Desktop/colima share it, not always macOS's /var/folders temp dir.
mkdir -p "$HOME/.cache"; W=$(mktemp -d "$HOME/.cache/ar-e2e.XXXXXX"); ID=$$-$RANDOM; NET=ar-e2e-$ID
cleanup() {
  if [ -n "${KEEP:-}" ]; then
    echo "KEEP: sandbox left running (ar-api-$ID, ar-pg-$ID, network $NET, $W)"
    echo "      API $AR_API  ·  psql: docker exec -it ar-pg-$ID psql -U postgres -d e2e"
    echo "      remove: docker rm -f ar-api-$ID ar-pg-$ID; docker network rm $NET; rm -rf $W"
    return
  fi
  docker rm -f "ar-api-$ID" "ar-pg-$ID" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$W"
}
AR_API=""; trap cleanup EXIT

mkdir -p "$W/src"
if command -v rsync >/dev/null; then
  (cd "$ROOT" && git ls-files -co --exclude-standard lapis projects/ai-runner) | grep -v '^lapis/logs/' \
    | rsync -a --files-from=- "$ROOT/" "$W/src/"
else
  (cd "$ROOT" && git ls-files -co --exclude-standard lapis projects/ai-runner | grep -v '^lapis/logs/' \
    | tar -cf - -T -) | tar -xf - -C "$W/src"
fi
mkdir -p "$W/src/lapis/logs" "$W/src/projects"
JWT_SECRET=$(openssl rand -hex 32)

docker network create "$NET" >/dev/null
docker run -d --name "ar-pg-$ID" --network "$NET" --network-alias ar-pg -e POSTGRES_PASSWORD=sbx \
  pgvector/pgvector:pg15 >/dev/null
until docker exec "ar-pg-$ID" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i "ar-pg-$ID" psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE e2e OWNER pguser;
SQL
# Extensions a hosted Postgres would pre-install (the app role isn't superuser).
docker exec "ar-pg-$ID" psql -U postgres -d e2e -qc 'CREATE EXTENSION IF NOT EXISTS vector;
  CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
  CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS cube; CREATE EXTENSION IF NOT EXISTS earthdistance;'

docker run -d --name "ar-api-$ID" --network "$NET" -p 127.0.0.1::80 -v "$W/src/lapis:/app" \
  -v "$W/src/projects:/app/projects" \
  -e POSTGRES_HOST=ar-pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=e2e \
  -e JWT_SECRET_KEY="$JWT_SECRET" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production \
  -e OPENSSL_SECRET_KEY="$(openssl rand -hex 16)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  -e FRONTEND_URL=https://dash.example.invalid -e REDIS_ENABLED=false lapis-lapis >/dev/null
sleep 6
[ "$(docker inspect -f '{{.State.Running}}' "ar-api-$ID")" = true ] || { docker logs "ar-api-$ID" 2>&1 | tail -40; exit 1; }
migrate() { docker exec -w /app "ar-api-$ID" lapis migrate > "$W/migrate-$1.log" 2>&1 || { tail -40 "$W/migrate-$1.log"; exit 1; }; }
migrate 1; migrate 2
echo "ok    migrations ran twice"
# Restored-database case: forget the plugin's tracking rows and run them all again.
docker exec "ar-pg-$ID" psql -U postgres -d e2e -qc "DELETE FROM project_migrations WHERE project_code = 'ai_runner'"
migrate 3
grep -q "ai_runner/.*: running" "$W/migrate-3.log" || { echo "FAIL  plugin migrations did not re-run"; tail -20 "$W/migrate-3.log"; exit 1; }
echo "ok    plugin migrations re-ran from scratch (idempotent)"
docker exec "ar-api-$ID" sh -c 'kill -HUP $(cat /app/logs/nginx.pid)'; sleep 3

for u in 'a1111111-0000-4000-8000-000000000001 owner.a@ar.invalid' 'b2222222-0000-4000-8000-000000000002 owner.b@ar.invalid' \
         'c3333333-0000-4000-8000-000000000003 dev.a@ar.invalid' 'd4444444-0000-4000-8000-000000000004 dev2.a@ar.invalid' \
         'e5555555-0000-4000-8000-000000000005 mgr.a@ar.invalid' 'f6666666-0000-4000-8000-000000000006 padmin.a@ar.invalid' \
         'a7777777-0000-4000-8000-000000000007 platform.admin@ar.invalid'; do
  set -- $u
  docker exec "ar-pg-$ID" psql -U postgres -d e2e -qc "INSERT INTO users (uuid, first_name, last_name, email, username,
    password, active, created_at, updated_at) VALUES ('$1', 'AR', 'Test', '$2', '${2%%@*}', 'x', true, now(), now())"
done
# The platform admin runs the sweep job on demand (POST /api/v2/plugins/ai_runner/jobs/lease_sweep/run).
docker exec "ar-pg-$ID" psql -U postgres -d e2e -qc "INSERT INTO user__roles (uuid, role_id, user_id, created_at, updated_at)
  SELECT gen_random_uuid()::text, r.id, u.id, now(), now() FROM roles r, users u
  WHERE r.role_name = 'administrative' AND u.uuid = 'a7777777-0000-4000-8000-000000000007'"

PORT=$(docker port "ar-api-$ID" 80/tcp | head -1 | sed 's/.*://')
AR_API="http://127.0.0.1:$PORT"
export AR_API AR_JWT_SECRET="$JWT_SECRET" AR_PSQL="docker exec -i ar-pg-$ID psql -U postgres -d e2e -tA -c"
# PROMPTPILOT_BIN=/path/to/promptpilot PROMPTPILOT_DIR=/path/to/promptpilot-source adds the real runner suite.
SUITES=${ONLY:-ai_runner_test${PROMPTPILOT_BIN:+ promptpilot_test}}
( for s in $SUITES; do python3 -I "$HERE/$s.py" || exit 1; done ) || {
  echo "--- server errors ---"
  docker exec "ar-api-$ID" sh -c 'cat /app/logs/error.log /var/log/nginx/error.log 2>/dev/null' \
    | grep -E "\[ai_runner\]|SYSTEM_500|\[Plugin" | cut -c1-400 | sort -u | tail -15
  exit 1; }
