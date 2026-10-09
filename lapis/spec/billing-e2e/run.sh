#!/usr/bin/env bash
# Billing & Entitlements end-to-end check in an isolated, no-internet Docker sandbox
# (docs/BILLING_ENTITLEMENTS.md §20): a fresh PROJECT_CODE=billing install with its own
# Postgres, Redis and an SMTP sink; an app configured purely through the API, sold,
# activated, verified offline, managed by its customer, upgraded, exported and deleted (run.py);
# then payments (pay.py): Stripe Connect, hosted checkout and webhook fulfilment against stripe-mock,
# Stripe's own API mock (it validates every parameter), answering as api.stripe.com inside the sandbox.
#
#   lapis/spec/billing-e2e/run.sh            # from the repo root; needs the lapis-lapis image
#
# Throwaway keys are generated for the run and removed afterwards.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/billing-e2e"
W=$(mktemp -d); NET=billing-e2e-$$
cleanup() { docker rm -f e2e-api-$$ e2e-pg-$$ e2e-redis-$$ e2e-smtp-$$ e2e-stripe-$$ >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true; git -C "$ROOT" worktree remove --force "$W/src" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/mail" "$W/out" "$W/projects"
git -C "$ROOT" worktree add -q --detach "$W/src" HEAD; mkdir -p "$W/src/lapis/logs"
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt > "$W/sign.pem"
JWT_SECRET=$(openssl rand -hex 32)
docker network create --internal "$NET" >/dev/null
docker run -d --name e2e-pg-$$ --network "$NET" --network-alias e2e-pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
docker run -d --name e2e-redis-$$ --network "$NET" --network-alias e2e-redis redis:7-alpine >/dev/null
docker run -d --name e2e-stripe-$$ --network "$NET" --network-alias api.stripe.com stripe/stripe-mock:latest -https-port 443 >/dev/null
docker run -d --name e2e-smtp-$$ --network "$NET" --network-alias e2e-smtp -v "$HERE/smtp_sink.py:/sink.py:ro" -v "$W/mail:/mail" python:3.12-alpine python -I /sink.py >/dev/null
until docker exec e2e-pg-$$ pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i e2e-pg-$$ psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE e2e OWNER pguser;
SQL
docker exec e2e-pg-$$ psql -U postgres -d e2e -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
docker run -d --name e2e-api-$$ --network "$NET" --network-alias e2e-api -v "$W/src/lapis:/app" -v "$W/projects:/app/projects" \
  -e POSTGRES_HOST=e2e-pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=e2e -e JWT_SECRET_KEY="$JWT_SECRET" \
  -e PROJECT_CODE=billing -e LAPIS_ENVIRONMENT=production -e BILLING_SIGNING_KEY="$(cat "$W/sign.pem")" -e BILLING_SIGNING_KEY_ID=e2e \
  -e OPSAPI_PUBLIC_URL=https://billing.e2e.test -e BILLING_HOSTED_BASE_URL=https://hosted.e2e.test -e REDIS_HOST=e2e-redis \
  -e REDIS_ENABLED=true -e OPSAPI_MAIL_ALLOW_PRIVATE=true -e OPENSSL_SECRET_KEY="$(openssl rand -hex 8)" \
  -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" -e STRIPE_SECRET_KEY=sk_test_e2e -e STRIPE_PLATFORM_FEE_PERCENT=10 \
  -e STRIPE_SSL_VERIFY=false -e STRIPE_CONNECT_WEBHOOK_SECRET=whsec_e2e_platform,whsec_e2e_connect -e LICENCE_DELIVERY_KEY="$(openssl rand -base64 32)" \
  -e LICENCE_DELIVERY_KEY_ID=e2e-1 lapis-lapis >/dev/null
sleep 6; docker exec -w /app e2e-api-$$ lapis migrate >/dev/null; docker exec e2e-api-$$ sh -c 'kill -HUP $(cat /app/logs/nginx.pid)'; sleep 2
docker exec e2e-pg-$$ psql -U postgres -d e2e -qc "INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) VALUES ('11111111-2222-4333-8444-555555555555','E2E','Owner','owner@e2e.invalid','e2eowner','x',true,now(),now())"
python3 - "$JWT_SECRET" > "$W/owner.jwt" <<'PY'
import sys, hmac, hashlib, base64, json, time
b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
h = b({"typ": "JWT", "alg": "HS256"}); p = b({"userinfo": {"uuid": "11111111-2222-4333-8444-555555555555", "email": "owner@e2e.invalid"}, "iat": int(time.time()), "exp": int(time.time()) + 3600, "iss": "opsapi"})
print((h + b"." + p + b"." + base64.urlsafe_b64encode(hmac.new(sys.argv[1].encode(), h + b"." + p, hashlib.sha256).digest()).rstrip(b"=")).decode())
PY
cp "$HERE/run.py" "$HERE/pay.py" "$W/"
docker run --rm --network "$NET" -v "$W:/e2e" -v "$W/mail:/mail" python:3.12-alpine python -I /e2e/run.py
docker run --rm --network "$NET" -v "$W:/e2e" -v "$W/mail:/mail" python:3.12-alpine python -I /e2e/pay.py
docker exec e2e-redis-$$ sh -c "redis-cli --scan --pattern 'billing:*' | xargs -r redis-cli DEL" >/dev/null
(cd "$ROOT/sdk/typescript" && npm run build >/dev/null 2>&1)
docker run --rm --network "$NET" -v "$W:/e2e" -v "$ROOT/sdk/typescript/dist:/sdk:ro" -v "$HERE/sdk.mjs:/e2e/sdk.mjs:ro" -w /e2e node:22-alpine node sdk.mjs
