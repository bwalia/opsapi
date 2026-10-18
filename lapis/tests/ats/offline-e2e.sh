#!/usr/bin/env bash
# End-to-end check of offline interviews and recruiter sign-up against a running OpsAPI
# (PROJECT_CODE including `ats`). No secrets in this file: every account and token is made here.
#
#   lapis/tests/ats/offline-e2e.sh [base_url]          default http://127.0.0.1:4020
#
# Activating the new workspace needs one of (else the invite steps are skipped):
#   OPSAPI_PSQL   a psql command reading SQL on stdin, e.g.
#                 OPSAPI_PSQL="docker exec -i opsapi-postgres-dev-db psql -U pguser -d opsapi -tA"
#                 (also turns the new workspace's sign-in code off, to test sign-in end to end)
#   ADMIN_JWT     a platform admin's JWT (POST /api/v2/ats/admin/activation)
#
# E2E_SAVE_FILE=<path> also saves the downloaded .snazzy_interview there.
# Needs curl and jq.
set -euo pipefail

BASE="${1:-${BASE_URL:-http://127.0.0.1:4020}}"
BASE="${BASE%/}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$HERE/fixtures/interview-kit.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }

# req METHOD PATH [JSON] [TOKEN] -> body in $TMP/body, status in $STATUS
req() {
    local method="$1" path="$2" data="${3:-}" token="${4:-}"
    local args=(-s -o "$TMP/body" -w '%{http_code}' -X "$method" -H 'Content-Type: application/json')
    [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
    [ -n "$data" ] && args+=(--data-binary "$data")
    STATUS="$(curl "${args[@]}" -D "$TMP/headers" "$BASE$path")"
    local wait
    wait="$(awk 'tolower($1) == "retry-after:" {print $2+0}' "$TMP/headers")"
    if [ "$STATUS" = 429 ] && [ "${wait:-999}" -le 65 ]; then # per-link limits are per minute: wait once, retry
        sleep "$((wait + 1))"
        STATUS="$(curl "${args[@]}" -D "$TMP/headers" "$BASE$path")"
    fi
}
body() { cat "$TMP/body"; }
field() { jq -r "$1" "$TMP/body"; }
expect() { # expect STATUS [jq-boolean] description
    local want="$1" cond="${2:-true}" what="$3"
    if [ "$STATUS" = "$want" ] && [ "$(jq -r "$cond" "$TMP/body" 2>/dev/null)" = "true" ]; then ok "$what"
    else bad "$what (HTTP $STATUS: $(head -c 400 "$TMP/body"))"; fi
}
sql() { [ -n "${OPSAPI_PSQL:-}" ] && echo "$1" | $OPSAPI_PSQL; }

STAMP="$(date +%s)$RANDOM"
EMAIL="recruiter.$STAMP@example.com"
PASSWORD="Offline-e2e-$(openssl rand -hex 6)-Zq9"
DEVICE_A="mac-a-$(openssl rand -hex 12)"
DEVICE_B="mac-b-$(openssl rand -hex 12)"

echo "OpsAPI at $BASE"

echo "Recruiter sign-up"
req POST /api/v2/public/ats/recruiters/register "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" \
    '{company:"Offline E2E Ltd", first_name:"Robin", last_name:"Recruiter", email:$e, password:$p, device_name:"Test Mac"}')"
if [ "$STATUS" = 429 ]; then
    echo "  stop sign-up is limited to 5 an hour per address (each run uses 2): wait, or clear the"
    echo "       rl:ats:reg-ip:* keys in the API's Redis"
    exit 1
fi
expect 201 '(.data.token | startswith("snz_")) and .data.namespace.uuid != null' "register returns a token"
TOKEN="$(field .data.token)"
NS_UUID="$(field .data.namespace.uuid)"
req POST /api/v2/public/ats/recruiters/register "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" \
    '{company:"Again", first_name:"R", last_name:"R", email:$e, password:$p}')"
expect 409 '.code == "email_taken"' "the same email again is refused"

echo "Recruiter sign-in"
req POST /api/v2/public/ats/recruiters/sign-in "$(jq -n --arg e "$EMAIL" '{email:$e, password:"Wrong-password-123"}')"
expect 401 '.code == "wrong_credentials"' "a wrong password is refused"
req POST /api/v2/public/ats/recruiters/sign-in "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')"
expect 403 '.code == "mfa_required"' "an account asked for a sign-in code gets no token"
if [ -n "${OPSAPI_PSQL:-}" ]; then
    sql "UPDATE namespaces SET mfa_required = false WHERE id IN (SELECT m.namespace_id FROM namespace_members m
         JOIN users u ON u.id = m.user_id WHERE u.email = '$EMAIL');" >/dev/null
    req POST /api/v2/public/ats/recruiters/sign-in "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" \
        '{email:$e, password:$p, device_name:"Second Mac"}')"
    expect 200 '(.data.token | startswith("snz_")) and .data.namespace.uuid != null' "sign-in returns a token"
fi

req GET /api/v2/public/ats/integration/ping "" "$TOKEN"
expect 200 '.data.namespace_uuid != null' "the token works"

echo "Activation"
if [ -n "${OPSAPI_PSQL:-}" ]; then
    sql "INSERT INTO ats_module_activations (namespace_id, status, source, activated_at)
         SELECT id, 'active', 'manual', NOW() FROM namespaces WHERE uuid = '$NS_UUID'
         ON CONFLICT (namespace_id) DO UPDATE SET status = 'active', source = 'manual', expires_at = NULL;" >/dev/null
elif [ -n "${ADMIN_JWT:-}" ]; then
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $ADMIN_JWT" -H 'Content-Type: application/json' \
        --data "{\"namespace_uuid\":\"$NS_UUID\",\"status\":\"active\"}" "$BASE/api/v2/ats/admin/activation"
fi
req GET /api/v2/public/ats/integration/ping "" "$TOKEN"
if [ "$(field .data.active)" != "true" ]; then
    echo "  skip the workspace isn't active (set OPSAPI_PSQL or ADMIN_JWT); stopping here"
    echo "E2E: $pass passed, $fail failed"
    [ "$fail" = 0 ]; exit
fi
ok "the workspace is active"

echo "Offline invites"
KIT="$(jq '.id = "e2e-kit-'"$STAMP"'"' "$FIXTURE")"
req POST /api/v2/public/ats/integration/invites "$(jq -n --argjson k "$KIT" \
    '{kit:$k, delivery:"carrier-pigeon", candidates:[{name:"Sam Taylor", email:"sam@example.com"}]}')" "$TOKEN"
expect 422 '.success == false' "an unknown delivery is refused"
req POST /api/v2/public/ats/integration/invites "$(jq -n --argjson k "$KIT" --arg s "$STAMP" \
    '{kit:$k, delivery:"offline", candidates:[{name:"Sam Taylor", email:("sam."+$s+"@example.com")},
      {name:"Alex Kim", email:("alex."+$s+"@example.com")}]}')" "$TOKEN"
expect 201 '.data.invited == 2 and (.data.results[0].app_url | startswith("snazzypro://interview?link="))' \
    "bulk offline invite returns app links"
URL="$(field '.data.results[0].url')"
UUID="$(field '.data.results[0].uuid')"
LINK="$(echo "$URL" | sed -E 's#.*/i/([^?]+).*#\1#')"

req GET "/api/v2/public/ats/interviews/$LINK"
expect 200 '.data.delivery == "offline" and .data.state == "invited"' "the candidate view says offline"
req POST "/api/v2/public/ats/interviews/$LINK/start" '{"notice_hash":"x"}'
expect 409 '.success == false' "an offline interview can't start in the browser"

echo "The app fetches the interview"
req POST "/api/v2/public/ats/interviews/$LINK/offline" "{\"device_id\":\"$DEVICE_A\"}"
expect 200 '.data.kit.id != null and ([.data.kit.competencies[].anchors[]] | all(. == "")) and .data.pack == null
    and (.data.notice | contains("on your own computer")) and .data.upload_by != null and .data.candidate.name == "Sam Taylor"' \
    "offline: candidate-safe kit, offline notice, no pack"
cp "$TMP/body" "$TMP/offline.json"
req POST "/api/v2/public/ats/interviews/$LINK/offline" "{\"device_id\":\"$DEVICE_A\"}"
expect 200 '.data.interview_uuid != null' "the same device can fetch it again"
req POST "/api/v2/public/ats/interviews/$LINK/offline" "{\"device_id\":\"$DEVICE_B\"}"
expect 403 '.code == "device_in_use"' "another device is refused"
req POST "/api/v2/public/ats/interviews/$LINK/offline" '{"device_id":"short"}'
expect 400 '.success == false' "a missing device id is refused"

# The app's .snazzy_interview, built from the kit it was given.
session() { # session ID
    jq --arg id "$1" '
      .data as $d | $d.kit as $k | (now - 240 | todate) as $start | (now - 5 | todate) as $end |
      def T(i; role; kind; text; q): {id: ("t" + (i|tostring)), role: role, kind: kind, text: text,
        question_id: q, at: $start, input: (if role == "candidate" then "typed" else null end)};
      {format: "snazzy-interview", version: 1, exported_at: $end, app: "Snazzy Pro e2e",
       interview: {id: $id, kit: $k, candidate: {name: $d.candidate.name}, channel: "this_mac",
         state: "completed", notice_hash: $d.notice_hash, notice_accepted_at: $start,
         started_at: $start, ended_at: $end, end_reason: "completed",
         offline: {interview_uuid: $d.interview_uuid, upload_by: $d.upload_by},
         turns: ([T(1; "interviewer"; "opening"; "Hello Sam, I am the AI interviewer."; null)]
           + ([$k.eligibility[], $k.questions[]] | to_entries | map(
               T(2 + .key * 2; "interviewer"; (if .value.competency then "core" else "eligibility" end);
                 .value.text; .value.id),
               T(3 + .key * 2; "candidate"; "answer";
                 (if .value.competency then "I coached a new adviser for two weeks; her resolution rate rose."
                  else "Yes" end); .value.id)))
           + [T(20; "interviewer"; "candidate_question"; "Do you have any questions for me?"; null),
              T(21; "candidate"; "candidate_question"; "No questions."; null),
              T(22; "interviewer"; "closing"; "Thank you for your time today."; null)]),
         flags: [], eligibility_answers: {e1: "Yes", e2: "Yes"}, adjustments: [],
         models: {interviewer: "apple-on-device"},
         evaluation: {competencies: [{id: "c1", level: 5, evidence: []}]},
         review: {reviewer: "Not a person", decision: "advance"}}}' "$TMP/offline.json"
}
new_uuid() { (uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid) | tr 'A-Z' 'a-z'; }
ID1="$(new_uuid)"
ID2="$(new_uuid)"
FILE1="$(session "$ID1")"

echo "The app uploads the result"
req POST "/api/v2/public/ats/interviews/$LINK/result" "$(jq -n --arg d "$DEVICE_B" --argjson f "$FILE1" '{device_id:$d, interview:$f}')"
expect 403 '.code == "device_in_use"' "result: another device is refused"
BADKIT="$(echo "$FILE1" | jq '.interview.kit.id = "someone-else"')"
req POST "/api/v2/public/ats/interviews/$LINK/result" "$(jq -n --arg d "$DEVICE_A" --argjson f "$BADKIT" '{device_id:$d, interview:$f}')"
expect 422 '.error | contains("different interview")' "result: a different kit is refused"
BADHASH="$(echo "$FILE1" | jq '.interview.notice_hash = "0123456789abcdef"')"
req POST "/api/v2/public/ats/interviews/$LINK/result" "$(jq -n --arg d "$DEVICE_A" --argjson f "$BADHASH" '{device_id:$d, interview:$f}')"
expect 422 '.success == false' "result: another notice is refused"
req POST "/api/v2/public/ats/interviews/$LINK/result" "$(jq -n --arg d "$DEVICE_A" --argjson f "$FILE1" '{device_id:$d, interview:$f}')"
expect 200 '.data.state == "completed" and .data.delivery == "offline" and (.data.self_id | type) == "array"' \
    "result: accepted, completed, self-ID offered"
req POST "/api/v2/public/ats/interviews/$LINK/result" "$(jq -n --arg d "$DEVICE_A" --argjson f "$FILE1" '{device_id:$d, interview:$f}')"
expect 200 '.data.state == "completed"' "result: the same upload again is fine"
req POST "/api/v2/public/ats/interviews/$LINK/result" "$(jq -n --arg d "$DEVICE_A" --argjson f "$(session "$ID2")" \
    '{device_id:$d, interview:$f}')"
expect 409 '.code == "already_sent"' "result: a second, different upload is refused"
req POST "/api/v2/public/ats/interviews/$LINK/offline" "{\"device_id\":\"$DEVICE_A\"}"
expect 410 '.code == "finished"' "offline: a finished interview can't be fetched again"
req POST "/api/v2/public/ats/interviews/$LINK/self-id" '{"answers":{}}'
expect 200 '.data.saved == true' "self-ID works after an offline interview"

echo "The recruiter's app fetches results"
req GET "/api/v2/public/ats/integration/interviews?delivery=offline&per_page=50" "" "$TOKEN"
if [ "$STATUS" = 200 ] && [ "$(jq -r --arg u "$UUID" '[.data[] | select(.uuid == $u and .state == "completed"
        and .delivery == "offline" and .result_uploaded_at != null)] | length' "$TMP/body")" = 1 ]; then
    ok "list: the offline interview is there, completed"
else bad "list: $(head -c 400 "$TMP/body")"; fi
expect 200 '.meta.total >= 2' "list: pagination meta"
req GET "/api/v2/public/ats/integration/interviews?since=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 hour' 2>/dev/null \
    || date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)" "" "$TOKEN"
expect 200 '(.data | length) == 0' "list: since filters by last change"
req GET "/api/v2/public/ats/integration/interviews?since=yesterday" "" "$TOKEN"
expect 422 '.success == false' "list: a bad since is refused"
req GET "/api/v2/public/ats/integration/interviews/$UUID" "" "$TOKEN"
if [ "$STATUS" = 200 ] && [ "$(jq -r --arg id "$ID1" '.data.file.format == "snazzy-interview" and .data.file.interview.id == $id
        and .data.file.interview.state == "completed" and .data.delivery == "offline"
        and (.data.file.interview.kit.competencies[0].anchors["1"] | length) > 0
        and (.data.file.interview.review == null)' "$TMP/body")" = true ]; then
    ok "file: a .snazzy_interview with the server's full kit and no device review"
    [ -n "${E2E_SAVE_FILE:-}" ] && jq '.data.file' "$TMP/body" > "$E2E_SAVE_FILE"
else bad "file: $(head -c 600 "$TMP/body")"; fi
req GET "/api/v2/public/ats/integration/interviews/00000000-0000-0000-0000-000000000000" "" "$TOKEN"
expect 404 '.success == false' "file: another interview is not found"

echo "E2E: $pass passed, $fail failed"
[ "$fail" = 0 ]
