#!/usr/bin/env bash
# VIP price-lock membership end-to-end check in a throwaway Docker sandbox: a fresh PROJECT_CODE=all install
# (shop + billing) with its own Postgres, an SMTP sink, and stripe-mock — Stripe's own API mock, which
# validates every parameter — answering as api.stripe.com. check.py then drives the public shop API and
# signed Stripe webhooks: founding-member cap, pricing, sign-in by emailed link, 90/120-day price lock,
# fee refund credit on a £100k+ order, credit at checkout, early access, waitlist, cancel, loyalty credit,
# the supplier catalogue sync (a password-protected test feed, cost + margin pricing, approvals), and customer
# sign-in with Google (a stand-in for Google's token + userinfo endpoints) → "my quotes".
#
#   lapis/spec/shop-vip-e2e/run.sh           # from the repo root; needs the lapis-lapis image
#
# Throwaway keys are generated for the run and everything is removed afterwards. Both the workspace mail
# settings and the deployment SMTP point at the sink, so no real email can leave the sandbox.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); HERE="$ROOT/lapis/spec/shop-vip-e2e"
W=$(mktemp -d); NET=shop-vip-e2e-$$; PORT=${SHOP_VIP_E2E_PORT:-48731}
cleanup() { docker rm -f e2e-api-$$ e2e-pg-$$ e2e-smtp-$$ e2e-stripe-$$ e2e-feed-$$ e2e-google-$$ >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
# SHOP_VIP_E2E_KEEP=1 leaves the sandbox running for debugging (remove it with the printed command).
if [ -n "${SHOP_VIP_E2E_KEEP:-}" ]; then trap - EXIT
  echo "keeping sandbox: docker rm -f e2e-api-$$ e2e-pg-$$ e2e-smtp-$$ e2e-stripe-$$ e2e-feed-$$ e2e-google-$$; docker network rm $NET; rm -rf $W"; fi
mkdir -p "$W/mail" "$W/certs"
# Throwaway TLS pair for the Google stand-in, handed over as env (a temp-dir bind mount is empty under some
# Docker Desktop setups, which only share the home directory).
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=googleapis.com" \
  -keyout "$W/certs/key.pem" -out "$W/certs/cert.pem" >/dev/null 2>&1
BFF_KEY=$(openssl rand -hex 24); WHSEC=whsec_$(openssl rand -hex 16); JWT_SECRET=$(openssl rand -hex 32)
docker network create "$NET" >/dev/null
docker run -d --name e2e-pg-$$ --network "$NET" --network-alias e2e-pg -e POSTGRES_PASSWORD=sbx pgvector/pgvector:pg15 >/dev/null
docker run -d --name e2e-stripe-$$ --network "$NET" --network-alias api.stripe.com stripe/stripe-mock:v0.188.0 -https-port 443 >/dev/null
docker run -d --name e2e-feed-$$ --network "$NET" --network-alias e2e-feed -v "$HERE/feed_server.py:/feed_server.py:ro" python:3.12-alpine python -I /feed_server.py >/dev/null
docker run -d --name e2e-google-$$ --network "$NET" --network-alias oauth2.googleapis.com --network-alias www.googleapis.com \
  -e MOCK_CERT="$(cat "$W/certs/cert.pem")" -e MOCK_KEY="$(cat "$W/certs/key.pem")" \
  -v "$HERE/google_mock.py:/google_mock.py:ro" python:3.12-alpine python -I /google_mock.py >/dev/null
docker run -d --name e2e-smtp-$$ --network "$NET" --network-alias e2e-smtp -v "$HERE/smtp_sink.py:/sink.py:ro" -v "$W/mail:/mail" python:3.12-alpine python -I /sink.py >/dev/null
until docker exec e2e-pg-$$ pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
docker exec -i e2e-pg-$$ psql -U postgres -q <<'SQL'
CREATE ROLE pguser LOGIN PASSWORD 'pgpassword' NOSUPERUSER;
CREATE DATABASE e2e OWNER pguser;
SQL
docker exec e2e-pg-$$ psql -U postgres -d e2e -qc 'CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pg_trgm;'
docker run -d --name e2e-api-$$ --network "$NET" -p "127.0.0.1:$PORT:80" -v "$ROOT/lapis:/app" \
  -e POSTGRES_HOST=e2e-pg -e POSTGRES_USER=pguser -e POSTGRES_PASSWORD=pgpassword -e POSTGRES_DB=e2e \
  -e JWT_SECRET_KEY="$JWT_SECRET" -e OPENSSL_SECRET_KEY="$(openssl rand -hex 8)" -e OPENSSL_SECRET_IV="$(openssl rand -hex 8)" \
  -e PROJECT_CODE=all -e LAPIS_ENVIRONMENT=production -e OPSAPI_MAIL_ALLOW_PRIVATE=true \
  -e STRIPE_SECRET_KEY=sk_test_e2e -e STRIPE_SSL_VERIFY=false -e STRIPE_SHOP_WEBHOOK_SECRET="$WHSEC" \
  -e SHOP_BFF_KEY="$BFF_KEY" -e SHOP_ALLOWED_ORIGINS=https://shop.e2e.test -e SHOP_PUBLIC_URL=https://shop.e2e.test \
  -e SHOP_SUPPLIER_ALLOW_PRIVATE=true \
  -e GOOGLE_CLIENT_ID=e2e.apps.googleusercontent.com -e GOOGLE_CLIENT_SECRET=e2e \
  -e GOOGLE_REDIRECT_URI=https://api.e2e.test/auth/google/callback \
  -e SMTP_HOST=e2e-smtp -e SMTP_PORT=2525 -e SMTP_USER=e2e -e SMTP_PASSWORD=e2e \
  lapis-lapis >/dev/null
sleep 6; docker exec -w /app e2e-api-$$ lapis migrate >/dev/null 2>&1; docker exec e2e-api-$$ sh -c 'kill -HUP $(cat /app/logs/nginx.pid)'; sleep 2
# A shop admin: a user who creates the "workstation" namespace through the API (so the owner role and
# module permissions are set up exactly as in production), signed in with a JWT minted for this run.
docker exec e2e-pg-$$ psql -U postgres -d e2e -qc "INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) VALUES ('11111111-2222-4333-8444-555555555555','Shop','Admin','admin@e2e.invalid','shopadmin','x',true,now(),now())"
OWNER=$(python3 - "$JWT_SECRET" <<'PY'
import sys, hmac, hashlib, base64, json, time
b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
h = b({"typ": "JWT", "alg": "HS256"}); p = b({"userinfo": {"uuid": "11111111-2222-4333-8444-555555555555", "email": "admin@e2e.invalid"}, "iat": int(time.time()), "exp": int(time.time()) + 3600, "iss": "opsapi"})
print((h + b"." + p + b"." + base64.urlsafe_b64encode(hmac.new(sys.argv[1].encode(), h + b"." + p, hashlib.sha256).digest()).rstrip(b"=")).decode())
PY
)
curl -sf -o /dev/null -X POST "http://127.0.0.1:$PORT/api/v2/user/namespaces" -H "Authorization: Bearer $OWNER" \
  -H "Content-Type: application/json" -d '{"name": "Workstation", "slug": "workstation"}'
docker exec -i e2e-pg-$$ psql -U postgres -d e2e -q <<'SQL'
INSERT INTO shop_products (uuid, namespace_id, sku, slug, name, product_type, price_mode, base_price_minor, stock_qty,
                           lead_time_days, price_verified, status, created_at, updated_at)
SELECT gen_random_uuid()::text, id, v.sku, v.slug, v.name, 'gpu', 'fixed', v.price, v.stock, v.lead, true, 'active', NOW(), NOW()
  FROM namespaces, (VALUES ('E2E-6000', 'rtx-pro-6000-blackwell-workstation', 'RTX PRO 6000 (e2e)', 1299900, 100, 14),
                           ('E2E-4500', 'rtx-pro-4500-blackwell', 'RTX PRO 4500 (e2e)', 229900, 0, 42))
       AS v(sku, slug, name, price, stock, lead)
 WHERE namespaces.slug = 'workstation';
-- the workspace's own mail server: the sandbox SMTP sink (plain SMTP)
INSERT INTO namespace_mail_settings (namespace_id, host, port, security, from_email, from_name, enabled, updated_at)
SELECT id, 'e2e-smtp', 2525, 'none', 'shop@e2e.test', 'Workstation', true, NOW() FROM namespaces WHERE slug = 'workstation';
SQL
python3 -I "$HERE/check.py" "http://127.0.0.1:$PORT" "$BFF_KEY" "$WHSEC" "e2e-pg-$$" "e2e-smtp-$$" "$OWNER" "e2e-feed-$$" || {
  echo "--- API log (mail / shop-vip / errors) ---"
  docker exec e2e-api-$$ cat /var/log/nginx/error.log | grep -v "\[debug\]" | grep -i "error\|shop-vip\|mail" | tail -30; exit 1; }
