"""Property PA sample story (POST /demo/reset { story: true }; docs/property-pa/06-sample-data.md).

Every screen has something to show before a real model is connected, and the sample goes through the real code:
captures confirmed / corrected / rejected / waiting, an offer and handoffs, answers shown and withheld by the real
checks, and the rules the PA has learnt. A reset removes it all, and a reset without the story leaves none behind.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pa_common import ASHLEY, PA, SOPHIE, data, platform_admin, setup  # noqa: E402
from pdtest import USERS, call, check, finish, sql  # noqa: E402

S, fx = setup("PA Story", "pa-story")
BODY = {"sophie_user_uuid": USERS[SOPHIE][0], "ashley_user_uuid": USERS[ASHLEY][0], "story": True}
ADMIN = platform_admin()
res = call("POST", PA + "/demo/reset", ASHLEY, S, BODY)
check("only a platform admin can load the sample (404 for a manager)", res[0] == 404, res)
fx = data(call("POST", PA + "/demo/reset", ADMIN, S, BODY), 200, "load the sample story")
check("story summary", fx.get("story") == {"captures": 3, "answers": 4, "handoffs": 2, "rules": 4}, fx.get("story"))
MICHAEL, PRIYA = fx["michael"]["opportunity_uuid"], None
opps = {o["title"].split(" —")[0]: o["uuid"] for o in
        data(call("GET", PA + "/opportunities?mine=true&per_page=50", SOPHIE, S), 200, "opportunities")}
PRIYA, HELEN, DEV, GARY = opps["Priya Shah"], opps["Helen Price"], opps["Dev Patel"], opps["Gary Lowe"]

# --- Captures -------------------------------------------------------------------------------------------------------
def sheet_for(opp):
    rows = data(call("GET", PA + f"/proposed-updates?target_uuid={opp}", SOPHIE, S), 200, "proposals")
    it = next(r["source_interaction_uuid"] for r in rows if r["source_interaction_uuid"])
    return data(call("GET", PA + f"/interactions/{it}/capture", SOPHIE, S), 200, "capture sheet")


m = sheet_for(MICHAEL)
st = {p["label"]: p["status"] for p in m["proposals"]}
check("Michael: 6 proposals, all decided; the AI's 'hot' guess corrected", m["counts"]["confirmed"] == 5
      and m["counts"]["corrected"] == 1 and st.get("Temperature") == "corrected", m["counts"])
check("the sample is labelled, never passed off as a live model", m["run"]["model"] == "sample-data"
      and all(p["model"] == "sample-data" and p["prompt_version"] == "sample" for p in m["proposals"]), m["run"])
check("the inferred row reads as Sophie's judgement", any(p["kind"] == "inferred" and "JUDGEMENT" in p["kind_label"]
      for p in m["proposals"]), [p["kind_label"] for p in m["proposals"]])
o = data(call("GET", PA + f"/opportunities/{MICHAEL}", SOPHIE, S), 200, "Michael")
check("confirmed values are on the record (minimum, Karen, temperature as corrected)", float(o["expectation_price"]) == 260000
      and "Karen" in str(o["decision_makers"]) and o["temperature"] == "warm", o)
check("the promised comparables became a next action with its reason",
      any("comparables" in a["title"] and a.get("reason") for a in o["next_actions"]), o["next_actions"])
hist = data(call("GET", PA + f"/history/pa_opportunities/{MICHAEL}?field=temperature", SOPHIE, S), 200, "temperature history")
vals = [h["value"] for h in (hist if isinstance(hist, list) else hist.get("temperature", hist.get("facts", [])))]
check("the AI's 'hot' stays in the history under Sophie's 'warm'", "hot" in vals and "warm" in vals, hist)
p = sheet_for(PRIYA)
check("Priya: price corrected, the 'hot' guess rejected", p["counts"]["corrected"] == 1 and p["counts"]["rejected"] == 1
      and p["counts"]["confirmed"] == 2, p["counts"])
o = data(call("GET", PA + f"/opportunities/{PRIYA}", SOPHIE, S), 200, "Priya")
check("Priya's minimum is Sophie's £210k, not the AI's £215k", float(o["expectation_price"]) == 210000, o["expectation_price"])
h = sheet_for(HELEN)
check("Helen: a fresh note waiting for Sophie", h["counts"]["proposed"] == 4, h["counts"])
day = data(call("GET", PA + "/today", SOPHIE, S), 200, "Today")
helen = next(c for c in day["cards"] if c["opportunity_uuid"] == HELEN)
check("Today shows Helen's changes waiting", any(s["key"] == "changes_waiting" for s in helen["signals"]), helen["signals"])
check("Sarah is still #1", day["cards"][0]["opportunity_uuid"] == fx["sarah"]["opportunity_uuid"], day["cards"][0]["title"])

# --- Manager Today, metrics -------------------------------------------------------------------------------------------
mt = data(call("GET", PA + "/manager/today", ASHLEY, S), 200, "Manager Today")
check("Dev's handoff is waiting for Ashley", any(x["opportunity_uuid"] == DEV for x in mt["handoffs"]), mt["handoffs"])
neg = {x["opportunity_uuid"]: x["text"] for x in mt["unusual_negotiations"]}
check("Dev's offer waiting; Gary's position far below his minimum", DEV in neg and GARY in neg, neg)
p = data(call("GET", PA + f"/prepare/{PRIYA}", SOPHIE, S), 200, "Prepare on Priya")
check("Ashley's answer to Priya's handoff is in Sophie's brief", any("Raj confirms" in r["text"] for r in p["manager_replies"]),
      p["manager_replies"])
mx = data(call("GET", PA + "/metrics", ASHLEY, S), 200, "metrics")
c, a = mx["capture"], mx["answers"]
check("capture metrics: 14 proposals, 7 confirmed, 2 corrected, 1 rejected, 4 waiting", (c["proposals"], c["confirmed"],
      c["corrected"], c["rejected"], c["waiting"]) == (14, 7, 2, 1, 4), c)
check("answers: the real checks passed 2 + 3 capture runs and withheld 2", a["runs"] == 7 and a["grounded"] == 5
      and a["withheld"] == 2, a)
check("handoffs: 2, one waiting", mx["handoffs"]["total"] == 2 and mx["handoffs"]["waiting"] == 1, mx["handoffs"])
runs = sql(f"""SELECT input_snapshot ->> 'message', output ->> 'grounded', output ->> 'withheld' FROM property_deals_agent_runs
    r JOIN namespaces n ON n.id = r.namespace_id WHERE n.uuid = '{S}' AND input_snapshot ->> 'mode' IN ('ask', 'coach')
    ORDER BY r.created_at""")
by = {r[0]: r for r in (line.split("|") for line in runs)}
check("withheld: a figure that isn't on record", by["What will Dev accept?"][1] == "false"
      and "isn't on record" in by["What will Dev accept?"][2], by.get("What will Dev accept?"))
check("withheld: coaching that suggested paying more", "suggested paying more"
      in (by["Dev is pushing back on £150k. What should I say?"][2] or ""), by.get("Dev is pushing back on £150k. What should I say?"))
check("shown: Michael's minimum with its source", by["What is Michael's minimum and who has to agree?"][1] == "true", runs)

# --- Learnt rules --------------------------------------------------------------------------------------------------------
pend = data(call("GET", PA + "/knowledge/pending", ASHLEY, S), 200, "pending rules")
check("the PA's own proposal (from Sophie's corrections) waits for a manager",
      any(r["key"] == "temperature_is_the_agents_call" and r["proposed_by_ai"] for r in pend), pend)
rules = {r["key"]: r for r in data(call("GET", PA + "/knowledge", SOPHIE, S), 200, "Sophie's rules")}
check("probate rule is on v2", rules["probate_valuation_timing"]["current_version"] == 2, rules.get("probate_valuation_timing"))
k = data(call("GET", PA + f"/knowledge/{rules['probate_valuation_timing']['uuid']}", SOPHIE, S), 200, "probate history")
check("v1 kept as superseded history", [v["status"] for v in k["versions"]] == ["approved", "superseded"], k["versions"])
check("Sophie's personal rule is hers", rules["helen_speak_to_jo"]["scope"] == "personal", rules.get("helen_speak_to_jo"))
check("Ashley doesn't see Sophie's personal rule", "helen_speak_to_jo" not in
      {r["key"] for r in data(call("GET", PA + "/knowledge", ASHLEY, S), 200, "Ashley's rules")})
check("a rejected rule is never used", "competitor_fees" not in rules and "temperature_is_the_agents_call" not in rules)

# --- Reset ----------------------------------------------------------------------------------------------------------------
fx2 = data(call("POST", PA + "/demo/reset", ADMIN, S, {k: v for k, v in BODY.items() if k != "story"}), 200, "reset, no story")
left = sql(f"""SELECT (SELECT COUNT(*) FROM pa_proposed_updates p WHERE p.namespace_id = n.id),
    (SELECT COUNT(*) FROM property_deals_agent_runs r WHERE r.namespace_id = n.id AND r.provider = 'jobshout-pa'),
    (SELECT COUNT(*) FROM pa_knowledge k WHERE k.namespace_id = n.id AND k.key IN ('temperature_is_the_agents_call',
        'probate_valuation_timing', 'helen_speak_to_jo', 'competitor_fees')),
    (SELECT COUNT(*) FROM pa_handoffs h WHERE h.namespace_id = n.id),
    (SELECT COUNT(*) FROM pa_field_facts f WHERE f.namespace_id = n.id AND f.target_uuid NOT IN
        (SELECT uuid::text FROM pa_opportunities WHERE namespace_id = n.id))
    FROM namespaces n WHERE n.uuid = '{S}'""")[0].split("|")
check("a plain reset leaves nothing of the story behind", [int(x) for x in left] == [0, 0, 0, 0, 0], left)
check("and keeps no fixture as 'real work' because of it", fx2["kept"] == 0 and fx2["cleared"] == 11, fx2)
check("and the playbook is untouched", len(data(call("GET", PA + "/knowledge", ASHLEY, S), 200, "playbook")) == 10)
fx3 = data(call("POST", PA + "/demo/reset", ADMIN, S, BODY), 200, "load the story twice")
check("loading it again replaces it, never duplicates", fx3["story"]["captures"] == 3 and len(
      data(call("GET", PA + "/knowledge/pending", ASHLEY, S), 200, "pending")) == 1)

sys.exit(finish())
