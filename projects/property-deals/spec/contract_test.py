"""Phase 4 contract: the screen endpoints (Today, board, deal overview, timeline, map, card, /me),
approvals (inbox, rules, edits), and the OpenAPI description behind @opsapi/client/property-deals.
Runs after scenario_test.py in the same sandbox (reuses "Demo Buyers Ltd").
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, sql, finish  # noqa: E402

S = sql("SELECT uuid FROM namespaces WHERE slug = 'demo-buyers'")[0]
B = sql("SELECT uuid FROM namespaces WHERE slug = 'other-co'")[0]
D = sql("SELECT d.uuid FROM property_deals_deals d JOIN crm_deals c ON c.uuid = d.crm_deal_uuid "
        "WHERE c.name = '7 Mill Lane' LIMIT 1")[0]

# --- /me ------------------------------------------------------------------------------------
me = expect("me (operator)", call("GET", P + "/me", "operator_s", S), 200)["data"]
check("operator permissions per module", "update" in me["permissions"]["tasks"] and me["permissions"]["settings"] == ["read"]
      and not me["is_manager"], me["permissions"])
mm = expect("me (manager)", call("GET", P + "/me", "manager_s", S), 200)["data"]
check("manager is_manager, settings shown", mm["is_manager"] and mm["settings"]["timezone"] == "Europe/London" and mm["setup_done"], mm)

# --- Today --------------------------------------------------------------------------------------
tm = expect("today (manager)", call("GET", P + "/today", "manager_s", S), 200)["data"]
check("Today: my tasks by urgency, escalated EPC task first", tm["tasks"] and tm["tasks"][0]["title"] == "Book an EPC assessor"
      and tm["tasks"][0]["overdue"], [t["title"] for t in tm["tasks"][:3]])
check("Today: red deals with £ at risk", any(d["uuid"] == D for d in tm["red_deals"]) and tm["money_at_risk"] > 0, tm["red_deals"])
check("Today: counts", tm["counts"]["open"] >= 1 and tm["counts"]["overdue"] >= 1, tm["counts"])
to = expect("today (operator)", call("GET", P + "/today", "operator_s", S), 200)["data"]
check("Today (operator): sees the red deal they work on", any(d["uuid"] == D for d in to["red_deals"]), to["red_deals"])
tb = expect("today (other workspace)", call("GET", P + "/today", "owner_b", B), 200)["data"]
check("Today in another workspace shows none of it", D not in json.dumps(tb), None)

# --- Board ------------------------------------------------------------------------------------------
bd = expect("deal board", call("GET", P + "/deals/board", "operator_s", S), 200)["data"]
cols = {c["key"]: c for c in bd["columns"]}
check("board: stage columns from the template (route isn't taken for a deal id)",
      bd["template"]["key"] == "uk_guaranteed_sale" and "searches" in cols, list(cols)[:6])
check("board: the deal sits in Searches", any(d["uuid"] == D for d in cols["searches"]["deals"]), cols["searches"]["deals"])
check("board: gate hints (Exchange has a gate)", cols["exchange"]["has_gate"] and cols["exchange"]["gate_summary"]["compliance"] >= 1
      and not cols["searches"]["has_gate"], cols["exchange"])

# --- Deal overview + timeline ----------------------------------------------------------------------
ov = expect("deal overview", call("GET", P + f"/deals/{D}/overview", "operator_s", S), 200)["data"]
states = {s["key"]: s["state"] for s in ov["stage"]["stages"]}
check("overview: stage states", states["new_lead"] == "done" and states["searches"] == "current"
      and states["exchange"] == "upcoming" and states["lease_pack"] == "skipped", states)
check("overview: next stage and its gate", ov["stage"]["next"] == "enquiries" and ov["stage"]["next_gate"]["ok"] is True, ov["stage"])
check("overview: health block", ov["health"]["health"] == "red" and float(ov["health"]["money_at_risk"]) > 0
      and ov["health"]["working_days_left"] == 9, ov["health"])
check("overview: open tasks + counts", ov["tasks"]["counts"]["total"] >= 5 and ov["tasks"]["open"], ov["tasks"]["counts"])
check("overview: 2 open enquiries, chase log", len(ov["enquiries"]) == 2 and ov["recent_chases"], None)
comp = {c["key"]: c for c in ov["compliance"]}
check("overview: compliance list from the template", comp["aml_cdd_buyer"]["status"] == "in_progress"
      and comp["sanctions_pep_seller"]["status"] == "not_started", {k: v["status"] for k, v in comp.items()})
check("overview: seller party with contact details", any(p["role"] == "seller" and p.get("name") for p in ov["parties"]), ov["parties"])
tl = expect("timeline", call("GET", P + f"/deals/{D}/timeline", "operator_s", S), 200)
check("timeline answers (audit trail, newest first)", isinstance(tl["data"], list), tl.get("meta"))
for path in (f"/deals/{D}/overview", f"/deals/{D}/timeline"):
    res = call("GET", P + path, "owner_b", B)
    check(f"other workspace: {path.split('/')[-1]} 404", res[0] == 404, res)

# --- Map + card --------------------------------------------------------------------------------------
mp = expect("map radius", call("GET", P + "/map?lat=53.95&lng=-1.09&radius_miles=5&layers=properties,deals", "operator_s", S), 200)["data"]
deal_pins = [f for f in mp["features"] if f["layer"] == "deals"]
check("map: the deal's property is a deal pin with health", any(f.get("deal_uuid") == D and f["deal_health"] == "red" for f in deal_pins), mp["features"])
check("map: distance computed", all(0 <= f["distance_miles"] <= 5 for f in mp["features"]), None)
far = expect("map far away", call("GET", P + "/map?lat=51.5&lng=-0.12&radius_miles=10", "operator_s", S), 200)["data"]
check("map: nothing near London", not far["features"], far["features"])
poly = expect("map polygon", call("GET", P + "/map?polygon=53.9,-1.2;54.0,-1.2;54.0,-1.0;53.9,-1.0&layers=deals", "operator_s", S), 200)["data"]
check("map: polygon finds the deal", any(f.get("deal_uuid") == D for f in poly["features"]), poly)
res = call("GET", P + "/map?lat=999&lng=0", "operator_s", S)
check("map: bad centre 422", res[0] == 422, res)
res = call("GET", P + "/map?lat=53.9&lng=-1.1&layers=sold_prices", "operator_s", S)
check("map: unknown layer 422 (connector layers come later)", res[0] == 422, res)
res = call("GET", P + "/map?lat=53.95&lng=-1.09&radius_miles=50", "owner_b", B)
check("map: other workspace sees no pins", res[0] == 200 and not res[1]["data"]["features"], res)
prop = sql(f"SELECT property_uuid FROM property_deals_deals WHERE uuid = '{D}'")[0]
card = expect("property card", call("GET", P + f"/properties/{prop}/card", "operator_s", S), 200)["data"]
check("card: property + its deal", card["property"]["uuid"] == prop and card["deal"]["uuid"] == D, card)

# --- Approvals ------------------------------------------------------------------------------------------
draft = {"to": "seller.solicitor@example.invalid", "subject": "Two open enquiries", "body": "Please reply to 1) FENSA 2) boundary."}
a = expect("operator asks for approval", call("POST", P + "/approvals", "operator_s", S,
           {"subject_type": "chase", "action": "send_email", "title": "Chase seller's solicitor", "payload": draft,
            "deal_uuid": D}), 201)["data"]
check("approval pending, payload hashed", a["status"] == "pending" and len(a["payload_sha256"]) == 64, a)
inbox_op = expect("operator inbox", call("GET", P + "/approvals/inbox", "operator_s", S), 200)
check("requester doesn't see own request as decidable", not any(x["uuid"] == a["uuid"] for x in inbox_op["data"]), inbox_op["data"])
inbox_m = expect("manager inbox", call("GET", P + "/approvals/inbox", "manager_s", S), 200)["data"]
check("manager's inbox has it (can_decide)", any(x["uuid"] == a["uuid"] and x["can_decide"] for x in inbox_m), inbox_m)
res = call("POST", P + f"/approvals/{a['uuid']}/decide", "operator_s", S, {"decision": "approve"})
check("can't approve your own request (403)", res[0] == 403, res)
res = call("POST", P + f"/approvals/{a['uuid']}/decide", "manager_s", S, {"decision": "reject"})
check("reject needs a note (422)", res[0] == 422, res)
edited = dict(draft, body="Please reply today to 1) FENSA 2) boundary dispute.")
ok = expect("manager approves an edited version", call("POST", P + f"/approvals/{a['uuid']}/decide", "manager_s", S,
            {"decision": "approve", "payload": edited, "note": "Tightened wording"}), 200)["data"]
# Approved actions run straight away (Phase 5). This workspace has no email server, so the send
# fails cleanly and the approval says why (it can be retried once SMTP is set).
check("approved and run: no SMTP here, so 'failed' with the reason", ok["status"] == "failed"
      and "email server" in ok["execution_result"]["error"], ok)
check("approved; edit is version 2; original kept", ok["payload_version"] == 2
      and ok["payload"]["body"] == edited["body"] and ok["original_payload"]["body"] == draft["body"], ok)
check("decision logged with who and the hash", ok["decisions"][0]["user_uuid"] == USERS["manager_s"][0]
      and ok["decisions"][0]["edited"] and ok["decisions"][0]["payload_sha256"] == ok["payload_sha256"], ok["decisions"])
res = call("POST", P + f"/approvals/{a['uuid']}/decide", "owner_s", S, {"decision": "approve"})
check("decided approvals can't be decided again (409)", res[0] == 409, res)

two = expect("two-person approval", call("POST", P + "/approvals", "operator_s", S,
             {"subject_type": "other", "action": "release_funds", "title": "Release completion funds", "payload": {"amount": 150000},
              "rule": "two_person", "deal_uuid": D}), 201)["data"]
first = expect("first approver", call("POST", P + f"/approvals/{two['uuid']}/decide", "manager_s", S, {"decision": "approve"}), 200)["data"]
check("still pending after one approval", first["status"] == "pending" and first.get("waiting_for") == "a second person", first)
res = call("POST", P + f"/approvals/{two['uuid']}/decide", "manager_s", S, {"decision": "approve"})
check("same person can't approve twice (409)", res[0] == 409, res)
second = expect("second approver", call("POST", P + f"/approvals/{two['uuid']}/decide", "owner_s", S, {"decision": "approve"}), 200)["data"]
check("approved by two different people (nothing automatic to run for this action)",
      second["status"] == "executed" and len(second["decisions"]) == 2 and second.get("decided_at"), second)

mgr = expect("manager-only approval", call("POST", P + "/approvals", "manager_s", S,
             {"subject_type": "offer", "action": "send_offer", "title": "Offer £140k", "payload": {"amount": 140000},
              "rule": "manager", "deal_uuid": D}), 201)["data"]
res = call("POST", P + f"/approvals/{mgr['uuid']}/decide", "operator_s", S, {"decision": "approve"})
check("operator can't approve a manager-rule request (403)", res[0] == 403, res)
rej = expect("owner rejects", call("POST", P + f"/approvals/{mgr['uuid']}/decide", "owner_s", S,
             {"decision": "reject", "note": "Wait for the survey"}), 200)["data"]
check("rejected with the note", rej["status"] == "rejected" and rej["decisions"][0]["note"] == "Wait for the survey", rej)
res = call("POST", P + f"/approvals/{a['uuid']}/decide", "owner_b", B, {"decision": "approve"})
check("other workspace can't touch it (404)", res[0] == 404, res)

# --- OpenAPI: every Property Deals operation is typed -------------------------------------------------
st, spec = call("GET", API + "/openapi.json", "owner_s")
ops = [(p, m, o) for p, item in spec["paths"].items() if "/property-deals" in p for m, o in item.items()]
generic = [(m, p) for p, m, o in ops if not o.get("operationId", "").startswith("property_deals_")]
check(f"openapi: {len(ops)} Property Deals operations, all typed", len(ops) >= 90 and not generic, generic[:5])
refs = set()
def walk(n):
    if isinstance(n, dict):
        if "$ref" in n: refs.add(n["$ref"].split("/")[-1])
        for v in n.values(): walk(v)
    elif isinstance(n, list):
        for v in n: walk(v)
walk(spec["paths"])
missing = [r for r in refs if r not in spec["components"]["schemas"]]
check("openapi: no dangling schema refs", not missing, missing)
check("openapi: screen schemas present", all(k in spec["components"]["schemas"] for k in
      ("PropertyDealsToday", "PropertyDealsDealOverview", "PropertyDealsMapResult", "PropertyDealsApproval")), None)

sys.exit(finish())
