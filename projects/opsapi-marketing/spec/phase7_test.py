#!/usr/bin/env python3
"""Phase 7: campaign audience resolution (PR #779) — dynamic list sync before
Validate/Send, friendly error messages with machine codes, malformed bodies."""
import os
import sys
import urllib.error
import urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, USERS, call, check, enable, expect, finish, jwt, new_uuid, sql, workspace,
)

A = workspace("owner_a", "Mkt Audience", "mkt-aud-" + new_uuid()[:8])
enable("owner_a", A)
expect("dry_run", call("PUT", API + "/api/v2/namespace/plugins/opsapi_marketing", "owner_a", A, {
    "settings": {"dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00"},
}), 200)

owner = USERS["owner_a"][0]
contacts = [new_uuid() for _ in range(3)]
for i, cu in enumerate(contacts):
    em = f"x{i}@xmas.invalid"
    sql(f"""
    INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, owner_user_uuid, status, created_at, updated_at)
    SELECT '{cu}', id, 'X', 'Mas', '{em}', '{owner}', 'active', now(), now()
    FROM namespaces WHERE uuid = '{A}' LIMIT 1;
    """)
    expect(f"opt-in {em}", call("POST", P + "/consent/opt-in", "owner_a", A, {
        "contact_uuid": cu, "channel": "email", "source": "form", "legal_basis": "consent",
    }), 200)


def new_campaign(name):
    c = expect(f"create {name}", call("POST", P + "/campaigns", "owner_a", A, {
        "name": name, "channel": "email", "message_type": "marketing", "status": "draft",
        "subject": "Hi {{contact.first_name}}",
        "body_html": "<p>Hi {{contact.first_name}}</p><a href=\"{{unsubscribe_url}}\">u</a>",
        "body_text": "Hi {{unsubscribe_url}}",
    }), 201)
    return (c.get("data") or c).get("uuid")


def new_list(name, list_type):
    lst = expect(f"list {name}", call("POST", P + "/lists", "owner_a", A, {
        "name": name, "list_type": list_type, "channel": "email",
    }), 201)
    return (lst.get("data") or lst).get("uuid")


def err_text(res):
    b = res[1] if isinstance(res[1], dict) else {}
    return str(b.get("error") or b.get("message") or "")


def err_code(res):
    b = res[1] if isinstance(res[1], dict) else {}
    d = b.get("details") or {}
    return d.get("code") if isinstance(d, dict) else None


# 1. No list, no recipients → audience_required, human-readable
c1 = new_campaign("No audience")
r = call("POST", P + f"/campaigns/{c1}/validate", "owner_a", A, {})
check("no audience → 400", r[0] == 400, r)
check("no audience → friendly text", "Select a list" in err_text(r), r)
check("no audience → code audience_required", err_code(r) == "audience_required", r)

# 2. Unknown list uuid → list_not_found
r = call("POST", P + f"/campaigns/{c1}/validate", "owner_a", A, {"list_uuid": new_uuid()})
check("unknown list → 400 list_not_found", r[0] == 400 and err_code(r) == "list_not_found", r)

# 3. Empty static list → empty_audience
empty_static = new_list("Empty static", "static")
r = call("POST", P + f"/campaigns/{c1}/validate", "owner_a", A, {"list_uuid": empty_static})
check("empty static → empty_audience", r[0] == 400 and err_code(r) == "empty_audience", r)
check("empty static → friendly text", "no contacts" in err_text(r), r)

# 4. Dynamic list with no segment rule (the reported "Xmas list" bug)
xmas = new_list("Xmas list", "dynamic")
c2 = new_campaign("Xmas")
r = call("POST", P + f"/campaigns/{c2}/validate", "owner_a", A, {"list_uuid": xmas})
check("dynamic no rule → dynamic_list_needs_segment_rule",
      r[0] == 400 and err_code(r) == "dynamic_list_needs_segment_rule", r)
r = call("POST", P + f"/campaigns/{c2}/audience-preview", "owner_a", A, {"list_uuid": xmas})
check("preview dynamic no rule → 400 with code",
      r[0] == 400 and err_code(r) == "dynamic_list_needs_segment_rule", r)

# 5. Give it a rule but do NOT sync — Validate must sync it itself
expect("set segment (no sync)", call("PUT", P + f"/lists/{xmas}/segment", "owner_a", A, {
    "rule": {"field": "email", "op": "contains", "value": "@xmas.invalid"},
}), 200)
members_before = sql(f"""SELECT count(*) FROM mkt_list_members m JOIN mkt_lists l ON l.id = m.list_id
                         WHERE l.uuid = '{xmas}' AND m.removed_at IS NULL""")
check("no members before validate", members_before == ["0"], members_before)
pv = expect("preview dynamic with rule", call("POST", P + f"/campaigns/{c2}/audience-preview", "owner_a", A,
                                             {"list_uuid": xmas}), 200)
check("preview audience_total == 3", (pv.get("data") or pv).get("audience_total") == 3, pv)
val = expect("validate dynamic with rule", call("POST", P + f"/campaigns/{c2}/validate", "owner_a", A,
                                               {"list_uuid": xmas}), 200)
vd = val.get("data") or val
check("validate eligible == 3", (vd.get("preview") or {}).get("eligible") == 3, val)
check("status validated", (vd.get("campaign") or {}).get("status") == "validated", val)

# 6. A contact added after validate is picked up at send (re-sync in start_campaign)
late = new_uuid()
sql(f"""
INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, owner_user_uuid, status, created_at, updated_at)
SELECT '{late}', id, 'Late', 'Mas', 'late@xmas.invalid', '{owner}', 'active', now(), now()
FROM namespaces WHERE uuid = '{A}' LIMIT 1;
""")
expect("opt-in late", call("POST", P + "/consent/opt-in", "owner_a", A, {
    "contact_uuid": late, "channel": "email", "source": "form", "legal_basis": "consent",
}), 200)
send = expect("send now dynamic", call("POST", P + f"/campaigns/{c2}/schedule", "owner_a", A,
                                       {"send_now": True}), 200)
sd = send.get("data") or send
check("queued 4 incl. late contact", sd.get("queued") == 4, send)

# 7. Status guard returns readable bad_status message
r = call("POST", P + f"/campaigns/{c2}/validate", "owner_a", A, {"list_uuid": xmas})
check("validate after send → 400", r[0] == 400, r)
check("bad_status → readable", "does not allow" in err_text(r) or "status" in err_text(r).lower(), r)

# 7b. Lifecycle guard on PUT: status can't be forged; edits while sending are refused;
#     editing a validated campaign's content drops it back to draft.
r = call("PUT", P + f"/campaigns/{c2}", "owner_a", A, {"subject": "Changed"})
check("edit while sending → 409 not_editable", r[0] == 409 and err_code(r) == "not_editable", r)
c3 = new_campaign("Guard")
r = call("PUT", P + f"/campaigns/{c3}", "owner_a", A, {"status": "sending", "name": "Guard 2"})
check("PUT ignores status", r[0] == 200 and (r[1].get("data") or {}).get("status") == "draft"
      and (r[1].get("data") or {}).get("name") == "Guard 2", r)
expect("validate guard", call("POST", P + f"/campaigns/{c3}/validate", "owner_a", A, {"list_uuid": xmas}), 200)
r = call("PUT", P + f"/campaigns/{c3}", "owner_a", A, {"tracking": {"goal_event": "lead"}})
check("tracking edit keeps validated", r[0] == 200 and (r[1].get("data") or {}).get("status") == "validated", r)
r = call("PUT", P + f"/campaigns/{c3}", "owner_a", A, {"subject": "New subject"})
check("content edit → back to draft", r[0] == 200 and (r[1].get("data") or {}).get("status") == "draft", r)
r = call("POST", P + "/campaigns", "owner_a", A, {"name": "Forged", "channel": "email", "status": "completed"})
check("create ignores status", r[0] == 201 and (r[1].get("data") or {}).get("status") == "draft", r)

# 8. Malformed JSON body → 400 (not 500, not silently ignored)
req = urllib.request.Request(P + f"/campaigns/{c1}/validate", data=b"{not json", method="POST", headers={
    "Authorization": "Bearer " + jwt("owner_a"), "Content-Type": "application/json", "X-Namespace-Id": A,
})
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        code = resp.status
except urllib.error.HTTPError as e:
    code = e.code
check("malformed JSON → 400", code == 400, code)

# 9. Empty body (no Content-Length) still works for body-optional actions
req = urllib.request.Request(P + f"/campaigns/{c1}/duplicate", data=None, method="POST", headers={
    "Authorization": "Bearer " + jwt("owner_a"), "X-Namespace-Id": A,
})
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        code = resp.status
except urllib.error.HTTPError as e:
    code = e.code
check("duplicate with empty body → 201", code == 201, code)

# 10. Cross-tenant list uuid cannot be attached
B = workspace("owner_b", "Mkt Other", "mkt-oth-" + new_uuid()[:8])
enable("owner_b", B)
lb = expect("B list", call("POST", P + "/lists", "owner_b", B, {
    "name": "B list", "list_type": "static", "channel": "email"}), 201)
lb_uuid = (lb.get("data") or lb).get("uuid")
r = call("POST", P + f"/campaigns/{c1}/validate", "owner_a", A, {"list_uuid": lb_uuid})
check("cross-tenant list → list_not_found", r[0] == 400 and err_code(r) == "list_not_found", r)

sys.exit(finish())
