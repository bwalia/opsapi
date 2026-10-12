#!/usr/bin/env bash
# One-command reset of the How It Works fixtures in a workspace.
#   OPSAPI=https://int-opsapi.example TOKEN=<jwt> NS=<namespace slug> scripts/reset-demo.sh [sophie_uuid] [ashley_uuid]
# TOKEN must be a platform admin's (the route is hidden from everyone else). Only rows tagged
# metadata.fixture = "how_it_works" are removed and re-created; a fixture real work points at is kept.
set -euo pipefail
: "${OPSAPI:?set OPSAPI}" "${TOKEN:?set TOKEN}" "${NS:?set NS (namespace slug)}"
body=$(printf '{%s%s}' "${1:+\"sophie_user_uuid\":\"$1\"}" "${2:+${1:+,}\"ashley_user_uuid\":\"$2\"}")
curl -fsS -X POST "$OPSAPI/api/v2/property-pa/demo/reset" -H "Authorization: Bearer $TOKEN" \
  -H "X-Namespace-Slug: $NS" -H "Content-Type: application/json" -d "$body"
echo
