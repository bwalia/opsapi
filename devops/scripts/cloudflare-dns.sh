#!/usr/bin/env bash
#
# Idempotently upsert a DNS record in Cloudflare (CNAME by default).
#
# Running it twice is a no-op; running it after the target changes updates the
# record in place. It never creates duplicates, which is the failure mode you get
# from a naive "POST a record" step.
#
# Usage:
#   cloudflare-dns.sh --name int.beaconpulse.net --content pop0.wslproxy.com
#   cloudflare-dns.sh --name beaconpulse.net --content pop0.wslproxy.com --proxied true
#   cloudflare-dns.sh --name x.example.com --content 1.2.3.4 --type A --dry-run
#
# Environment:
#   CLOUDFLARE_API_TOKEN            Scoped API token (PREFERRED). Needs Zone:DNS:Edit,
#                                   plus Zone:Zone:Read if CLOUDFLARE_ZONE_ID is unset.
#   CLOUDFLARE_ACCOUNT_EMAIL        Legacy fallback: account email +
#   CLOUDFLARE_ACCOUNT_API_KEY      Global API Key. Grants full account access —
#                                   prefer a scoped token.
#   CLOUDFLARE_ZONE_ID              Zone id. Supplying it skips the zone lookup and
#                                   lets the token drop the Zone:Read scope.
#   CLOUDFLARE_ZONE                 Zone apex (e.g. beaconpulse.net). Used only to
#                                   look up the id when CLOUDFLARE_ZONE_ID is unset.
#   CLOUDFLARE_API_BASE             Override the API root (used by the test harness).
#
# Apex records: a CNAME at the zone apex is illegal in DNS, but Cloudflare accepts
# one and serves it via CNAME flattening. That is why prod (beaconpulse.net) works.
set -euo pipefail

API_BASE="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
RECORD_TYPE="CNAME"
TTL=1 # 1 = "automatic" in Cloudflare
PROXIED="false"
DRY_RUN="false"
NAME=""
CONTENT=""

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --content) CONTENT="${2:-}"; shift 2 ;;
    --type) RECORD_TYPE="${2:-}"; shift 2 ;;
    --ttl) TTL="${2:-}"; shift 2 ;;
    --proxied) PROXIED="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$NAME" ]] || die "--name is required"
[[ -n "$CONTENT" ]] || die "--content is required"
[[ "$PROXIED" == "true" || "$PROXIED" == "false" ]] || die "--proxied must be true or false"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

# Credentials go into a 0600 curl config file rather than -H flags, so they never
# appear in the process table (`ps` on a shared/self-hosted runner would show them).
CURL_CFG="$(mktemp)"
chmod 600 "$CURL_CFG"
trap 'rm -f "$CURL_CFG"' EXIT

if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" >>"$CURL_CFG"
elif [[ -n "${CLOUDFLARE_ACCOUNT_EMAIL:-}" && -n "${CLOUDFLARE_ACCOUNT_API_KEY:-}" ]]; then
  printf 'header = "X-Auth-Email: %s"\n' "$CLOUDFLARE_ACCOUNT_EMAIL" >>"$CURL_CFG"
  printf 'header = "X-Auth-Key: %s"\n' "$CLOUDFLARE_ACCOUNT_API_KEY" >>"$CURL_CFG"
else
  die "set CLOUDFLARE_API_TOKEN (preferred), or CLOUDFLARE_ACCOUNT_EMAIL + CLOUDFLARE_ACCOUNT_API_KEY"
fi
printf 'header = "Content-Type: application/json"\n' >>"$CURL_CFG"

# cf METHOD PATH [BODY] — calls the API and fails loudly. Cloudflare answers 200
# with {"success":false} on logical errors, so the HTTP status alone is not enough.
cf() {
  local method="$1" path="$2" body="${3:-}" resp
  if [[ -n "$body" ]]; then
    resp="$(curl -sS -K "$CURL_CFG" -X "$method" "${API_BASE}${path}" --data "$body")"
  else
    resp="$(curl -sS -K "$CURL_CFG" -X "$method" "${API_BASE}${path}")"
  fi
  if [[ "$(jq -r 'try .success catch "false"' <<<"$resp")" != "true" ]]; then
    echo "Cloudflare API error on ${method} ${path}:" >&2
    jq -r '.errors // .' <<<"$resp" >&2 || echo "$resp" >&2
    return 1
  fi
  printf '%s' "$resp"
}

# ---- resolve the zone -------------------------------------------------------
zone_id="${CLOUDFLARE_ZONE_ID:-}"
if [[ -z "$zone_id" ]]; then
  [[ -n "${CLOUDFLARE_ZONE:-}" ]] || die "set CLOUDFLARE_ZONE_ID, or CLOUDFLARE_ZONE so the id can be looked up"
  zone_id="$(cf GET "/zones?name=${CLOUDFLARE_ZONE}" | jq -r '.result[0].id // empty')"
  [[ -n "$zone_id" ]] || die "zone '${CLOUDFLARE_ZONE}' not found (token may lack Zone:Read)"
fi

# ---- find an existing record ------------------------------------------------
existing="$(cf GET "/zones/${zone_id}/dns_records?type=${RECORD_TYPE}&name=${NAME}")"

# Do NOT reach for `// empty` on proxied/ttl. jq's `//` is the *alternative*
# operator: it fires on `false` as well as `null`, so `.proxied // empty` yields
# "" for an unproxied record and the drift check below would rewrite the record on
# every single deploy. Guard on the array length instead and stringify explicitly.
rec_id="$(jq -r '.result[0].id? // ""' <<<"$existing")"
cur_content="$(jq -r '.result[0].content? // ""' <<<"$existing")"
cur_proxied="$(jq -r 'if (.result | length) > 0 then (.result[0].proxied | tostring) else "" end' <<<"$existing")"
cur_ttl="$(jq -r 'if (.result | length) > 0 then (.result[0].ttl | tostring) else "" end' <<<"$existing")"

payload="$(jq -nc \
  --arg type "$RECORD_TYPE" \
  --arg name "$NAME" \
  --arg content "$CONTENT" \
  --argjson proxied "$PROXIED" \
  --argjson ttl "$TTL" \
  '{type:$type, name:$name, content:$content, proxied:$proxied, ttl:$ttl}')"

if [[ -z "$rec_id" ]]; then
  action="create"
elif [[ "$cur_content" != "$CONTENT" || "$cur_proxied" != "$PROXIED" || "$cur_ttl" != "$TTL" ]]; then
  action="update"
else
  action="noop"
fi

if [[ "$action" == "noop" ]]; then
  echo "= ${RECORD_TYPE} ${NAME} -> ${CONTENT} (proxied=${PROXIED}) already correct"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] would ${action} ${RECORD_TYPE} ${NAME} -> ${CONTENT} (proxied=${PROXIED}, ttl=${TTL})"
  [[ "$action" == "update" ]] && echo "[dry-run]   current: ${cur_content} (proxied=${cur_proxied}, ttl=${cur_ttl})"
  exit 0
fi

if [[ "$action" == "create" ]]; then
  cf POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null
  echo "+ created ${RECORD_TYPE} ${NAME} -> ${CONTENT} (proxied=${PROXIED})"
else
  cf PUT "/zones/${zone_id}/dns_records/${rec_id}" "$payload" >/dev/null
  echo "~ updated ${RECORD_TYPE} ${NAME} -> ${CONTENT} (was ${cur_content}, proxied=${PROXIED})"
fi
