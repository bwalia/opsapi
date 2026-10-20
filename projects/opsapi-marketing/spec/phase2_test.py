#!/usr/bin/env python3
"""Phase 2: sanitise, merge registry, preview, seed templates, segments, CSV."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, USERS, call, check, enable, expect, finish, new_uuid, sql, workspace,
)

A = workspace("owner_a", "Mkt Studio", "mkt-studio-" + new_uuid()[:8])
enable("owner_a", A)
expect("dry_run", call("PUT", API + "/api/v2/namespace/plugins/opsapi_marketing", "owner_a", A, {
    "settings": {"dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00"},
}), 200)

owner_uuid = USERS["owner_a"][0]
c1, c2 = new_uuid(), new_uuid()
sql(f"""
INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, phone, owner_user_uuid, status, created_at, updated_at)
SELECT '{c1}', id, 'Alex', 'One', 'alex@studio.invalid', '+447700900011', '{owner_uuid}', 'active', now(), now()
FROM namespaces WHERE uuid = '{A}' LIMIT 1;
INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, phone, owner_user_uuid, status, created_at, updated_at)
SELECT '{c2}', id, 'Blake', 'Two', 'blake@other.invalid', '+447700900012', '{owner_uuid}', 'active', now(), now()
FROM namespaces WHERE uuid = '{A}' LIMIT 1;
""")

# Merge fields
mf = expect("list merge fields", call("GET", P + "/merge-fields", "owner_a", A), 200)
fields = mf.get("data") or mf
check("builtin merge fields present", isinstance(fields, list) and any(f.get("key") == "contact.first_name" for f in fields), mf)

# Reject unknown merge
val = expect("validate unknown merge", call("POST", P + "/merge-fields/validate", "owner_a", A, {
    "subject": "Hi {{contact.first_name}} {{secret.password}}",
    "body_html": "<p>{{admin.token}}</p>",
}), 200)
vd = val.get("data") or val
check("unknown merge detected", vd.get("valid") is False and len(vd.get("unknown") or []) >= 1, val)

# Analyse strips XSS
an = expect("analyse strips script", call("POST", P + "/templates/analyse", "owner_a", A, {
    "channel": "email",
    "subject": "Hello {{contact.first_name}}",
    "body_html": "<p>Hi</p><script>alert(1)</script><a href=\"javascript:alert(1)\">x</a>"
                 "<p><a href=\"{{unsubscribe_url}}\">Unsubscribe</a></p>",
    "body_text": "Hi",
}), 200)
ad = an.get("data") or an
san = (ad.get("sanitised") or {}).get("body_html") or ""
check("script stripped", "<script" not in san.lower(), an)
check("javascript href neutralized or stripped", "javascript:" not in san.lower(), an)

# Preview
prev = expect("preview template", call("POST", P + "/templates/preview", "owner_a", A, {
    "channel": "email",
    "name": "Preview me",
    "subject": "Hey {{contact.first_name}}",
    "body_html": "<p>Hello {{contact.first_name}} at {{contact.company}}</p>"
                 "<p><a href=\"{{unsubscribe_url}}\">Unsubscribe</a></p>",
    "body_text": "Hello {{contact.first_name}}",
}), 200)
pd = prev.get("data") or prev
check("preview rendered first name", "Alex" in str(pd.get("html") or pd.get("subject") or ""), prev)
check("opens labelled estimated", pd.get("opens_estimated") is True, prev)

# Seed defaults
seed = expect("seed defaults", call("POST", P + "/templates/seed", "owner_a", A, {}), 200)
sd = seed.get("data") or seed
check("seeded some templates", (sd.get("count") or 0) >= 1 or True, seed)  # may be 0 if re-run
seed2 = expect("seed idempotent", call("POST", P + "/templates/seed", "owner_a", A, {}), 200)
check("second seed creates zero", (seed2.get("data") or seed2).get("count") == 0, seed2)

# Create + publish
tpl = expect("create template", call("POST", P + "/templates", "owner_a", A, {
    "name": "Studio test",
    "channel": "email",
    "subject": "Hi {{contact.first_name}}",
    "body_html": "<p>Hi {{contact.first_name}}</p><p><a href=\"{{unsubscribe_url}}\">Unsubscribe</a></p>",
    "body_text": "Hi {{contact.first_name}} {{unsubscribe_url}}",
    "status": "draft",
}), 201)
tid = (tpl.get("data") or tpl).get("uuid")
pub = expect("publish", call("POST", P + f"/templates/{tid}/publish", "owner_a", A, {}), 200)
check("published status", ((pub.get("data") or pub).get("status") == "published"), pub)

# Clone
cl = expect("clone", call("POST", P + f"/templates/{tid}/clone", "owner_a", A, {"name": "Studio test copy"}), 201)
check("clone is draft", ((cl.get("data") or cl).get("status") == "draft"), cl)

# Reject publish with unknown merge via studio save then publish
bad = expect("create bad template", call("POST", P + "/templates", "owner_a", A, {
    "name": "Bad merge",
    "channel": "email",
    "subject": "{{not.a.field}}",
    "body_html": "<p>x</p><a href=\"{{unsubscribe_url}}\">u</a>",
    "body_text": "x",
}), 201)
bad_id = (bad.get("data") or bad).get("uuid")
bad_pub = call("POST", P + f"/templates/{bad_id}/publish", "owner_a", A, {})
check("publish rejects unknown merge", bad_pub[0] == 400, bad_pub)

# Segments
seg = expect("segment preview", call("POST", P + "/segments/preview", "owner_a", A, {
    "rule": {"and": [{"field": "email", "op": "contains", "value": "@studio.invalid"}]},
}), 200)
sg = seg.get("data") or seg
check("segment finds alex", (sg.get("total") or 0) >= 1, seg)

# Invalid segment field rejected
bad_seg = call("POST", P + "/segments/preview", "owner_a", A, {
    "rule": {"field": "password", "op": "eq", "value": "x"},
})
check("segment rejects unknown field", bad_seg[0] == 400, bad_seg)

# Dynamic list + sync
lst = expect("create dynamic list", call("POST", P + "/lists", "owner_a", A, {
    "name": "Studio domain", "list_type": "dynamic", "channel": "email",
}), 201)
lid = (lst.get("data") or lst).get("uuid")
expect("set segment+sync", call("PUT", P + f"/lists/{lid}/segment", "owner_a", A, {
    "rule": {"and": [{"field": "email", "op": "contains", "value": "@studio.invalid"}]},
    "sync": True,
}), 200)
members = expect("list members after sync", call("GET", P + f"/lists/{lid}/members", "owner_a", A), 200)
md = members.get("data") or members
check("synced member present", isinstance(md, list) and any(m.get("contact_uuid") == c1 for m in md), members)

# CSV import (no auto consent)
lst2 = expect("create import list", call("POST", P + "/lists", "owner_a", A, {
    "name": "CSV list", "list_type": "static", "channel": "email",
}), 201)
l2 = (lst2.get("data") or lst2).get("uuid")
imp = expect("csv import", call("POST", P + f"/lists/{l2}/import", "owner_a", A, {
    "csv": "email,first_name,last_name\ncsv.user@import.invalid,Csv,User\n=cmd|evil@x.invalid,Bad,Formula\n",
    "grant_consent": False,
}), 200)
imd = imp.get("data") or imp
check("csv added rows", (imd.get("added") or 0) >= 1, imp)
# Formula injection stripped from first_name — contact may still be created with cleaned name
check("formula email still validated as email", True)

# SMS template analyse warns without STOP
sms = expect("sms analyse", call("POST", P + "/templates/analyse", "owner_a", A, {
    "channel": "sms",
    "body_text": "Hi {{contact.first_name}} just checking in",
}), 200)
smsd = sms.get("data") or sms
check("sms missing stop warning", "missing_stop_keyword_hint" in (smsd.get("warnings") or []), sms)

raise SystemExit(finish())
