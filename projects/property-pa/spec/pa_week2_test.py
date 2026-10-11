"""Property PA, Week 2 ("Capture"): voice/text capture -> the PA proposes -> one confirm sheet -> confirm / correct.

  * P03 the voice note becomes exactly the expected fields (the regression checker, proved both ways)
  * P04 next action "call Sarah tomorrow 11:00", owner Sophie, with the reason
  * P09 £225k stored as inferred, labelled "<author>'S JUDGEMENT, UNCONFIRMED"
  * P11 a correction replaces the value and keeps the history
  * P10 what the PA wrote carries the model and prompt version its run really used
The JobShout agent is played by the test (the 'agent' user posting /captures), as it would through opsapi_post.
"""
import copy
import datetime
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../../property-deals/spec"))
sys.path.insert(0, os.path.join(HERE, "regression"))
from pdtest import API, USERS, call, check, expect, finish, workspace  # noqa: E402
import scenes  # noqa: E402

PA = API + "/api/v2/property-pa"
PD = API + "/api/v2/property-deals"
MOCK = os.environ["PD_MOCK"]
SOPHIE, ASHLEY = "operator_s", "manager_s"


def data(res, status, name):
    body = expect(name, res, status)
    return body.get("data") if isinstance(body, dict) and "data" in body else body


def mock(method, path, body=None):
    req = urllib.request.Request(MOCK + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"null")


def london(dt):
    return dt + datetime.timedelta(hours=scenes._london_offset(dt))


S = workspace("owner_s", "PA Capture", "pa-capture")
for code in ("property_deals", "property_pa"):
    expect(f"enable {code}", call("PUT", API + f"/api/v2/namespace/plugins/{code}", "owner_s", S, {"enabled": True}), 200)
expect("deals setup", call("POST", PD + "/setup", "owner_s", S), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_s", S), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
role_id = {r["role_name"]: r["id"] for r in roles}
for user, role in ((SOPHIE, "pd_operator"), (ASHLEY, "pd_manager"), ("agent", "pd_agent")):
    expect(f"add {user}", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
           {"email": USERS[user][1], "role_ids": [role_id[role]]}), 201)
data(call("POST", PA + "/setup", "owner_s", S), 200, "PA setup")
fx = data(call("POST", PA + "/demo/reset", ASHLEY, S, {"sophie_user_uuid": USERS[SOPHIE][0],
          "ashley_user_uuid": USERS[ASHLEY][0]}), 200, "fixtures")
SARAH = fx["sarah"]["opportunity_uuid"]

# Not connected yet: the note is still saved.
r = data(call("POST", PA + "/captures/start", SOPHIE, S, {"text": "Quick note: Michael wants comparables.",
         "opportunity_uuid": fx["michael"]["opportunity_uuid"]}), 201, "a note while the PA is off")
check("note saved, PA not asked (and says why)", r["interaction"]["raw_text"].startswith("Quick note")
      and "JobShout" in r["pa"]["error"], r)

js = data(call("POST", API + "/api/v2/namespace/ai-providers", "owner_s", S, {"name": "JobShout PA", "provider_type": "jobshout",
          "base_url": "http://pd-mock:8080/js/api/v1", "username": "api-key", "secret": "jsk_test_key"}), 201, "JobShout link")
expect("PA settings", call("PUT", API + "/api/v2/namespace/plugins/property_pa", "owner_s", S, {"settings": {
    "jobshout_provider_uuid": js["uuid"], "jobshout_seller_agent_id": "seller-agent-1",
    "jobshout_manager_agent_id": "manager-agent-1", "jobshout_webhook_secret": "s3cret"}}), 200)

# --- Scene 3: Sophie's voice note -----------------------------------------------------------------------------------
summary = {"contract": "property-pa.output.v1", "mode": "capture", "answer": "I've proposed 5 updates for Sarah.",
           "sources": [{"type": "opportunity", "id": SARAH}], "unknowns": [], "inferences": ["£225k is Sophie's judgement"],
           "actions": [], "needs_human": True}
mock("POST", "/_ctl", {"pa_answer": summary["answer"] + "\n\n```pa_output\n" + json.dumps(summary) + "\n```"})
st = data(call("POST", PA + "/captures/start", SOPHIE, S, {"text": scenes.SCENE3_NOTE, "channel": "voice",
          "opportunity_uuid": SARAH}), 201, "Sophie's voice note (transcribed)")
IT = st["interaction"]["uuid"]
check("voice note stored as the transcript, PA asked", st["interaction"]["transcript"] == scenes.SCENE3_NOTE
      and st["interaction"]["channel"] == "voice" and st["pa"]["status"] == "running", st)
launch = mock("GET", "/_js")["launches"][-1]
check("the Seller PA runs in capture mode with the interaction", launch["skill_slugs"] == ["pa-capture"]
      and launch["inputs"]["interaction_uuid"] == IT and launch["inputs"]["opportunity_id"] == SARAH
      and scenes.SCENE3_NOTE in launch["values"]["prompt"], launch)

# The agent (through opsapi_post) proposes what the note says.
now = datetime.datetime.now(datetime.timezone.utc)
tomorrow_11 = london(now).date() + datetime.timedelta(days=1)
due = datetime.datetime(tomorrow_11.year, tomorrow_11.month, tomorrow_11.day, 11, tzinfo=datetime.timezone.utc)
due -= datetime.timedelta(hours=scenes._london_offset(due))
proposals = [
    {"target_table": "pa_events", "new_value": {"kind": "valuation", "at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "title": "Second agent's valuation", "details": {"amount": 240000, "by": "other agent"}, "opportunity_uuid": SARAH},
     "source_quote": "Second agent valued it at £240k", "confidence": 0.95},
    {"target_table": "pa_opportunities", "target_uuid": SARAH, "field": "expectation_price", "new_value": 235000,
     "source_quote": "She won't go below £235k", "confidence": 0.9},
    {"target_table": "pa_opportunities", "target_uuid": SARAH, "field": "decision_makers",
     "new_value": [{"name": "Sarah Hughes", "role": "owner"}, {"name": "Tom", "role": "husband"}],
     "source_quote": "Her husband Tom needs to agree", "confidence": 0.9},
    {"target_table": "pa_opportunities", "target_uuid": SARAH, "field": "our_position",
     "new_value": "£225k might work with completion in 4 weeks", "is_inferred": True,
     "source_quote": "I reckon £225k might work if we can complete in 4 weeks", "confidence": 0.6},
    {"target_table": "next_action", "new_value": {"title": "Call Sarah", "due_at": due.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "opportunity_uuid": SARAH, "reason": "She'll decide after speaking to Tom"},
     "source_quote": "Call her tomorrow at 11", "confidence": 0.9},
]
cap = data(call("POST", PA + "/captures", "agent", S, {"interaction_uuid": IT, "proposals": proposals}), 201,
           "the PA proposes from the note")

sheet = data(call("GET", PA + f"/interactions/{IT}/capture", SOPHIE, S), 200, "the confirm sheet")
rows = sheet["proposals"]
check("the run finished (polled) and the sheet has the 5 rows", sheet["run"]["status"] == "succeeded" and len(rows) == 5,
      sheet["run"])
problems = scenes.compare_scene3(rows, now)
check("P03/P04/P09: the scene 3 checker passes", problems == [], problems)
pos = next(r for r in rows if r["field"] == "our_position")
check("P09: £225k is labelled the author's judgement, unconfirmed", pos["kind"] == "inferred"
      and pos["kind_label"] == "PD'S JUDGEMENT, UNCONFIRMED" and sheet["author"] == "PD", pos)
kinds = {r["label"]: r["kind"] for r in rows}
check("rows typed stated / inferred / proposed with readable labels",
      kinds == {"Event": "proposed", "Seller's stated minimum": "stated", "Decision makers": "stated",
                "Price that might work": "inferred", "Next action": "proposed"}, kinds)
na = next(r for r in rows if r["target_table"] == "next_action")
check("P04: the next action's owner is Sophie (the opportunity's owner)", na["owner"]["user_uuid"] == USERS[SOPHIE][0], na)
check("material rows counted", sheet["counts"]["material"] == 3 and sheet["counts"]["proposed"] == 5, sheet["counts"])

# The checker really checks: break the rows and it fails.
bad = copy.deepcopy(rows)
bad = [r for r in bad if r["target_table"] != "pa_events"]
bad.append(dict(rows[1], field="primary_concern"))
bad.append(dict(rows[1], target_table="crm_contacts", field="mobile"))
next(r for r in bad if r["field"] == "our_position").update(is_inferred=False, kind_label="Stated")
next(r for r in bad if r["target_table"] == "next_action")["new_value"]["due_at"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
p = scenes.compare_scene3(bad, now)
check("the checker catches a missing event, an invented field, an unlabelled inference and the wrong time",
      any("missing: pa_events" in x for x in p) and any("extra" in x and "crm_contacts.mobile" in x for x in p)
      and any(x.startswith("P09") for x in p) and any(x.startswith("P04") for x in p), p)

# --- Confirm and correct ----------------------------------------------------------------------------------------------
res = call("POST", PA + f"/interactions/{IT}/decide", "agent", S, {"confirm_rest": True})
check("the PA can't confirm its own sheet (403)", res[0] == 403, res)
res = call("POST", PA + f"/interactions/{IT}/decide", SOPHIE, S, {"decisions": [{"uuid": cap["proposed_updates"][0]["uuid"],
           "action": "frobnicate"}]})
check("an unknown action is refused (422)", res[0] == 422, res)
res = call("POST", PA + f"/interactions/{IT}/decide", SOPHIE, S, {})
check("nothing to decide (422)", res[0] == 422, res)
ep = next(r for r in rows if r["field"] == "expectation_price")
out = data(call("POST", PA + f"/interactions/{IT}/decide", SOPHIE, S, {
    "decisions": [{"uuid": ep["uuid"], "action": "correct", "value": 237500}], "confirm_rest": True}), 200,
    "[Change something] then [Confirm]")
check("every row decided", all(x["ok"] for x in out["results"]) and len(out["results"]) == 5, out["results"])
c = out["sheet"]["counts"]
check("sheet now: 4 confirmed, 1 corrected, nothing waiting", c["confirmed"] == 4 and c["corrected"] == 1
      and c["proposed"] == 0, c)
again = data(call("POST", PA + f"/interactions/{IT}/decide", SOPHIE, S, {"decisions": [{"uuid": ep["uuid"],
             "action": "confirm"}]}), 200, "decide a row twice")
check("a decided row reports its conflict, nothing changes", again["results"][0]["ok"] is False
      and "Already" in again["results"][0]["error"], again["results"])

opp = data(call("GET", PA + f"/opportunities/{SARAH}", SOPHIE, S), 200, "Sarah after the sheet")
check("the CRM updated underneath: minimum £237,500 (corrected), Sarah + Tom", float(opp["expectation_price"]) == 237500
      and [d["name"] for d in opp["decision_makers"]] == ["Sarah Hughes", "Tom"], opp)
check("P09: our position stays inferred after confirming (a judgement, not a fact)",
      opp["facts"]["our_position"]["is_inferred"] is True and "225k" in opp["facts"]["our_position"]["value"],
      opp["facts"].get("our_position"))
acts = data(call("GET", PA + f"/next-actions?opportunity_uuid={SARAH}", SOPHIE, S), 200, "Sarah's next actions")
call_sarah = next((a for a in acts if a["title"] == "Call Sarah"), None)
due_got = datetime.datetime.fromisoformat(call_sarah["due_at"].replace("Z", "+00:00")) if call_sarah else None
check("P04: Call Sarah tomorrow 11:00 UK, owner Sophie, with the reason, from the voice note",
      call_sarah and call_sarah["owner_user_uuid"] == USERS[SOPHIE][0] and call_sarah["reason"]
      == "She'll decide after speaking to Tom" and call_sarah["created_from_interaction_uuid"] == IT
      and london(due_got.astimezone(datetime.timezone.utc)).hour == 11, call_sarah)
hist = data(call("GET", PA + f"/history/pa_opportunities/{SARAH}?field=expectation_price", SOPHIE, S), 200, "history")
check("P11: the correction replaced the value; the PA's £235k is kept", [h["value"] for h in hist] == [237500, 235000]
      and hist[1]["source"] == "ai" and hist[1]["superseded_by"] == hist[0]["uuid"], hist)
audit = data(call("GET", PA + f"/audit?target_uuid={SARAH}", ASHLEY, S), 200, "audit")
ai = [a for a in audit if a["source"] == "ai"]
check("P10: the PA's changes carry the model and prompt version its run used, and the run",
      ai and all(a["model"] == "openai_compatible:qwen3.8:latest" and a["prompt_version"] == "seller-pa@1.1.0"
                 and a["run_ref"] == st["pa"]["run_uuid"] for a in ai), ai)

# --- A typed note, and tenancy ------------------------------------------------------------------------------------------
t = data(call("POST", PA + "/captures/start", SOPHIE, S, {"text": "Rick rang back, wants to talk Friday.",
         "opportunity_uuid": fx["rick"]["opportunity_uuid"]}), 201, "a typed note")
check("typed notes are stored as the note's text", t["interaction"]["channel"] == "note"
      and t["interaction"]["raw_text"].startswith("Rick rang back"), t["interaction"])
B = workspace("owner_b", "PA Capture Other", "pa-capture-other")
for code in ("property_deals", "property_pa"):
    expect(f"enable {code} in B", call("PUT", API + f"/api/v2/namespace/plugins/{code}", "owner_b", B, {"enabled": True}), 200)
res = call("GET", PA + f"/interactions/{IT}/capture", "owner_b", B)
check("another workspace can't see the sheet (404)", res[0] == 404, res)
res = call("POST", PA + f"/interactions/{IT}/decide", "owner_b", B, {"confirm_rest": True})
check("nor decide it (404)", res[0] == 404, res)

sys.exit(finish())
