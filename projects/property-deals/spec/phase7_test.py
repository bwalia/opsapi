"""Phase 7 — the rest of the agents and hardening (PROMPT-backend Phase 7, SPEC §3.5, §3.8 #10, §4).

  * agents: lead triage, property enrichment, offer reasoning (manager-only), buyer matcher (one pack per buyer),
    document checker (reads a PDF, cites the page, only flags), compliance assistant (never passes a check),
    investor update — each a draft, approved, then carried out
  * supplier speed measured nightly; reports: stage times, late days, conversion, supplier and party speed, AI usage
  * export (CSV / JSON, managers only, spreadsheet-safe), retention, Prometheus metrics, the board's default template
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid as uuidlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, jwt, sql, workspace  # noqa: E402

MOCK = os.environ["PD_MOCK"]
M = "http://pd-mock:8080"


def mock(method, path, body=None):
    req = urllib.request.Request(MOCK + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"null")


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


def raw(method, url, user, ns, body=None, ctype="application/json"):
    h = {"Authorization": "Bearer " + jwt(user), "X-Namespace-Id": ns, "Content-Type": ctype}
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def wait_run(run_uuid, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = (call("GET", P + f"/agent-runs/{run_uuid}", "operator_s", S)[1] or {}).get("data") or {}
        if r.get("status") not in ("queued", "running", None):
            return r
        time.sleep(0.4)
    return r


def run_agent(task_uuid, name):
    st, b = call("POST", P + f"/tasks/{task_uuid}/agent-run", "operator_s", S)
    check(f"{name}: started (202)", st == 202, b)
    r = wait_run(b["data"]["uuid"]) if st == 202 else {}
    check(f"{name}: run succeeded", r.get("status") == "succeeded", r)
    return r


def approvals_for(task_uuid):
    return data(call("GET", P + f"/approvals?task_uuid={task_uuid}&status=pending", "manager_s", S), 200, "pending approvals") or []


def approve(a, user="manager_s"):
    return data(call("POST", P + f"/approvals/{a['uuid']}/decide", user, S, {"decision": "approve"}), 200, "approve " + a["action"])


def task(body, name):
    return data(call("POST", P + "/tasks", "operator_s", S, dict(body, agent_eligible=True)), 201, name)["task_uuid"]


def emails_to(addr):
    return [m for m in mock("GET", "/_smtp") if any(addr in t for t in m["to"])]


def make_pdf(pages):
    """A minimal valid PDF (Helvetica text, one block per page) that pdftotext can read."""
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", None, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    kids = []
    for text in pages:
        lines = "".join("(%s) Tj 0 -16 Td " % ln.replace("(", "[").replace(")", "]") for ln in text.split("\n"))
        stream = "BT /F1 12 Tf 72 720 Td %sET" % lines
        objs.append("<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream))
        content = len(objs)
        objs.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                    "/Contents %d 0 R >>" % content)
        kids.append(len(objs))
    objs[1] = "<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join("%d 0 R" % k for k in kids), len(kids))
    out, offsets = "%PDF-1.4\n", []
    for i, o in enumerate(objs):
        offsets.append(len(out.encode()))
        out += "%d 0 obj\n%s\nendobj\n" % (i + 1, o)
    xref = len(out.encode())
    out += "xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += "".join("%010d 00000 n \n" % off for off in offsets)
    out += "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return out.encode()


# --- Workspace: AI provider, connectors, SMTP ------------------------------------------------------------------
mock("POST", "/_ctl", {"reset_all": True})
S = workspace("owner_s", "Seven Buyers Ltd", "seven-buyers")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_s", S), 200)
board = data(call("GET", P + "/deals/board", "owner_s", S), 200, "board with no deals")
check("board with no deals opens on the default template (UK, 14 stages)", board["template"]["key"] == "uk_guaranteed_sale"
      and len(board["columns"]) == 14, board.get("template"))
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_s", S), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
role_id = {r["role_name"]: r["id"] for r in roles}
for user, role in (("manager_s", "pd_manager"), ("operator_s", "pd_operator")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
           {"email": USERS[user][1], "role_ids": [role_id[role]]}), 201)
local = data(call("POST", API + "/api/v2/namespace/ai-providers", "owner_s", S, {"name": "Local", "provider_type": "openai_compatible",
             "base_url": M + "/v1", "default_model": "qwen-local", "is_local": True, "input_cost_per_mtok": 0.1, "output_cost_per_mtok": 0.2}), 201, "local model")
expect("SMTP → sink", call("PUT", API + "/api/v2/namespace/mail-settings", "owner_s", S,
       {"host": "pd-mock", "port": 2525, "security": "none", "from_email": "deals@seven.test"}), 200)
for kind, cfg, secret in (("postcodes", {"base_url": M + "/pc"}, None),
                          ("epc", {"base_url": M + "/epc", "email": "epc@data-buyers.test"}, "epc-key"),
                          ("price_paid", {"base_url": M + "/lr"}, None)):
    body = {"kind": kind, "name": kind, "config": cfg}
    if secret:
        body["secret"] = secret
    data(call("POST", P + "/connectors", "manager_s", S, body), 201, "connector " + kind)
cat = data(call("GET", P + "/ai/agents", "operator_s", S), 200, "agent catalogue")
check("all 10 agents from SPEC §3.5 in the catalogue", [a["key"] for a in cat] == ["lead_triage", "property_enrichment",
      "offer_reasoning", "buyer_matcher", "legal_chaser", "booking_agent", "document_checker", "compliance_assistant",
      "digest_writer", "investor_update"], [a["key"] for a in cat])

# --- 1. Lead triage ------------------------------------------------------------------------------------------------
lead = expect("seller lead with call notes", call("POST", API + "/api/v2/crm/leads", "operator_s", S, {"first_name": "Pat",
              "source": "website_form", "notes": "Probate sale - mum passed away in June, recently bereaved, wants to sell by December"}), 201)
lead = lead.get("data") or lead
lt = task({"title": "Triage the new lead", "lead_uuid": lead["uuid"], "agent_key": "lead_triage"}, "triage task")
run_agent(lt, "lead triage")
a = approvals_for(lt)
check("triage: draft fills the lead's fields for a person to confirm", len(a) == 1 and a[0]["action"] == "update_lead"
      and a[0]["payload"]["details"]["situation"] == "probate" and a[0]["payload"]["details"]["vulnerability_flag"] is True, a)
check("triage: nothing written before approval", sql(f"SELECT COUNT(*) FROM property_deals_lead_details WHERE lead_uuid = '{lead['uuid']}' AND situation = 'probate'") == ["0"])
approve(a[0])
got = data(call("GET", P + f"/leads/{lead['uuid']}", "operator_s", S), 200, "lead")
check("triage: approved fields applied (situation, deadline, vulnerability, priority)", got["details"]["situation"] == "probate"
      and got["details"]["deadline_date"].startswith("2026-12-01") and got["details"]["vulnerability_flag"] is True
      and got["priority"] == "high", got)
no_lead = task({"title": "Triage without a lead", "agent_key": "lead_triage"}, "task without a lead")
res = call("POST", P + f"/tasks/{no_lead}/agent-run", "operator_s", S)
check("triage needs a lead (422)", res[0] == 422 and "lead" in res[1]["error"], res)

# --- A deal to work on ----------------------------------------------------------------------------------------------------
prop = data(call("POST", P + "/properties", "operator_s", S, {"address_line1": "7 Mill Lane", "town": "York", "postcode": "YO1 7AA",
            "tenure": "leasehold", "lease_years_left": 70, "property_type": "terraced", "bedrooms": 3, "est_market_value": 150000,
            "est_rent_pcm": 900, "condition": "needs_work"}), 201, "property")
deal = data(call("POST", P + "/deals", "operator_s", S, {"property_uuid": prop["uuid"], "deal_type": "buy", "name": "7 Mill Lane",
            "target_completion_date": "2026-09-01", "late_penalty_per_day": 100, "late_penalty_cap_days": 20}), 201, "deal")
D = deal["uuid"]
check("stage history starts when the deal is created", sql(f"SELECT stage_key FROM property_deals_stage_history WHERE deal_uuid = '{D}' AND left_at IS NULL") == [deal["stage_key"]])
buyer_c = expect("buyer contact", call("POST", API + "/api/v2/crm/contacts", "operator_s", S,
                 {"first_name": "Ivy", "last_name": "Investor", "email": "ivy@investors.test"}), 201)
buyer_c = buyer_c.get("data") or buyer_c
data(call("POST", P + "/deal-parties", "operator_s", S, {"deal_uuid": D, "role": "buyer", "contact_uuid": buyer_c["uuid"]}), 201,
     "buyer on the deal")

# --- 2. Property enrichment --------------------------------------------------------------------------------------------------
pe = task({"title": "Check the EPC register and comparables", "deal_uuid": D, "property_uuid": prop["uuid"],
           "agent_key": "property_enrichment"}, "enrichment task")
run_agent(pe, "property enrichment")
check("enrichment ran the official lookups first (EPC C on the property)",
      sql(f"SELECT epc_rating FROM property_deals_properties WHERE uuid = '{prop['uuid']}'") == ["C"])
a = approvals_for(pe)
check("enrichment: proposes facts, doesn't write them", len(a) == 1 and a[0]["action"] == "update_property"
      and a[0]["payload"]["changes"]["known_issues_add"] == ["short_lease"], a)
approve(a[0])
check("enrichment approved: flood risk and known issue added",
      sql(f"SELECT flood_risk || '|' || known_issues::text FROM property_deals_properties WHERE uuid = '{prop['uuid']}'") == ['low|["short_lease"]'])

# --- 3. Offer reasoning (manager only) ----------------------------------------------------------------------------------------
orq = task({"title": "Draft the offer", "deal_uuid": D, "agent_key": "offer_reasoning", "approval_rule": "any_operator"}, "offer task")
run_agent(orq, "offer reasoning")
a = approvals_for(orq)
check("offer: a manager-only approval whatever the task said", len(a) == 1 and a[0]["rule"] == "manager"
      and a[0]["action"] == "record_offer" and a[0]["payload"]["recommended"] == 128000, a)
res = call("POST", P + f"/approvals/{a[0]['uuid']}/decide", "operator_s", S, {"decision": "approve"})
check("offer: an operator can't approve it (403)", res[0] == 403, res)
approve(a[0])
d = data(call("GET", P + f"/deals/{D}", "operator_s", S), 200, "deal")
check("offer approved: recorded on the deal with the reasoning", float(d["offer_amount"]) == 128000 and "Offer reasoning" in d["notes"]
      and "median" in d["notes"], d)

# --- 4. Buyer matcher -------------------------------------------------------------------------------------------------------------
york = [{"type": "radius", "lat": 53.96, "lng": -1.08, "miles": 10}]
for first, email in (("Ann", "ann@buyers.test"), ("Bob", "bob@buyers.test")):
    c = expect("contact " + first, call("POST", API + "/api/v2/crm/contacts", "operator_s", S,
               {"first_name": first, "last_name": "Buyer", "email": email}), 201)
    c = c.get("data") or c
    data(call("POST", P + "/buyer-profiles", "operator_s", S, {"contact_uuid": c["uuid"], "price_max": 200000, "areas": york,
         "strategies": ["btl"]}), 201, "buyer " + first)
bm = task({"title": "Find buyers for 7 Mill Lane", "deal_uuid": D, "property_uuid": prop["uuid"], "agent_key": "buyer_matcher"},
          "matcher task")
run_agent(bm, "buyer matcher")
a = approvals_for(bm)
check("matcher: one personal deal pack per matching buyer", len(a) == 2 and all(x["action"] == "send_deal_pack" for x in a)
      and sorted(x["payload"]["to"] for x in a) == ["ann@buyers.test", "bob@buyers.test"], a)
approve(next(x for x in a if x["payload"]["to"] == "ann@buyers.test"))
check("matcher: the approved pack went to Ann only", len(emails_to("ann@buyers.test")) == 1 and emails_to("bob@buyers.test") == [])

# --- 7. Document checker (reads a PDF, cites the page) --------------------------------------------------------------------------------
pdf = make_pdf(["Title register\nTitle number NYK12345\nProprietor: P. Seller", "Charges register\nRestrictive covenant: no building "
                "beyond the rear wall\nwithout the consent of the transferor"])
boundary = "pdboundary" + uuidlib.uuid4().hex
body = b"".join([
    b"--" + boundary.encode() + b"\r\nContent-Disposition: form-data; name=\"deal_uuid\"\r\n\r\n" + D.encode() + b"\r\n",
    b"--" + boundary.encode() + b"\r\nContent-Disposition: form-data; name=\"category\"\r\n\r\ntitle\r\n",
    b"--" + boundary.encode() + b"\r\nContent-Disposition: form-data; name=\"file\"; filename=\"title-register.pdf\"\r\n"
    b"Content-Type: application/pdf\r\n\r\n" + pdf + b"\r\n",
    b"--" + boundary.encode() + b"--\r\n"])
st, up, _ = raw("POST", P + "/documents", "operator_s", S, body, "multipart/form-data; boundary=" + boundary)
check("upload the title register (PDF)", st == 201, up[:300])
dc = task({"title": "Check the legal pack", "deal_uuid": D, "agent_key": "document_checker"}, "document task")
r = run_agent(dc, "document checker")
steps = r.get("steps") if isinstance(r.get("steps"), list) else json.loads(r.get("steps") or "[]")
check("checker read the document with its tool", any(s.get("tool") == "read_document" for s in steps), steps)
a = approvals_for(dc)
fl = a[0]["payload"]["flags"][0] if a else {}
check("checker: flags the covenant on page 2 (pdftotext page markers), never clears", len(a) == 1 and a[0]["action"] == "add_red_flags"
      and fl.get("page") == 2 and fl.get("filename") == "title-register.pdf" and fl.get("severity") == "high", a)
approve(a[0])
e = sql(f"SELECT title || '|' || blocking || '|' || source FROM property_deals_enquiries WHERE deal_uuid = '{D}'")
check("approved flag → a blocking enquiry citing the document and page",
      e == ["Restrictive covenant on extensions (title-register.pdf, page 2)|true|agent"], e)

# --- 8. Compliance assistant (never passes a check) -----------------------------------------------------------------------------------
chk = data(call("POST", P + "/compliance-checks", "operator_s", S, {"check_type": "aml_cdd_seller", "subject_type": "deal",
           "deal_uuid": D, "party_role": "seller", "status": "in_progress"}), 201, "seller AML in progress")
ca = task({"title": "Prepare the AML checklist", "deal_uuid": D, "agent_key": "compliance_assistant"}, "compliance task")
run_agent(ca, "compliance assistant")
a = approvals_for(ca)
check("assistant: missing check, note and a mismatch, as a draft", len(a) == 1 and a[0]["action"] == "compliance_notes"
      and a[0]["payload"]["mismatches"], a)
approve(a[0])
rows = sql(f"SELECT check_type || '|' || status FROM property_deals_compliance_checks WHERE deal_uuid = '{D}' ORDER BY check_type")
check("assistant: buyer AML added as not_started; seller AML still in progress (a person signs off)",
      rows == ["aml_cdd_buyer|not_started", "aml_cdd_seller|in_progress"], rows)
check("assistant's note recorded on the check", "Passport" in sql(f"SELECT data->'assistant_notes'->>0 FROM property_deals_compliance_checks WHERE uuid = '{chk['uuid']}'")[0])

# --- 10. Investor update ------------------------------------------------------------------------------------------------------------
iu = task({"title": "Weekly investor update", "deal_uuid": D, "agent_key": "investor_update"}, "update task")
run_agent(iu, "investor update")
a = approvals_for(iu)
check("investor update: email to the buyer on the deal, with the reference", len(a) == 1 and a[0]["payload"]["to"] == "ivy@investors.test"
      and f"[PD-{D[:8]}]" in a[0]["payload"]["subject"], a)
approve(a[0])
check("sent once approved", len(emails_to("ivy@investors.test")) == 1)

# --- Supplier speed + reports ----------------------------------------------------------------------------------------------------------
sup = data(call("POST", P + "/suppliers", "operator_s", S, {"name": "Quick EPC", "email": "q@s.test", "kinds": ["epc_assessor"]}), 201, "supplier")
for i, (confirm_h, done_h, slot_end_h) in enumerate([(4, 48, 50), (24, 96, 72)]):
    sql(f"""INSERT INTO property_deals_bookings (namespace_id, supplier_uuid, deal_uuid, service, status, requested_at, confirmed_at,
           done_at, slot_end) SELECT namespace_id, '{sup['uuid']}', '{D}', 'epc', 'done', NOW() - interval '10 days',
           NOW() - interval '10 days' + interval '{confirm_h} hours', NOW() - interval '10 days' + interval '{done_h} hours',
           NOW() - interval '10 days' + interval '{slot_end_h} hours' FROM property_deals_deals WHERE uuid = '{D}'""")
n = data(call("POST", P + "/engine/run", "manager_s", S, {"checks": ["nightly"]}), 200, "nightly job")
s2 = data(call("GET", P + f"/suppliers/{sup['uuid']}", "operator_s", S), 200, "supplier")
check("nightly: measured turnaround and on-time % on the directory", n["nightly"]["suppliers"] == 1
      and float(s2["avg_turnaround_hours"]) == 72 and float(s2["on_time_pct"]) == 50 and s2["jobs_measured"] == 2, s2)
sp = data(call("GET", P + "/reports/supplier-speed", "operator_s", S), 200, "supplier speed report")
check("report: supplier speed", sp[0]["bookings"] == 2 and sp[0]["avg_hours_to_confirm"] == 14 and sp[0]["on_time_pct"] == 50, sp)

sql(f"""UPDATE property_deals_stage_history SET entered_at = NOW() - interval '5 days' WHERE deal_uuid = '{D}';
        INSERT INTO property_deals_stage_history (namespace_id, deal_uuid, stage_key, entered_at, left_at)
        SELECT namespace_id, uuid, 'offer_sent', NOW() - interval '20 days', NOW() - interval '17 days' FROM property_deals_deals WHERE uuid = '{D}'""")
stg = data(call("GET", P + "/reports/stage-times", "operator_s", S), 200, "stage times")
check("report: time per stage (completed) and current", any(r["stage_key"] == "offer_sent" and r["avg_days"] == 3 for r in stg["completed_stages"])
      and any(r["avg_days_so_far"] >= 5 for r in stg["current"]), stg)
data(call("PUT", P + f"/deals/{D}", "operator_s", S, {"status": "completed"}), 200, "complete the deal (target was 2026-09-01)")
late = data(call("GET", P + "/reports/late-days", "operator_s", S), 200, "late days")
check("report: late days and penalty cost (capped at 20 days × £100)", late["completed"] == 1 and late["late"] == 1
      and late["worst"][0]["days_late"] > 20 and late["penalty_cost"] == 2000, late)
check("completing closed the stage history", sql(f"SELECT COUNT(*) FROM property_deals_stage_history WHERE deal_uuid = '{D}' AND left_at IS NULL") == ["0"])
conv = data(call("GET", P + "/reports/conversion", "operator_s", S), 200, "conversion")
check("report: conversion totals and by source", conv["totals"]["leads"] >= 1 and conv["totals"]["deals"] == 1
      and conv["totals"]["completed"] == 1 and any(r["source"] == "website_form" for r in conv["by_source"]), conv["totals"])
sql(f"""INSERT INTO property_deals_chases (namespace_id, deal_uuid, to_party, channel, status, sent_at, reply_at)
        SELECT namespace_id, uuid, 'seller_solicitor', 'email', 'replied', NOW() - interval '3 days', NOW() - interval '1 day'
        FROM property_deals_deals WHERE uuid = '{D}'""")
ps = data(call("GET", P + "/reports/party-speed", "operator_s", S), 200, "party speed")
check("report: solicitor reply speed", any(r["to_party"] == "seller_solicitor" and r["replied"] >= 1 and r["avg_hours_to_reply"] > 0
      for r in ps["chases"]), ps)
ai = data(call("GET", P + "/reports/ai-usage", "operator_s", S), 200, "AI usage report")
check("report: AI runs per agent and approval outcomes", ai["daily"] and any(o["agent_key"] == "buyer_matcher" and o["drafts"] == 2
      and o["approved"] == 1 and o["pending"] == 1 for o in ai["approval_outcomes"]), ai["approval_outcomes"])
res = call("GET", P + "/reports/late-days", "reader", S)
check("reports need workspace membership", res[0] in (401, 403), res)

# --- Export --------------------------------------------------------------------------------------------------------------------------
data(call("PUT", P + f"/properties/{prop['uuid']}", "operator_s", S, {"notes": "=HYPERLINK(\"http://evil\")"}), 200, "a note that looks like a formula")
st, body, hdr = raw("GET", P + "/export/properties?format=csv", "manager_s", S)
text = body.decode()
check("export CSV: header starts with uuid, attachment, one row", st == 200 and text.splitlines()[0].startswith("uuid,")
      and "attachment" in hdr.get("Content-Disposition", "") and len(text.strip().splitlines()) == 2, (st, text[:300], hdr))
check("export CSV is spreadsheet-safe (formula cells prefixed)", "'=HYPERLINK" in text and ",=HYPERLINK" not in text, text[:500])
st, body, hdr = raw("GET", P + "/export/agent_runs?format=json", "manager_s", S)
rows = json.loads(body)
check("export JSON: all agent runs, no internal ids", st == 200 and len(rows) >= 7 and "namespace_id" not in rows[0] and "id" not in rows[0], rows[:1])
st, body, _ = raw("GET", P + "/export/properties?format=csv", "operator_s", S)
check("export is for managers (403 for an operator)", st == 403, body[:200])
st, body, _ = raw("GET", P + "/export/passwords", "manager_s", S)
check("unknown export → 404", st == 404, body[:200])

# --- Retention --------------------------------------------------------------------------------------------------------------------------
expect("short retention", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S,
       {"settings": {"retention_inbound_days": 30, "retention_agent_run_days": 30}}), 200)
data(call("POST", P + "/inbound-messages", "operator_s", S, {"from_address": "x@y.test", "body_text": "old email body", "deal_uuid": D}),
     201, "an email")
sql("UPDATE property_deals_inbound_messages SET received_at = NOW() - interval '40 days' WHERE body_text = 'old email body'")
sql(f"UPDATE property_deals_agent_runs SET created_at = NOW() - interval '40 days' WHERE task_uuid = '{lt}'")
n = data(call("POST", P + "/engine/run", "manager_s", S, {"checks": ["nightly"]}), 200, "nightly job")
check("retention: old email body and old run drafts removed, facts kept", n["nightly"]["inbound"] == 1 and n["nightly"]["agent_runs"] == 1
      and sql(f"SELECT (output_draft IS NULL AND output IS NULL)::text || '|' || status FROM property_deals_agent_runs WHERE task_uuid = '{lt}'")
      == ["true|succeeded"], n)

# --- Prometheus ------------------------------------------------------------------------------------------------------------------------
data(call("POST", P + "/engine/run", "manager_s", S, {"checks": ["sla"]}), 200, "engine run (publishes gauges)")
with urllib.request.urlopen(API + "/metrics", timeout=10) as r:
    metrics = r.read().decode()
check("metrics: workspace gauges and agent counters exported",
      'property_deals_tasks_open{namespace="seven-buyers"}' in metrics
      and 'property_deals_agent_runs_total{namespace="seven-buyers",agent="buyer_matcher",status="succeeded"}' in metrics
      and "property_deals_agent_cost_usd_total" in metrics, [l for l in metrics.splitlines() if "property_deals" in l][:10])

sys.exit(finish())
