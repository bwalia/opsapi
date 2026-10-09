#!/usr/bin/env bash
# Chat across pods: two API processes (api-a, api-b) share one Redis and one
# Postgres; a WebSocket client on each must get what the other pod sends.
# api-c runs with REDIS_ENABLED=false (local-only, as before pub/sub) and as
# production. Kanban events, delivery-partner codes and a per-route rate limit
# must also hold across the two Redis pods. Then
# Redis is stopped (sends still succeed, delivery stays local, /ready on the
# Redis pods answers 503) and restarted (the subscribers reconnect by
# themselves, /ready recovers, cross-pod delivery resumes). Redis has a
# password, as in the Helm chart.
#
#   lapis/spec/chat-pubsub-e2e/run.sh              # this checkout (HEAD)
#   lapis/spec/chat-pubsub-e2e/run.sh origin/main  # the same checks against main (cross-pod fails there)
#
# No internet; needs the lapis-lapis, pgvector/pgvector:pg15, redis:7-alpine and python:3.12-alpine images.
set -euo pipefail
REF=${1:-HEAD}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/chat-pubsub-e2e"
W=$(mktemp -d); NET=chat-e2e-$$; P=chat-$$
cleanup() { docker rm -f $P-a $P-b $P-c $P-pg $P-redis >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true
  git -C "$ROOT" worktree remove --force "$W/src" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
git -C "$ROOT" worktree add -q --detach "$W/src" "$REF"; mkdir -p "$W/src/lapis/logs" "$W/projects"
openssl rand -hex 32 > "$W/jwt_secret"; openssl rand -hex 20 > "$W/redis_password"
docker network create --internal "$NET" >/dev/null
docker run -d --name $P-pg --network "$NET" --network-alias pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
docker run -d --name $P-redis --network "$NET" --network-alias redis redis:7-alpine redis-server --requirepass "$(cat "$W/redis_password")" >/dev/null
until docker exec $P-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i $P-pg psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE chat OWNER pguser;
SQL
docker exec $P-pg psql -U postgres -d chat -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
api() { # name redis_enabled require_redis deploy_env
  docker run -d --name $P-$1 --network "$NET" --network-alias api-$1 -v "$W/src/lapis:/app" -v "$W/projects:/app/projects" \
    -e POSTGRES_HOST=pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=chat \
    -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production -e OPSAPI_DEPLOY_ENV="$4" \
    -e REDIS_ENABLED="$2" -e REDIS_HOST=redis -e REDIS_PASSWORD="$(cat "$W/redis_password")" \
    -e CHAT_REQUIRE_REDIS="$3" lapis-lapis >/dev/null
}
api a true true test; api b true true test; api c false false prod
sleep 7; docker exec -w /app $P-a lapis migrate >/dev/null 2>&1; docker restart $P-a $P-b $P-c >/dev/null
log() { docker exec $P-$1 cat /var/log/nginx/error.log; }  # the http-level error_log
# Live pattern subscriptions Redis holds (one per subscribed nginx worker).
subs() { docker exec -e REDISCLI_AUTH="$(cat "$W/redis_password")" $P-redis redis-cli client list | grep -c " psub=1 " || true; }
wait_subs() {
  for _ in $(seq 60); do [ "$(subs)" -ge 2 ] && return 0; sleep 1; done
  echo "  FAIL only $(subs) of 2 pods subscribed"; return 1
}
rc=0
wait_subs && echo "  ok   api-a and api-b each hold a Redis subscription ($(subs) in Redis; api-c, REDIS_ENABLED=false, none)" || rc=1
# alice, bob and carol, all members of one channel.
echo '{' > "$W/users.json"; sep=""
for who in alice bob carol; do
  id=$(python3 -c 'import uuid; print(uuid.uuid4())')
  docker exec $P-pg psql -U postgres -d chat -qc "INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) VALUES ('$id', '$who', 'Chat', '$who@chat.test', '$who', 'x', true, now(), now())"
  printf '%s"%s": {"uuid": "%s", "email": "%s@chat.test"}' "$sep" "$who" "$id" "$who" >> "$W/users.json"; sep=","
done
echo '}' >> "$W/users.json"
python3 -c 'import uuid; print(uuid.uuid4())' > "$W/channel_uuid"; CH=$(cat "$W/channel_uuid")
docker exec $P-pg psql -U postgres -d chat -qc "INSERT INTO chat_channels (uuid, name, type, created_by, created_at, updated_at) VALUES ('$CH', 'general', 'public', 'seed', now(), now())"
for who in alice bob carol; do
  docker exec $P-pg psql -U postgres -d chat -qc "INSERT INTO chat_channel_members (uuid, channel_uuid, user_uuid, joined_at, created_at, updated_at) SELECT gen_random_uuid()::text, '$CH', uuid, now(), now(), now() FROM users WHERE email = '$who@chat.test'"
done
# Kanban: one project (alice + bob), one board and column. Delivery: alice is a partner.
python3 -c 'import uuid; print(uuid.uuid4())' > "$W/project_uuid"; python3 -c 'import uuid; print(uuid.uuid4())' > "$W/board_uuid"
docker exec -i $P-pg psql -U postgres -d chat -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO namespaces (uuid, name, slug) VALUES (gen_random_uuid()::text, 'Chat', 'chat-e2e');
INSERT INTO kanban_projects (uuid, namespace_id, name, slug, owner_user_uuid)
  SELECT '$(cat "$W/project_uuid")', id, 'Board', 'board', (SELECT uuid FROM users WHERE email = 'alice@chat.test') FROM namespaces WHERE slug = 'chat-e2e';
INSERT INTO kanban_project_members (uuid, project_id, user_uuid, role)
  SELECT gen_random_uuid()::text, p.id, u.uuid, 'member' FROM kanban_projects p, users u WHERE u.email IN ('alice@chat.test', 'bob@chat.test');
INSERT INTO kanban_boards (uuid, project_id, name, created_by)
  SELECT '$(cat "$W/board_uuid")', id, 'Main', owner_user_uuid FROM kanban_projects;
INSERT INTO kanban_columns (uuid, board_id, name) SELECT gen_random_uuid()::text, id, 'To do' FROM kanban_boards;
INSERT INTO delivery_partners (uuid, user_id, company_name, contact_person_name, contact_person_phone,
    contact_person_email, business_address, created_at, updated_at)
  SELECT gen_random_uuid()::text, id, 'Fast', 'Alice', '+44 7700 900123', email, '1 Road', now(), now()
  FROM users WHERE email IN ('alice@chat.test', 'carol@chat.test');
SQL
cp "$HERE/check.py" "$W/"
check() { docker run --rm --network "$NET" -v "$W:/w" python:3.12-alpine python -I /w/check.py $1; }
echo "== two pods, one Redis"; check "ready 200" || rc=1; check cross || rc=1; check multipod || rc=1
echo "== Redis stopped"; docker stop $P-redis >/dev/null; check "ready 503" || rc=1; check down || rc=1
log a | grep -q "PUBLISH failed" && echo "  ok   api-a logged a WARN and fell back to local delivery" || { echo "  FAIL no WARN on api-a"; rc=1; }
echo "== Redis back"; docker start $P-redis >/dev/null
wait_subs && echo "  ok   both subscribers reconnected on their own" || rc=1
check "ready 200" || rc=1; check cross || rc=1
echo "== chat-ws log lines (all pods)"
for p in a b c; do log $p | grep "chat-ws" | sed -E "s/^[0-9/]+ [0-9:]+ //; s/[0-9]+#[0-9]+: (\*[0-9]+ )?//; s/, context: .*//; s/^/  api-$p: /" | sort | uniq -c | head -8 || true; done
exit $rc
