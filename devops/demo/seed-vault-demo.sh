#!/usr/bin/env bash
# Write the opsapi-demo secrets to WSL Vault (kv/data/opsapi-demo/config), once.
#
# Generates fresh random values for the DB password, JWT key and encryption
# key/IV; GOOGLE_CLIENT_SECRET comes from your environment. Values go straight
# to Vault — nothing is printed or written to disk. If the path already exists
# it is SKIPPED (FORCE=1 to overwrite — that logs every user out and makes
# already-encrypted data unreadable, so only do it on a fresh demo).
#
#   export WSLVAULT_API_KEY='wslv_…'          # or WSLVAULT_TOKEN='eyJ…'
#   export GOOGLE_CLIENT_SECRET='GOCSPX-…'
#   ./devops/demo/seed-vault-demo.sh          # DRY_RUN=1 to preview
set -euo pipefail
VAULT_ADDR="${VAULT_ADDR:-https://vault.workstation.co.uk}"
: "${GOOGLE_CLIENT_SECRET:?set GOOGLE_CLIENT_SECRET (the demo Google OAuth client secret)}"

json_field() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1') or '')"; }

if [ -z "${WSLVAULT_TOKEN:-}" ]; then
  : "${WSLVAULT_API_KEY:?set WSLVAULT_API_KEY (wslv_...) or WSLVAULT_TOKEN}"
  resp=$(printf '{"api_key":"%s"}' "$WSLVAULT_API_KEY" | curl -sS --max-time 20 -X POST \
    -H 'Content-Type: application/json' --data-binary @- "${VAULT_ADDR}/v1/auth/api-key")
  WSLVAULT_TOKEN=$(printf '%s' "$resp" | json_field token)
  if [ -z "$WSLVAULT_TOKEN" ]; then
    challenge=$(printf '%s' "$resp" | json_field challenge)
    [ -n "$challenge" ] || { echo "API key exchange refused — check WSLVAULT_API_KEY"; exit 1; }
    read -r -p "Authenticator code (6 digits): " code
    WSLVAULT_TOKEN=$(printf '{"challenge":"%s","code":"%s"}' "$challenge" "$code" | curl -sS --max-time 20 \
      -X POST -H 'Content-Type: application/json' --data-binary @- "${VAULT_ADDR}/v1/auth/mfa/totp" | json_field token)
    [ -n "$WSLVAULT_TOKEN" ] || { echo "MFA code refused (or the 120s challenge expired) — run again"; exit 1; }
  fi
  echo "signed in to WSL Vault"
fi

url="${VAULT_ADDR}/v1/kv/data/opsapi-demo/config"
code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${WSLVAULT_TOKEN}" "$url")
case "$code" in
  401|403) echo "WSL Vault rejected the token (HTTP ${code}) — nothing written"; exit 1 ;;
  200) [ "${FORCE:-0}" = "1" ] || { echo "opsapi-demo/config already exists - skipped (FORCE=1 to overwrite)"; exit 0; } ;;
esac
if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "would write 8 keys to opsapi-demo/config (path now: HTTP ${code})"; exit 0
fi

# OPENSSL_SECRET_KEY / IV are 32 hex chars, matching lapis/.sample.env.
status=$(python3 - <<'PY' | curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
    -H "X-Vault-Token: ${WSLVAULT_TOKEN}" -H 'Content-Type: application/json' --data-binary @- "$url"
import json, os, secrets
print(json.dumps({"data": {
    "POSTGRES_USER": "pguser",
    "POSTGRES_PASSWORD": secrets.token_urlsafe(32),
    "POSTGRES_PORT": "5432",
    "JWT_SECRET_KEY": secrets.token_urlsafe(48),
    "OPENSSL_SECRET_KEY": secrets.token_hex(16),
    "OPENSSL_SECRET_IV": secrets.token_hex(16),
    "GOOGLE_CLIENT_SECRET": os.environ["GOOGLE_CLIENT_SECRET"],
    "ADMIN_PASSWORD": secrets.token_urlsafe(18),
}}))
PY
)
[ "${status:0:1}" = "2" ] || { echo "write FAILED (HTTP ${status}) — nothing written"; exit 1; }
echo "wrote opsapi-demo/config (HTTP ${status}). The admin password is ADMIN_PASSWORD in that path."
