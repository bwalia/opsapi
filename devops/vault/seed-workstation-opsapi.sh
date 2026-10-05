#!/usr/bin/env bash
# Copy opsapi.workstation.co.uk's secrets from the cluster into WSL Vault, once.
#
# Source: the Secret the workstation release runs on today — the blob both it and
# the diy API were synced from HC Vault (secret/diytaxreturnuk/opsapi/<env>/config),
# read here from <env>/diytaxreturn-lapis-secrets (identical key-for-key to
# workstation-opsapi-secrets minus its generated LAPIS_CONFIG_LUA_FILE).
# Target: WSL Vault kv/data/workstation-opsapi/<env>/config.
#
# Values go cluster -> pipe -> Vault; nothing is printed or written to disk.
# An env whose path already exists is SKIPPED (set FORCE=1 to overwrite).
#
# Auth — either:
#   WSLVAULT_API_KEY='wslv_…'   an API key; exchanged here for a token (asks for
#                               your 6-digit authenticator code if the key needs MFA)
#   WSLVAULT_TOKEN='eyJ…'       an already-exchanged token (JWT)
# Use a key of the SAME tenant External Secrets reads from (wslvault-backend),
# or ESO won't see what you write.
#
#   export KUBECONFIG=~/.kube/k3s1.yaml
#   ./devops/vault/seed-workstation-opsapi.sh prod int     # DRY_RUN=1 to preview
set -euo pipefail
VAULT_ADDR="${VAULT_ADDR:-https://vault.workstation.co.uk}"
[ $# -gt 0 ] || { echo "usage: $0 <env>... (e.g. prod int)"; exit 2; }

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

fail=0
for env in "$@"; do
  url="${VAULT_ADDR}/v1/kv/data/workstation-opsapi/${env}/config"
  code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${WSLVAULT_TOKEN}" "$url")
  case "$code" in
    401|403) echo "${env}: WSL Vault rejected the token (HTTP ${code}) — nothing written. Use a token/API key that can write workstation-opsapi/*."; exit 1 ;;
    200) [ "${FORCE:-0}" = "1" ] || { echo "${env}: workstation-opsapi/${env}/config already exists - skipped (FORCE=1 to overwrite)"; continue; } ;;
  esac
  keys=$(kubectl get secret -n "$env" diytaxreturn-lapis-secrets -o json | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["data"]))')
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "${env}: would write ${keys} keys to workstation-opsapi/${env}/config (path now: HTTP ${code})"; continue
  fi
  status=$(kubectl get secret -n "$env" diytaxreturn-lapis-secrets -o json \
    | python3 -c 'import sys,json,base64; d=json.load(sys.stdin)["data"]; print(json.dumps({"data": {k: base64.b64decode(v).decode() for k, v in d.items()}}))' \
    | curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
        -H "X-Vault-Token: ${WSLVAULT_TOKEN}" -H 'Content-Type: application/json' --data-binary @- "$url")
  if [ "${status:0:1}" != "2" ]; then
    echo "${env}: write FAILED (HTTP ${status}) — nothing written"; fail=1; continue
  fi
  stored=$(curl -sS --max-time 20 -H "X-Vault-Token: ${WSLVAULT_TOKEN}" "$url" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(((d.get("data") or {}).get("data")) or {}))')
  echo "${env}: wrote workstation-opsapi/${env}/config — ${stored} of ${keys} keys stored (HTTP ${status})"
  [ "$stored" = "$keys" ] || fail=1
done
exit $fail
