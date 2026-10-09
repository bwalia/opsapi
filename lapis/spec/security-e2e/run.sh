#!/usr/bin/env bash
# Live security checks (auth hardening) in an isolated, no-internet Docker sandbox:
# a fresh PROJECT_CODE=all install of a git ref, seeded users, then check.py.
#
#   lapis/spec/security-e2e/run.sh              # this checkout (HEAD)
#   lapis/spec/security-e2e/run.sh origin/main  # the same checks against main (they should fail there)
#
# Needs the lapis-lapis image. Throwaway secrets are generated per run and removed afterwards.
set -euo pipefail
REF=${1:-HEAD}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/security-e2e"
W=$(mktemp -d); NET=sec-e2e-$$
cleanup() { docker rm -f sec-api-$$ sec-pg-$$ >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true
  git -C "$ROOT" worktree remove --force "$W/src" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/out" "$W/projects"
git -C "$ROOT" worktree add -q --detach "$W/src" "$REF"; mkdir -p "$W/src/lapis/logs"
openssl rand -hex 32 > "$W/jwt_secret"; openssl rand -hex 16 > "$W/gh_secret"; openssl rand -hex 16 > "$W/peek_secret"
# The seeded users' password: random per run, never in the repo.
printf "Sx%s!" "$(openssl rand -hex 10)" > "$W/user_password"
docker network create --internal "$NET" >/dev/null
docker run -d --name sec-pg-$$ --network "$NET" --network-alias sec-pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
until docker exec sec-pg-$$ pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i sec-pg-$$ psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE sec OWNER pguser;
SQL
docker exec sec-pg-$$ psql -U postgres -d sec -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
docker run -d --name sec-api-$$ --network "$NET" --network-alias sec-api -v "$W/src/lapis:/app" -v "$W/projects:/app/projects" \
  -e POSTGRES_HOST=sec-pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=sec \
  -e JWT_SECRET_KEY="$(cat "$W/jwt_secret")" -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production -e OPSAPI_DEPLOY_ENV=test \
  -e STRIPE_WEBHOOK_SECRET=whsec_sec_e2e -e GITHUB_WEBHOOK_SECRET="$(cat "$W/gh_secret")" \
  -e E2E_OTP_PEEK_ENABLED=true -e E2E_OTP_PEEK_SECRET="$(cat "$W/peek_secret")" -e 'OTP_SUPPRESS_FOR_EMAIL_REGEX=@sec\.test$' \
  lapis-lapis >/dev/null
sleep 7; docker exec -w /app sec-api-$$ lapis migrate >/dev/null 2>&1; docker restart sec-api-$$ >/dev/null; sleep 7
# Users: alice and bob own a workspace each; carol, dave and gail sign in with a password; eve and frank are staff.
HASH=$(docker exec -e PW="$(cat "$W/user_password")" sec-api-$$ /usr/local/openresty/luajit/bin/luajit -e 'print(require("bcrypt").digest(os.getenv("PW"), 10))')
echo '{' > "$W/users.json"; sep=""
for who in alice bob carol dave eve frank gail; do
  id=$(python3 -c 'import uuid; print(uuid.uuid4())')
  docker exec sec-pg-$$ psql -U postgres -d sec -qc "INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) VALUES ('$id', '$who', 'Sec', '$who@sec.test', '$who', '$HASH', true, now(), now())"
  printf '%s"%s": {"uuid": "%s", "email": "%s@sec.test"}' "$sep" "$who" "$id" "$who" >> "$W/users.json"; sep=","
done
echo '}' >> "$W/users.json"
cp "$HERE/check.py" "$W/"
docker run --rm --network "$NET" -v "$W:/sec" python:3.12-alpine python -I /sec/check.py
# OTP codes are stored hashed: no plain code for the user who just signed in.
plain=$(docker exec sec-pg-$$ psql -U postgres -d sec -Atc "SELECT count(*) FROM admin_otp_codes o JOIN users u ON u.id = o.user_id WHERE u.uuid = '$(cat "$W/out/otp_user.txt")' AND o.code IS NOT NULL")
total=$(docker exec sec-pg-$$ psql -U postgres -d sec -Atc "SELECT count(*) FROM admin_otp_codes o JOIN users u ON u.id = o.user_id WHERE u.uuid = '$(cat "$W/out/otp_user.txt")'")
if [ "$plain" = "0" ] && [ "$total" != "0" ]; then echo "  ok   OTP codes are stored hashed ($total row, no plain code)"; else echo "  FAIL OTP codes stored in plain text ($plain of $total rows)"; fi
