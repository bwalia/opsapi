#!/usr/bin/env bash
# Copy workstation-opsapi WSL Vault secrets from one ring to others, then
# overlay env-specific keys (DB host/password from Zalando, UI/API URLs, …).
#
# Source of truth for the bulk of keys: WSL Vault kv/data/workstation-opsapi/<src>/config
# (falls back to the synced K8s Secret <src>/workstation-opsapi-secrets if Vault
# read fails). DB password comes from the Zalando credentials Secret in the
# target namespace after workstation-opsapi-db is Running.
#
# Auth: uses the cluster's ESO token (int/wslvault-token) — same tenant as
# ClusterSecretStore wslvault-backend. Nothing is printed or written to disk.
#
#   export KUBECONFIG=~/.kube/k3s1.yaml   # or the public API override
#   ./devops/vault/copy-workstation-opsapi-secrets.sh test acc
#   DRY_RUN=1 ./devops/vault/copy-workstation-opsapi-secrets.sh test
#   FORCE=1  …                              # overwrite an existing target path
#   SRC_ENV=int …                           # default int
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.workstation.co.uk}"
SRC_ENV="${SRC_ENV:-int}"
DB_NAME="${DB_NAME:-workstation-opsapi-db}"
[ $# -gt 0 ] || { echo "usage: $0 <target-env>... (e.g. test acc)"; exit 2; }

json_field() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1') or '')"; }

# Prefer an explicit token; otherwise pull the ESO token from the cluster.
if [ -z "${WSLVAULT_TOKEN:-}" ]; then
  WSLVAULT_TOKEN=$(kubectl -n int get secret wslvault-token -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$WSLVAULT_TOKEN" ] || { echo "could not read int/wslvault-token — set WSLVAULT_TOKEN"; exit 1; }
  echo "using ESO token from int/wslvault-token"
fi

# Load source blob from Vault (preferred) or the synced K8s Secret.
load_src() {
  local url="${VAULT_ADDR}/v1/kv/data/workstation-opsapi/${SRC_ENV}/config"
  local body code
  body=$(curl -sk --max-time 30 -w '\n%{http_code}' -H "X-Vault-Token: ${WSLVAULT_TOKEN}" "$url")
  code=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')
  if [ "$code" = "200" ]; then
    printf '%s' "$body" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(((d.get("data") or {}).get("data")) or {}))'
    echo "source: vault workstation-opsapi/${SRC_ENV}/config" >&2
    return
  fi
  echo "vault read ${SRC_ENV} HTTP ${code} — falling back to K8s Secret" >&2
  kubectl -n "$SRC_ENV" get secret workstation-opsapi-secrets -o json \
    | python3 -c 'import sys,json,base64; d=json.load(sys.stdin)["data"]; print(json.dumps({k: base64.b64decode(v).decode() for k,v in d.items() if k != "LAPIS_CONFIG_LUA_FILE"}))'
  echo "source: secret ${SRC_ENV}/workstation-opsapi-secrets" >&2
}

SRC_JSON=$(load_src)
SRC_KEYS=$(printf '%s' "$SRC_JSON" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
echo "loaded ${SRC_KEYS} keys from ${SRC_ENV}"

zalando_password() {
  local ns="$1"
  local secret="pguser.${DB_NAME}.credentials.postgresql.acid.zalan.do"
  kubectl -n "$ns" get secret "$secret" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

overlay_for_env() {
  local env="$1" pw="$2"
  # stdin: source JSON → stdout: target JSON with overlays.
  # Must use python -c (not a heredoc) so sys.stdin stays the pipe.
  TARGET_ENV="$env" DB_NAME="$DB_NAME" PG_PASSWORD="$pw" python3 -c '
import json, os, sys
src = json.load(sys.stdin)
env = os.environ["TARGET_ENV"]
db = os.environ["DB_NAME"]
pw = os.environ["PG_PASSWORD"]
host = f"{db}.{env}.svc.cluster.local"
ui = f"https://{env}-opsapi-ui.workstation.co.uk" if env != "prod" else "https://opsapi-ui.workstation.co.uk"
api = f"https://{env}-opsapi.workstation.co.uk" if env != "prod" else "https://opsapi.workstation.co.uk"
src.pop("LAPIS_CONFIG_LUA_FILE", None)
out = dict(src)
out.update({
    "ENVIRONMENT": env,
    "PROJECT_CODE": "all",
    "POSTGRES_HOST": host,
    "POSTGRES_DB": "workstation_opsapi",
    "POSTGRES_USER": "pguser",
    "POSTGRES_PORT": "5432",
    "POSTGRES_PASSWORD": pw,
    "DATABASE": "workstation_opsapi",
    "DB_HOST": host,
    "DB_USER": "pguser",
    "DB_PASSWORD": pw,
    "DB_PORT": "5432",
    "FRONTEND_URL": ui,
    "APP_BASE_URL": ui,
    "APP_DOMAIN": ui.replace("https://", ""),
    "API_DOMAIN": api.replace("https://", ""),
    "LAPIS_API_URL": api,
    "NEXT_PUBLIC_API_URL": api,
    "NEXT_PUBLIC_LAPIS_API_URL": api,
    # Shared int MinIO for now (separate buckets). Per-env MinIO can follow later.
    "MINIO_ENDPOINT": "http://workstation-minio.int.svc.cluster.local:9000",
    "MINIO_PUBLIC_URL": "https://int-minio.workstation.co.uk",
    "MINIO_BUCKET": f"opsapi-{env}",
    "CORS_ALLOWED_DOMAINS": "workstation.co.uk,workstation.academy",
    "AUTH_COOKIE_TRUSTED_DOMAINS": "workstation.co.uk",
})
print(json.dumps(out))
'
}

fail=0
for env in "$@"; do
  url="${VAULT_ADDR}/v1/kv/data/workstation-opsapi/${env}/config"
  code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${WSLVAULT_TOKEN}" "$url")
  case "$code" in
    401|403) echo "${env}: vault rejected token (HTTP ${code})"; exit 1 ;;
    200) [ "${FORCE:-0}" = "1" ] || { echo "${env}: already exists — skipped (FORCE=1 to overwrite)"; continue; } ;;
  esac

  kubectl -n "$env" get postgresql "$DB_NAME" >/dev/null 2>&1 \
    || { echo "${env}: postgresql/${DB_NAME} missing — apply devops/k8s/workstation-db-${env}.yaml first"; fail=1; continue; }
  status=$(kubectl -n "$env" get postgresql "$DB_NAME" -o jsonpath='{.status.PostgresClusterStatus}' 2>/dev/null || true)
  [ "$status" = "Running" ] || { echo "${env}: db status=${status:-unknown} (want Running)"; fail=1; continue; }

  pw=$(zalando_password "$env")
  [ -n "$pw" ] || { echo "${env}: no Zalando pguser password secret yet"; fail=1; continue; }

  payload=$(printf '%s' "$SRC_JSON" | overlay_for_env "$env" "$pw")
  nkeys=$(printf '%s' "$payload" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')

  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "${env}: would write ${nkeys} keys → workstation-opsapi/${env}/config (path now HTTP ${code})"
    continue
  fi

  status=$(printf '%s' "$payload" | python3 -c 'import sys,json; print(json.dumps({"data": json.load(sys.stdin)}))' \
    | curl -sk --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
        -H "X-Vault-Token: ${WSLVAULT_TOKEN}" -H 'Content-Type: application/json' --data-binary @- "$url")
  if [ "${status:0:1}" != "2" ]; then
    echo "${env}: write FAILED (HTTP ${status})"; fail=1; continue
  fi
  stored=$(curl -sk --max-time 20 -H "X-Vault-Token: ${WSLVAULT_TOKEN}" "$url" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(((d.get("data") or {}).get("data")) or {}))')
  echo "${env}: wrote workstation-opsapi/${env}/config — ${stored} keys (HTTP ${status})"
  [ "$stored" = "$nkeys" ] || fail=1
done
exit $fail
