#!/usr/bin/env python3
"""Phase 9: step-1 production fixes — run with quiet hours ON and real budgets, which the
earlier suites turn off (that's how these bugs got through)."""
import os
import sys
import time
import urllib.error
import urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import API, P, USERS, call, check, enable, expect, finish, new_uuid, sql, workspace  # noqa: E402

OWNER = USERS["owner_a"][0]
PLUGINS = API + "/api/v2/namespace/plugins/opsapi_marketing"


def data(b):
    return (b.get("data") or b) if isinstance(b, dict) else {}


def code(res):
    return ((res[1] if isinstance(res[1], dict) else {}).get("details") or {}).get("code")


def setup(name, **settings):
    ns = workspace("owner_a", name, "p9-" + new_uuid()[:8])
    enable("owner_a", ns)
    base = {"dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00",
            "marketing_frequency_cap_count": 50}
    base.update(settings)
    expect("settings " + name, call("PUT", PLUGINS, "owner_a", ns, {"settings": base}), 200)
    return ns


def contact(ns, email, first="C", channel="email"):
    cu = new_uuid()
    sql(f"""INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, phone, owner_user_uuid,
            status, created_at, updated_at)
            SELECT '{cu}', id, $q${first}$q$, 'Nine', '{email}', '+447700900999', '{OWNER}', 'active', now(), now()
            FROM namespaces WHERE uuid = '{ns}'""")
    expect("opt-in", call("POST", P + "/consent/opt-in", "owner_a", ns,
                          {"contact_uuid": cu, "channel": channel, "source": "form"}), 200)
    return cu


def static_list(ns, members):
    lst = data(expect("list", call("POST", P + "/lists", "owner_a", ns,
                                   {"name": "L" + new_uuid()[:6], "list_type": "static", "channel": "email"}), 201))
    for cu in members:
        expect("member", call("POST", P + f"/lists/{lst['uuid']}/members", "owner_a", ns, {"contact_uuid": cu}), 201)
    return lst["uuid"]


def campaign(ns, user="owner_a", **kw):
    body = {"name": "P9 " + new_uuid()[:6], "channel": "email", "message_type": "marketing",
            "subject": "Hi {{contact.first_name}}", "body_html": "<p>Hello {{contact.first_name}}</p>",
            "body_text": "Hello {{contact.first_name}}"}
    body.update(kw)
    return data(expect("campaign", call("POST", P + "/campaigns", user, ns, body), 201))["uuid"]


def run_sender(ns):
    """Run the campaign sender for this workspace once and wait for it to finish."""
    q = (f"SELECT COALESCE(j.last_run_at::text, 'never') FROM plugin_jobs j JOIN namespaces n "
         f"ON n.id = j.namespace_id WHERE j.job = 'opsapi_marketing.campaign_sender' AND n.uuid = '{ns}'")
    deadline = time.time() + 90  # a new workspace's job row is seeded within a minute
    while time.time() < deadline and not sql(q):
        time.sleep(2)
    before = sql(q)
    sql(f"UPDATE plugin_jobs SET next_run_at = NOW() FROM namespaces n WHERE n.id = plugin_jobs.namespace_id "
        f"AND plugin_jobs.job = 'opsapi_marketing.campaign_sender' AND n.uuid = '{ns}'")
    deadline = time.time() + 45
    while time.time() < deadline and sql(q) == before:
        time.sleep(2)


def drain(ns, cid, rounds=5):
    for _ in range(rounds):
        run_sender(ns)
        if sql(f"SELECT status FROM mkt_campaigns WHERE uuid = '{cid}'") != ["sending"]:
            return


def states(cid):
    return sorted(sql(f"SELECT d.state || ':' || COALESCE(d.reason, '') FROM mkt_deliveries d "
                      f"JOIN mkt_campaigns c ON c.id = d.campaign_id WHERE c.uuid = '{cid}'"))


def status(cid):
    return sql(f"SELECT status FROM mkt_campaigns WHERE uuid = '{cid}'")


# ---------------------------------------------------------------- platform: auth bypass
def raw_get(path):
    try:
        with urllib.request.urlopen(urllib.request.Request(API + path), timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


check("encoded ..%2F path can't skip the login check (401)", raw_get("/api/v2/modules/..%2Fpublic%2Fx") == 401)
check("plain protected path still 401", raw_get("/api/v2/modules/x") == 401)
check("public marketing route still public (400 bad token, not 401)",
      raw_get("/api/v2/opsapi-marketing/public/unsubscribe?token=x") == 400)

# ---------------------------------------------------------------- W1: normal settings
W1 = setup("P9 main")

# Push / webhook can never deliver to CRM contacts: refused up front.
r = call("POST", P + "/campaigns", "owner_a", W1, {"name": "Hook", "channel": "webhook", "body_text": "{}"})
check("webhook channel refused (422)", r[0] == 422, r)

# Budget N sends exactly N.
cs = [contact(W1, f"bud{i}@p9.invalid") for i in range(3)]
cid = campaign(W1, max_deliveries=2)
expect("budget send", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W1,
                           {"list_uuid": static_list(W1, cs), "send_now": True}), 200)
drain(W1, cid)
s = states(cid)
check("budget 2 → exactly 2 sent", s.count("accepted:dry_run") == 2 and len(s) == 2, s)

# Dynamic segments sync every match (was capped at 500).
sql(f"""INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, owner_user_uuid, status,
        created_at, updated_at)
        SELECT gen_random_uuid()::text, n.id, 'Seg', 'Nine', 'seg' || g || '@p9.invalid', '{OWNER}', 'active',
               now(), now()
        FROM namespaces n, generate_series(1, 520) g WHERE n.uuid = '{W1}'""")
dl = data(expect("dynamic list", call("POST", P + "/lists", "owner_a", W1,
                                      {"name": "Dyn", "list_type": "dynamic", "channel": "email"}), 201))
sync = data(expect("segment + sync", call("PUT", P + f"/lists/{dl['uuid']}/segment", "owner_a", W1,
                                          {"rule": {"field": "first_name", "op": "eq", "value": "Seg"},
                                           "sync": True}), 200)).get("sync") or {}
check("dynamic list syncs all 520", sync.get("synced") == 520, sync)

# A broken template fails validation and is never sent.
cu = contact(W1, "tpl@p9.invalid")
bad = campaign(W1, body_html="<p>{% if contact.first_name %}Hi</p>", body_text="Hi")
r = call("POST", P + f"/campaigns/{bad}/validate", "owner_a", W1, {"list_uuid": static_list(W1, [cu])})
check("broken template → validate 400 template_error", r[0] == 400 and code(r) == "template_error", r)
check("template error names the problem", "endif" in str(r[1]), r)
call("POST", P + f"/campaigns/{bad}/test-send", "owner_a", W1, {"contact_uuid": cu})
s = sql(f"SELECT d.state FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id WHERE c.uuid = '{bad}'")
check("broken template test-send fails, not accepted", s == ["failed"], s)

# Merge values are plain in subject / text, escaped once in HTML.
cu = contact(W1, "obrien@p9.invalid", first="Seán O'Brien & Co")
cid = campaign(W1)
call("POST", P + f"/campaigns/{cid}/test-send", "owner_a", W1, {"contact_uuid": cu})
row = sql(f"SELECT d.subject || '|' || d.body_text || '|' || d.body_html FROM mkt_deliveries d "
          f"JOIN mkt_campaigns c ON c.id = d.campaign_id WHERE c.uuid = '{cid}'")
parts = (row[0] if row else "||").split("|", 2)
check("subject not HTML-escaped", parts[0] == "Hi Seán O'Brien & Co", parts[0])
check("text body not HTML-escaped", "Hello Seán O'Brien & Co" in parts[1], parts[1])
check("HTML body escaped once", "O&#39;Brien &amp; Co" in parts[2] and "&amp;#39;" not in parts[2], parts[2][:200])

# Template preview: no double escaping either.
pv = data(expect("preview", call("POST", P + "/templates/preview", "owner_a", W1, {
    "channel": "email", "subject": "Hi {{contact.first_name}}", "body_html": "<p>{{contact.first_name}}</p>",
    "sample": {"contact": {"first_name": "O'Brien & Co"}}}), 200))
check("preview subject plain", pv.get("subject") == "Hi O'Brien & Co", pv.get("subject"))

# CSV import keeps international phone numbers.
sl = data(expect("sms list", call("POST", P + "/lists", "owner_a", W1,
                                  {"name": "SMS", "list_type": "static", "channel": "sms"}), 201))
expect("csv import", call("POST", P + f"/lists/{sl['uuid']}/import", "owner_a", W1, {
    "csv": "email,first_name,phone\ncsv9@p9.invalid,Csv,+44 7700 900123\n", "grant_consent": True}), 200)
ph = sql(f"SELECT c.phone FROM crm_contacts c JOIN namespaces n ON n.id = c.namespace_id "
         f"WHERE c.email = 'csv9@p9.invalid' AND n.uuid = '{W1}'")
check("imported phone stored as E.164", ph == ["+447700900123"], ph)

# Audience preview is read-only: it doesn't attach the list.
la, lb = static_list(W1, [cu]), static_list(W1, [cu])
cid = campaign(W1)
expect("validate on list A", call("POST", P + f"/campaigns/{cid}/validate", "owner_a", W1, {"list_uuid": la}), 200)
expect("preview list B", call("POST", P + f"/campaigns/{cid}/audience-preview", "owner_a", W1,
                              {"list_uuid": lb}), 200)
cur = sql(f"SELECT l.uuid FROM mkt_campaigns c JOIN mkt_lists l ON l.id = c.list_id WHERE c.uuid = '{cid}'")
check("preview didn't change the campaign's list", cur == [la], cur)
check("still validated", status(cid) == ["validated"], status(cid))

# Approval: the author can't approve; A/B edits, list swaps and paused edits all need approval again.
cid = campaign(W1, approval_required=True)
expect("validate", call("POST", P + f"/campaigns/{cid}/validate", "owner_a", W1, {"list_uuid": la}), 200)
r = call("POST", P + f"/campaigns/{cid}/approve", "owner_a", W1, {})
check("author can't self-approve", r[0] == 400 and code(r) == "self_approval", r)
expect("approver approves", call("POST", P + f"/campaigns/{cid}/approve", "approver", W1, {}), 200)
expect("A/B after approval", call("PUT", P + f"/campaigns/{cid}/ab-config", "owner_a", W1, {"variants": [
    {"key": "A", "subject": "New A", "body_html": "<p>A</p>"}, {"key": "B", "subject": "New B"}]}), 200)
check("A/B edit → draft", status(cid) == ["draft"], status(cid))
r = call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W1, {"send_now": True})
check("send refused until approved again", r[0] == 400 and code(r) == "approval_required", r)
expect("re-approve", call("POST", P + f"/campaigns/{cid}/approve", "approver", W1, {}), 200)
r = call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W1, {"list_uuid": lb, "send_now": True})
check("other list at send → needs approval again", r[0] == 400 and code(r) == "approval_required", r)
expect("re-approve after list change", call("POST", P + f"/campaigns/{cid}/approve", "approver", W1, {}), 200)
future = "2099-01-01T09:00:00Z"
expect("schedule later", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W1, {"scheduled_at": future}), 200)
expect("pause", call("POST", P + f"/campaigns/{cid}/pause", "owner_a", W1, {}), 200)
expect("edit while paused", call("PUT", P + f"/campaigns/{cid}", "owner_a", W1, {"subject": "Changed"}), 200)
check("paused edit → draft", status(cid) == ["draft"], status(cid))
r = call("POST", P + f"/campaigns/{cid}/resume", "owner_a", W1, {})
check("can't resume edited content without validating", r[0] == 400, r)

# Workspace-wide approval: a campaign that doesn't ask for it still needs it.
expect("require approval", call("PUT", PLUGINS, "owner_a", W1, {"settings": {"require_approval": True}}), 200)
cid = campaign(W1)
r = call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W1, {"list_uuid": la, "send_now": True})
check("workspace require_approval enforced", r[0] == 400 and code(r) == "approval_required", r)
expect("approve", call("POST", P + f"/campaigns/{cid}/approve", "approver", W1, {}), 200)
expect("send after approval", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W1, {"send_now": True}), 200)
expect("require approval off", call("PUT", PLUGINS, "owner_a", W1, {"settings": {"require_approval": False}}), 200)

# A member who can edit campaigns (no manage) can't approve, or send transactional messages.
role = new_uuid()
sql(f"""INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, created_at, updated_at)
        SELECT '{role}', id, 'p9_editor', 'Editor',
               '{{"opsapi_marketing_campaigns":["read","create","update"]}}', now(), now()
        FROM namespaces WHERE uuid = '{W1}';
        INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
        SELECT gen_random_uuid()::text, n.id, u.id, 'active', false, now(), now(), now()
        FROM namespaces n, users u WHERE n.uuid = '{W1}' AND u.uuid = '{USERS["owner_b"][0]}';
        INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
        SELECT gen_random_uuid()::text, m.id, r.id, now(), now()
        FROM namespace_members m JOIN namespaces n ON n.id = m.namespace_id
        JOIN users u ON u.id = m.user_id JOIN namespace_roles r ON r.uuid = '{role}'
        WHERE n.uuid = '{W1}' AND u.uuid = '{USERS["owner_b"][0]}'""")
tx = campaign(W1, user="owner_b", message_type="transactional")
r = call("POST", P + f"/campaigns/{tx}/schedule", "owner_b", W1, {"list_uuid": la, "send_now": True})
check("editor can't send transactional (403)", r[0] == 403 and code(r) == "message_type_needs_manage", r)
mk = campaign(W1, user="owner_b", approval_required=True)
expect("editor validates", call("POST", P + f"/campaigns/{mk}/validate", "owner_b", W1, {"list_uuid": la}), 200)
r = call("POST", P + f"/campaigns/{mk}/approve", "owner_b", W1, {})
check("editor can't approve (403)", r[0] == 403, r)
expect("owner approves editor's campaign", call("POST", P + f"/campaigns/{mk}/approve", "owner_a", W1, {}), 200)

# ---------------------------------------------------------------- W2: frequency cap 1
W2 = setup("P9 cap", marketing_frequency_cap_count=1)
cu = contact(W2, "cap@p9.invalid")
lid = static_list(W2, [cu])
first = campaign(W2)
expect("cap send 1", call("POST", P + f"/campaigns/{first}/schedule", "owner_a", W2,
                          {"list_uuid": lid, "send_now": True}), 200)
drain(W2, first)
check("cap 1 → first message goes out", states(first) == ["accepted:dry_run"], states(first))
second = campaign(W2)
r = call("POST", P + f"/campaigns/{second}/schedule", "owner_a", W2, {"list_uuid": lid, "send_now": True})
check("cap 1 → second campaign has nobody eligible", r[0] == 400 and code(r) == "no_eligible_recipients", r)
el = data(expect("eligibility", call("POST", P + f"/campaigns/{second}/eligibility", "owner_a", W2,
                                     {"contact_uuid": cu}), 200))
check("cap 1 → reason is frequency_cap", el.get("reason") == "frequency_cap", el)

# ---------------------------------------------------------------- W3: quiet hours all day
W3 = setup("P9 quiet", quiet_hours_from="00:00", quiet_hours_to="23:59")
cq = [contact(W3, f"q{i}@p9.invalid") for i in range(2)]
cid = campaign(W3)
expect("send in quiet hours", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W3,
                                   {"list_uuid": static_list(W3, cq), "send_now": True}), 200)
run_sender(W3)
run_sender(W3)
check("quiet hours: messages wait in the queue", states(cid) == ["queued:", "queued:"], states(cid))
check("quiet hours: campaign still sending", status(cid) == ["sending"], status(cid))
ts = data(expect("test-send in quiet hours", call("POST", P + f"/campaigns/{cid}/test-send", "owner_a", W3,
                                                  {"contact_uuid": cq[0]}), 200))
check("test-send ignores quiet hours", ts.get("state") == "accepted", ts)
expect("quiet hours end", call("PUT", PLUGINS, "owner_a", W3,
                               {"settings": {"quiet_hours_from": "00:00", "quiet_hours_to": "00:00"}}), 200)
drain(W3, cid)
s = [x for x in states(cid) if x == "accepted:dry_run"]
check("after quiet hours: both sent (plus the test)", len(s) == 3, states(cid))
check("after quiet hours: campaign completed", status(cid) == ["completed"], status(cid))

sys.exit(finish())
