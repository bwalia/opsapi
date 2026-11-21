#!/usr/bin/env bash
# Write the Daybook demo's secrets to WSL Vault (kv/data/daybook-demo/config), once.
# Same generator as the OpsAPI demos (fresh random DB password, JWT key, encryption
# key/IV, ADMIN_PASSWORD); nothing is printed or written to disk. Skips an existing
# path (FORCE=1 overwrites: logs everyone out, so only on a fresh demo).
#
#   export WSLVAULT_API_KEY='wslv_…'                 # or WSLVAULT_TOKEN='eyJ…'
#   ./devops/daybook-demo/seed-vault-daybook.sh      # DRY_RUN=1 to preview
#
# Then add, in the Vault UI, the HMRC SANDBOX application's HMRC_CLIENT_ID and
# HMRC_CLIENT_SECRET to the same path (only needed for "Connect to HMRC" in the
# demo; everything else works without them).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
VAULT_PATH="${VAULT_PATH:-daybook-demo/config}" exec "$here/../demo/seed-vault-demo.sh" "$@"
