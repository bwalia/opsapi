#!/usr/bin/env bash
# Write the Daybook demo's secrets to WSLVault (https://vault.workstation.co.uk, KV v2
# mount `kv`), one set per Ring Promoter ring, like jobshout's `jobshout/<ring>/<name>`:
#
#   daybook-demo/<ring>/config  POSTGRES_* , JWT_SECRET_KEY, OPENSSL_SECRET_KEY/IV,
#                               ADMIN_PASSWORD: fresh random values (same generator as
#                               devops/demo/seed-vault-demo.sh). Read by the API chart's
#                               ExternalSecret and the DB's (devops/k8s/daybook-demo-db.yaml).
#   daybook-demo/<ring>/login   DEMO_PASSWORD: the PUBLISHED demo password
#                               (daybook.co.uk/demos), kept out of git for secret scanners.
#
# Nothing is printed or written to disk. An existing path is SKIPPED (FORCE=1 overwrites
# `config`: that logs everyone out and makes encrypted data unreadable, so only on a fresh
# ring; `login` is safe to overwrite).
#
#   export WSLVAULT_API_KEY='wslv_…'                       # or WSLVAULT_TOKEN='eyJ…'
#   RING=int ./devops/daybook-demo/seed-vault-daybook.sh   # or RING=all; DRY_RUN=1 to preview
#   (asks for DEMO_PASSWORD without echo unless it's in the environment)
#
# Then, for "Connect to HMRC" in the demo only, add the HMRC SANDBOX application's
# HMRC_CLIENT_ID and HMRC_CLIENT_SECRET to daybook-demo/<ring>/config in the Vault UI.
set -euo pipefail
VAULT_ADDR="${VAULT_ADDR:-https://vault.workstation.co.uk}"
: "${RING:?set RING=int|test|acc|prod|all}"
case "$RING" in
  all) RINGS="int test acc prod" ;;
  int|test|acc|prod) RINGS="$RING" ;;
  *) echo "RING must be int, test, acc, prod or all"; exit 1 ;;
esac

json_field() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1') or '')"; }

if [ "${DRY_RUN:-0}" != "1" ] && [ -z "${DEMO_PASSWORD:-}" ]; then
  read -r -s -p "Published demo password (DEMO_PASSWORD): " DEMO_PASSWORD; echo
  [ "${#DEMO_PASSWORD}" -ge 12 ] || { echo "DEMO_PASSWORD must be 12+ characters"; exit 1; }
fi
export DEMO_PASSWORD="${DEMO_PASSWORD:-}"

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
  echo "signed in to WSLVault"
fi

# write <path> <kind> <force>: kind is config (random keys) or login (DEMO_PASSWORD).
write() {
  local path="$1" kind="$2" force="$3" url code status
  url="${VAULT_ADDR}/v1/kv/data/${path}"
  code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${WSLVAULT_TOKEN}" "$url")
  case "$code" in
    401|403) echo "WSLVault rejected the token (HTTP ${code}) — nothing written"; exit 1 ;;
    200) [ "$force" = "1" ] || { echo "${path} already exists - skipped"; return 0; } ;;
  esac
  if [ "${DRY_RUN:-0}" = "1" ]; then echo "would write ${path} (now HTTP ${code})"; return 0; fi
  # OPENSSL_SECRET_KEY / IV are 32 hex chars, matching lapis/.sample.env.
  status=$(KIND="$kind" python3 - <<'PY' | curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
      -H "X-Vault-Token: ${WSLVAULT_TOKEN}" -H 'Content-Type: application/json' --data-binary @- "$url"
import json, os, secrets
if os.environ["KIND"] == "login":
    data = {"DEMO_PASSWORD": os.environ["DEMO_PASSWORD"]}
else:
    data = {
        "POSTGRES_USER": "pguser",
        "POSTGRES_PASSWORD": secrets.token_urlsafe(32),
        "POSTGRES_PORT": "5432",
        "JWT_SECRET_KEY": secrets.token_urlsafe(48),
        "OPENSSL_SECRET_KEY": secrets.token_hex(16),
        "OPENSSL_SECRET_IV": secrets.token_hex(16),
        "ADMIN_PASSWORD": secrets.token_urlsafe(18),
    }
print(json.dumps({"data": data}))
PY
  )
  [ "${status:0:1}" = "2" ] || { echo "write ${path} FAILED (HTTP ${status})"; exit 1; }
  echo "wrote ${path} (HTTP ${status})"
}

for r in $RINGS; do
  write "daybook-demo/${r}/config" config "${FORCE:-0}"
  write "daybook-demo/${r}/login"  login  "${FORCE_LOGIN:-${FORCE:-0}}"
done
echo "done. The platform admin password is ADMIN_PASSWORD in daybook-demo/<ring>/config."
