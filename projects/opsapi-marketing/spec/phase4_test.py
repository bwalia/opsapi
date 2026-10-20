#!/usr/bin/env python3
"""Phase 4: analytics, reply classification, tracking effects."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, USERS, call, check, enable, expect, finish, new_uuid, sql, workspace,
)

A = workspace("owner_a", "Mkt Track", "mkt-track-" + new_uuid()[:8])
enable("owner_a", A)
expect("dry_run", call("PUT", API + "/api/v2/namespace/plugins/opsapi_marketing", "owner_a", A, {
    "settings": {"dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00"},
}), 200)

owner = USERS["owner_a"][0]
cu = new_uuid()
em = "track@life.invalid"
sql(f"""
INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, phone, owner_user_uuid, status, created_at, updated_at)
SELECT '{cu}', id, 'T', 'Rack', '{em}', '+447700900099', '{owner}', 'active', now(), now()
FROM namespaces WHERE uuid = '{A}' LIMIT 1;
""")
expect("opt-in", call("POST", P + "/consent/opt-in", "owner_a", A, {
    "contact_uuid": cu, "channel": "email", "source": "form", "legal_basis": "consent",
}), 200)

prev = expect("classify interested", call("POST", P + "/replies/classify-preview", "owner_a", A, {
    "subject": "Re: offer", "body_text": "Yes I'm interested, sounds good!",
}), 200)
pd = prev.get("data") or prev
check("interested class", pd.get("classification") == "interested", prev)
check("never auto_send", pd.get("auto_send") is False, prev)

unsub = expect("classify unsub", call("POST", P + "/replies/classify-preview", "owner_a", A, {
    "body_text": "Please unsubscribe me from this list",
}), 200)
check("unsubscribe class", (unsub.get("data") or unsub).get("classification") == "unsubscribe", unsub)

ing = expect("ingest unsub", call("POST", P + "/replies/ingest", "owner_a", A, {
    "provider": "test",
    "external_id": "ext-unsub-1",
    "channel": "email",
    "address": em,
    "contact_uuid": cu,
    "subject": "bye",
    "body_text": "unsubscribe please",
}), 201)
check("auto_send false on ingest", ((ing.get("data") or ing).get("auto_send") is False), ing)

dup = expect("dup ingest", call("POST", P + "/replies/ingest", "owner_a", A, {
    "provider": "test", "external_id": "ext-unsub-1",
    "body_text": "unsubscribe please", "channel": "email", "address": em,
}), 200)
check("duplicate flagged", (dup.get("data") or dup).get("duplicate") is True, dup)

cons = expect("consent after unsub reply", call("GET", P + f"/consent/{cu}", "owner_a", A), 200)
cd = cons.get("data") or cons
subs = cd.get("subscriptions") or []
check("subscription unsubscribed", any(s.get("status") == "unsubscribed" for s in subs), cons)

ov = expect("analytics overview", call("GET", P + "/analytics/overview", "owner_a", A), 200)
od = ov.get("data") or ov
check("overview has deliveries", isinstance(od.get("deliveries"), dict), ov)
check("opens estimated note", (od.get("notes") or {}).get("opens_are_estimated") is True, ov)

tl = expect("contact timeline", call("GET", P + f"/analytics/contacts/{cu}", "owner_a", A), 200)
td = tl.get("data") or tl
check("timeline has replies", isinstance(td.get("replies"), list) and len(td.get("replies")) >= 1, tl)

lr = expect("list replies", call("GET", P + "/replies?classification=unsubscribe", "owner_a", A), 200)
payload = lr.get("data") or lr
rows = payload.get("data") if isinstance(payload, dict) else payload
if isinstance(rows, dict):
    rows = rows.get("data") or []
check("listed unsubscribe reply", isinstance(rows, list) and len(rows) >= 1, lr)

expect("ingest complaint", call("POST", P + "/replies/ingest", "owner_a", A, {
    "provider": "test", "external_id": "ext-comp-1",
    "channel": "email", "address": "complainer@life.invalid",
    "body_text": "This is spam / complaint / GDPR",
}), 201)
sup = expect("complaint suppressed", call("GET", P + "/suppressions", "owner_a", A), 200)
sp = (sup.get("data") or sup)
items = sp if isinstance(sp, list) else (sp.get("data") or sp.get("items") or [])
if isinstance(items, dict):
    items = items.get("data") or []
addrs = [str(x.get("address", "")).lower() for x in items] if isinstance(items, list) else []
check("complaint address suppressed", "complainer@life.invalid" in addrs, {"addrs": addrs, "raw": sup})

sys.exit(finish())
