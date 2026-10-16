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

# Mass assignment and missing guards (check_mass_assignment.py): two sellers with a store each in sec-a and sec-b,
# a platform admin, and a user whose first platform role is tax_admin; one product, variant, category, order and
# order item per store, and a platform secret.
psqlq() { docker exec sec-pg-$$ psql -U postgres -d sec -v ON_ERROR_STOP=1 -qAtc "$1"; }
echo '{' > "$W/users2.json"; sep=""
for who in sam vic tina pat; do
  id=$(python3 -c 'import uuid; print(uuid.uuid4())')
  psqlq "INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) VALUES ('$id', '$who', 'Sec', '$who@sec.test', '$who', '$HASH', true, now(), now())"
  printf '%s"%s": {"uuid": "%s", "email": "%s@sec.test"}' "$sep" "$who" "$id" "$who" >> "$W/users2.json"; sep=","
done
echo '}' >> "$W/users2.json"
for pair in sam:seller vic:seller tina:tax_admin pat:administrative; do
  psqlq "INSERT INTO user__roles (uuid, user_id, role_id, created_at, updated_at) SELECT md5(random()::text), u.id, r.id, now(), now() FROM users u, roles r WHERE u.username = '${pair%%:*}' AND r.role_name = '${pair##*:}'"
done
psqlq "
INSERT INTO stores (uuid, user_id, name, slug, namespace_id, created_at, updated_at) VALUES
  ('st-a', (SELECT id FROM users WHERE username='sam'), 'Sam Shop', 'sam-shop', (SELECT id FROM namespaces WHERE slug='sec-a'), now(), now()),
  ('st-b', (SELECT id FROM users WHERE username='vic'), 'Vic Shop', 'vic-shop', (SELECT id FROM namespaces WHERE slug='sec-b'), now(), now());
INSERT INTO storeproducts (uuid, store_id, name, price, compare_price, namespace_id, is_active, created_at, updated_at) VALUES
  ('pr-a', (SELECT id FROM stores WHERE uuid='st-a'), 'Expensive A', 500, NULL, (SELECT id FROM namespaces WHERE slug='sec-a'), true, now(), now()),
  ('pr-b', (SELECT id FROM stores WHERE uuid='st-b'), 'Cheap B', 1, NULL, (SELECT id FROM namespaces WHERE slug='sec-b'), true, now(), now());
INSERT INTO product_variants (uuid, product_id, title, price, inventory_quantity, is_active, created_at, updated_at) VALUES
  ('va-a', (SELECT id FROM storeproducts WHERE uuid='pr-a'), 'A large', 450, 25, true, now(), now()),
  ('va-b', (SELECT id FROM storeproducts WHERE uuid='pr-b'), 'B small', 1, 25, true, now(), now());
INSERT INTO categories (uuid, store_id, name, namespace_id, created_at, updated_at) VALUES
  ('ca-a', (SELECT id FROM stores WHERE uuid='st-a'), 'Cat A', (SELECT id FROM namespaces WHERE slug='sec-a'), now(), now()),
  ('ca-b', (SELECT id FROM stores WHERE uuid='st-b'), 'Cat B', (SELECT id FROM namespaces WHERE slug='sec-b'), now(), now());
INSERT INTO orders (uuid, store_id, order_number, status, subtotal, total_amount, payment_status, namespace_id, created_at, updated_at) VALUES
  ('or-a', (SELECT id FROM stores WHERE uuid='st-a'), 'SEC-1', 'pending', 100, 100, 'pending', (SELECT id FROM namespaces WHERE slug='sec-a'), now(), now());
INSERT INTO orderitems (uuid, order_id, product_id, product_title, quantity, price, total, created_at, updated_at) VALUES
  ('oi-a', (SELECT id FROM orders WHERE uuid='or-a'), (SELECT id FROM storeproducts WHERE uuid='pr-a'), 'Expensive A', 1, 100, 100, now(), now());
INSERT INTO secrets (uuid, secret, name, description, created_at, updated_at) VALUES ('se-1', 'not-really-encrypted', 'stripe', 'test', now(), now());"
psqlq "SELECT json_build_object('store_b', (SELECT id FROM stores WHERE uuid='st-b'), 'ns_b', (SELECT id FROM namespaces WHERE slug='sec-b'),
  'product_b', (SELECT id FROM storeproducts WHERE uuid='pr-b'), 'category_b', (SELECT id FROM categories WHERE uuid='ca-b'),
  'order_b_like', 999999)" > "$W/fixtures.json"
cp "$HERE/check_mass_assignment.py" "$W/"
docker run --rm --network "$NET" -v "$W:/sec" python:3.12-alpine python -I /sec/check_mass_assignment.py
