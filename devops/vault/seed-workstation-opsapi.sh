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
#   export KUBECONFIG=~/.kube/k3s1.yaml
#   export WSLVAULT_TOKEN='<wslvault JWT that can write workstation-opsapi/*>'
#   ./devops/vault/seed-workstation-opsapi.sh prod int     # DRY_RUN=1 to preview
set -euo pipefail
: "${WSLVAULT_TOKEN:?set WSLVAULT_TOKEN to a wslvault JWT that can write workstation-opsapi/*}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.workstation.co.uk}"
[ $# -gt 0 ] || { echo "usage: $0 <env>... (e.g. prod int)"; exit 2; }

for env in "$@"; do
  url="${VAULT_ADDR}/v1/kv/data/workstation-opsapi/${env}/config"
  code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${WSLVAULT_TOKEN}" "$url")
  if [ "$code" = "200" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "${env}: workstation-opsapi/${env}/config already exists - skipped (FORCE=1 to overwrite)"; continue
  fi
  keys=$(kubectl get secret -n "$env" diytaxreturn-lapis-secrets -o json | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["data"]))')
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "${env}: would write ${keys} keys to workstation-opsapi/${env}/config (path now: HTTP ${code})"; continue
  fi
  status=$(kubectl get secret -n "$env" diytaxreturn-lapis-secrets -o json \
    | python3 -c 'import sys,json,base64; d=json.load(sys.stdin)["data"]; print(json.dumps({"data": {k: base64.b64decode(v).decode() for k, v in d.items()}}))' \
    | curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
        -H "X-Vault-Token: ${WSLVAULT_TOKEN}" -H 'Content-Type: application/json' --data-binary @- "$url")
  echo "${env}: wrote ${keys} keys to workstation-opsapi/${env}/config (HTTP ${status})"
done
