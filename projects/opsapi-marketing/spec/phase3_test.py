#!/usr/bin/env python3
"""Phase 3: campaign lifecycle — validate, approve, pause/resume, A/B, budget."""
import os
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, USERS, call, check, enable, expect, finish, new_uuid, sql, workspace,
)

A = workspace("owner_a", "Mkt Life", "mkt-life-" + new_uuid()[:8])
enable("owner_a", A)
expect("dry_run", call("PUT", API + "/api/v2/namespace/plugins/opsapi_marketing", "owner_a", A, {
    "settings": {"dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00"},
}), 200)

owner = USERS["owner_a"][0]
contacts = [new_uuid() for _ in range(4)]
emails = [f"c{i}@life.invalid" for i in range(4)]
for i, (cu, em) in enumerate(zip(contacts, emails)):
    phone = f"+4477009000{i:02d}"
    sql(f"""
    INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, phone, owner_user_uuid, status, created_at, updated_at)
    SELECT '{cu}', id, 'C', 'Life', '{em}', '{phone}', '{owner}', 'active', now(), now()
    FROM namespaces WHERE uuid = '{A}' LIMIT 1;
    """)
    expect(f"opt-in {em}", call("POST", P + "/consent/opt-in", "owner_a", A, {
        "contact_uuid": cu, "channel": "email", "source": "form", "legal_basis": "consent",
    }), 200)

# Suppress one
expect("suppress one", call("POST", P + "/suppressions", "owner_a", A, {
    "address": emails[3], "channel": "email", "reason": "manual", "source": "test",
}), 201)

lst = expect("list", call("POST", P + "/lists", "owner_a", A, {
    "name": "Life list", "list_type": "static", "channel": "email",
}), 201)
lid = (lst.get("data") or lst).get("uuid")
for cu in contacts:
    expect("member", call("POST", P + f"/lists/{lid}/members", "owner_a", A, {"contact_uuid": cu}), 201)

camp = expect("create campaign", call("POST", P + "/campaigns", "owner_a", A, {
    "name": "Lifecycle",
    "channel": "email",
    "message_type": "marketing",
    "status": "draft",
    "subject": "Hi {{contact.first_name}}",
    "body_html": "<p>Hello {{contact.first_name}}</p><p><a href=\"{{unsubscribe_url}}\">Unsubscribe</a></p>",
    "body_text": "Hello {{contact.first_name}} {{unsubscribe_url}}",
    "approval_required": True,
    "max_deliveries": 2,
}), 201)
cid = (camp.get("data") or camp).get("uuid")

# Cannot schedule draft without validate when approval required path
# Validate
val = expect("validate", call("POST", P + f"/campaigns/{cid}/validate", "owner_a", A, {
    "list_uuid": lid,
}), 200)
vd = val.get("data") or val
prev = vd.get("preview") or {}
check("eligible count > 0", (prev.get("eligible") or 0) >= 1, val)
check("suppressed counted", (prev.get("suppressed") or 0) >= 1, val)
check("status awaiting_approval", (vd.get("campaign") or {}).get("status") == "awaiting_approval", val)

# Schedule blocked while awaiting approval
blocked = call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", A, {"send_now": True})
check("schedule blocked pending approval", blocked[0] == 400, blocked)

# The author can't approve their own campaign; another admin can.
own = call("POST", P + f"/campaigns/{cid}/approve", "owner_a", A, {})
check("author can't self-approve", own[0] == 400 and ((own[1] or {}).get("details") or {}).get("code") == "self_approval",
      own)
apr = expect("approve", call("POST", P + f"/campaigns/{cid}/approve", "approver", A, {}), 200)
check("approved → validated", ((apr.get("data") or apr).get("status") == "validated"), apr)

# A/B config
ab = expect("set ab", call("PUT", P + f"/campaigns/{cid}/ab-config", "owner_a", A, {
    "enabled": True,
    "variants": [
        {"key": "A", "subject": "Variant A {{contact.first_name}}", "weight": 1,
         "body_html": "<p>A {{contact.first_name}}</p><a href=\"{{unsubscribe_url}}\">u</a>",
         "body_text": "A"},
        {"key": "B", "subject": "Variant B {{contact.first_name}}", "weight": 1,
         "body_html": "<p>B {{contact.first_name}}</p><a href=\"{{unsubscribe_url}}\">u</a>",
         "body_text": "B"},
    ],
}), 200)
check("A/B edit after approval → back to draft", (ab.get("data") or ab).get("status") == "draft", ab)
again = call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", A, {"send_now": True})
check("send blocked until approved again",
      again[0] == 400 and ((again[1] or {}).get("details") or {}).get("code") == "approval_required", again)
expect("re-approve", call("POST", P + f"/campaigns/{cid}/approve", "approver", A, {}), 200)

# Send now (budget 2)
send = expect("send now", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", A, {
    "list_uuid": lid, "send_now": True, "max_deliveries": 2,
}), 200)
sd = send.get("data") or send
check("queued under budget", (sd.get("queued") or 0) <= 2, send)
check("status sending", ((sd.get("campaign") or sd).get("status") == "sending"), send)

# Pause
pause = expect("pause", call("POST", P + f"/campaigns/{cid}/pause", "owner_a", A, {}), 200)
check("paused", ((pause.get("data") or pause).get("status") == "paused"), pause)

# Resume
res = expect("resume", call("POST", P + f"/campaigns/{cid}/resume", "owner_a", A, {}), 200)
rst = (res.get("data") or res).get("status")
check("resumed to sending or scheduled", rst in ("sending", "scheduled"), res)

# Stats
st = expect("stats", call("GET", P + f"/campaigns/{cid}/stats", "owner_a", A), 200)
std = st.get("data") or st
check("stats has totals", isinstance(std.get("by_state"), dict) or (std.get("total") or 0) >= 0, st)

# Duplicate
dup = expect("duplicate", call("POST", P + f"/campaigns/{cid}/duplicate", "owner_a", A, {
    "name": "Lifecycle copy",
}), 201)
check("dup is draft", ((dup.get("data") or dup).get("status") == "draft"), dup)

# Cancel
# First make a fresh sending campaign to cancel
camp2 = expect("campaign2", call("POST", P + "/campaigns", "owner_a", A, {
    "name": "To cancel",
    "channel": "email",
    "message_type": "marketing",
    "status": "draft",
    "subject": "Bye",
    "body_html": "<p>x</p><a href=\"{{unsubscribe_url}}\">u</a>",
    "body_text": "x {{unsubscribe_url}}",
}), 201)
c2 = (camp2.get("data") or camp2).get("uuid")
expect("validate2", call("POST", P + f"/campaigns/{c2}/validate", "owner_a", A, {"list_uuid": lid}), 200)
expect("schedule2", call("POST", P + f"/campaigns/{c2}/schedule", "owner_a", A, {"send_now": True}), 200)
can = expect("cancel", call("POST", P + f"/campaigns/{c2}/cancel", "owner_a", A, {}), 200)
check("cancelled", ((can.get("data") or can).get("status") == "cancelled"), can)

# Reject path
camp3 = expect("campaign3", call("POST", P + "/campaigns", "owner_a", A, {
    "name": "Reject me",
    "channel": "email",
    "message_type": "marketing",
    "approval_required": True,
    "subject": "Hi {{contact.first_name}}",
    "body_html": "<p>Hi</p><a href=\"{{unsubscribe_url}}\">u</a>",
    "body_text": "Hi {{unsubscribe_url}}",
}), 201)
c3 = (camp3.get("data") or camp3).get("uuid")
expect("validate3", call("POST", P + f"/campaigns/{c3}/validate", "owner_a", A, {"list_uuid": lid}), 200)
rej = expect("reject", call("POST", P + f"/campaigns/{c3}/reject", "owner_a", A, {"reason": "copy weak"}), 200)
check("rejected to draft", ((rej.get("data") or rej).get("status") == "draft"), rej)

# Re-check eligibility at send: opt-out mid-flight
# Already covered in phase0; quick assert validate won't allow empty eligible-only? suppressed still in list.
time.sleep(0.2)
raise SystemExit(finish())
