"""Property PA, Week 3 ("Think"): Today, Why #1, Prepare Me, Coach, Teach.

  * P01 Today ranks Sarah #1 with the right reason (her promise is due and the second valuation was yesterday)
  * P07 "Why #1?" lists the real signals with their weights, each traceable to a record
  * P02 Prepare Me: every fact maps to a record (checked by the grounding check), unknowns become questions
  * P06 Coach suggests questions, never a higher offer; a coach answer that suggests paying more is withheld
  * Scene 6: Ashley teaches "a valuation is an anchor, not a minimum"; it appears in Sophie's next brief on Sarah
"""
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pa_common import ASHLEY, PA, SOPHIE, data, mock, pa_answer, setup  # noqa: E402
from pdtest import USERS, call, check, finish, sql  # noqa: E402
import scenes  # noqa: E402

S, fx = setup("PA Think", "pa-think", jobshout=True)
SARAH, RICK = fx["sarah"]["opportunity_uuid"], fx["rick"]["opportunity_uuid"]


def grounded(items, name):
    """Every item's text, cited by its ref (with its label), passes the grounding check."""
    claims = [{"text": i["text"] + (f" ({i['label']})" if i.get("label") else ""), "refs": [i["ref"]]} for i in items]
    r = data(call("POST", PA + "/grounding/check", SOPHIE, S, {"text": "\n".join(c["text"] for c in claims),
             "claims": claims}), 200, name)
    return r


# --- P01 / P07: Today and why ------------------------------------------------------------------------------------------
day = data(call("GET", PA + "/today", SOPHIE, S), 200, "Sophie's Today")
cards = day["cards"]
check("P01: Sarah is #1", cards[0]["opportunity_uuid"] == SARAH and cards[0]["rank"] == 1, [c["title"] for c in cards[:3]])
check("P01: for the right reason (her promise is due; the valuation was yesterday)",
      cards[0]["signals"][0]["key"] == "promise_due" and "decide after the second valuation" in cards[0]["why_now"]
      and any(s["key"] == "event_just_happened" and "yesterday" in s["text"] for s in cards[0]["signals"]), cards[0])
check("the card says what to do and why", cards[0]["action"] == "Call Sarah"
      and "decision" in cards[0]["objective"], cards[0])
check("all 11 opportunities ranked", len(cards) == 11 and [c["rank"] for c in cards] == list(range(1, 12)), len(cards))
rick = next(c for c in cards if c["opportunity_uuid"] == RICK)
rwhy = data(call("GET", PA + f"/today/why/{RICK}", SOPHIE, S), 200, "Why is Rick where he is?")
check("Why for one card ranks it exactly where Today does", rwhy["rank"] == next(c["rank"] for c in cards
      if c["opportunity_uuid"] == RICK) and rwhy["score"] == next(c["score"] for c in cards
      if c["opportunity_uuid"] == RICK), rwhy)
idx = sql("SELECT string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE indexname IN "
          "('idx_pd_task_details_pa_opp', 'idx_pd_agent_runs_pa_run', 'idx_pd_agent_runs_pa_interaction', "
          "'idx_pa_pu_target', 'idx_pa_pu_run', 'idx_pa_facts_run')")
check("the PA's lookups are indexed (next actions per opportunity, runs by JobShout id / interaction, proposals)",
      idx == ["idx_pa_facts_run,idx_pa_pu_run,idx_pa_pu_target,idx_pd_agent_runs_pa_interaction,"
              "idx_pd_agent_runs_pa_run,idx_pd_task_details_pa_opp"], idx)
check("Rick's silence is a signal (relationship risk)", any(s["key"] == "gone_quiet" for s in rick["signals"])
      and "follow-up" in rick["action"], rick)
why = data(call("GET", PA + f"/today/why/{SARAH}", SOPHIE, S), 200, "Why #1?")
check("P07: Why #1 lists every signal with its weight, and the score is their sum",
      why["rank"] == 1 and why["of"] == 11 and why["score"] == sum(s["weight"] for s in why["signals"])
      and all(s["weight"] == why["weights"][s["key"]] for s in why["signals"]) and len(why["signals"]) >= 3, why)
r = grounded([{"text": s["text"], "ref": s["ref"]} for s in why["signals"] if s.get("ref")], "signals ground")
check("P07: each signal traces to a record in this workspace", r["ok"], r)
budget = data(call("GET", PA + "/today?minutes=30", SOPHIE, S), 200, "I have 30 minutes")["budget"]
check("a 30-minute budget fits the top cards and says what waits", budget["used"] <= 30 and budget["fits"]
      and budget["fits"][0]["opportunity_uuid"] == SARAH and len(budget["waits"]) > 0, budget)
res = call("GET", PA + "/today?minutes=2", SOPHIE, S)
check("a silly budget is refused (422)", res[0] == 422, res)
check("Ashley's Today has none of Sophie's opportunities", data(call("GET", PA + "/today", ASHLEY, S), 200,
      "Ashley's Today")["cards"] == [])
res = call("GET", PA + f"/today/why/{SARAH}", ASHLEY, S)
check("nor a Why for them (404)", res[0] == 404, res)

# --- P02: Prepare me for Sarah (before and after the voice note) ----------------------------------------------------------
p = data(call("GET", PA + f"/prepare/{SARAH}", SOPHIE, S), 200, "Prepare me for Sarah")
check("P02: unknowns are said as unknown, with the question to ask", "expectation_price" in p["unknowns"]
      and any(q["field"] == "expectation_price" for q in p["questions"]) and "timescale" in p["unknowns"], p["unknowns"])
check("the promise and the last interaction are in it", p["promises"] and p["last_interaction"]["ref"].startswith("crm_activities:"),
      p["promises"])
check("the relevant playbook rules are picked by the situation", {"seller_competing_valuation", "grounded_or_silent",
      "seller_follow_up_promise"} <= {k["key"] for k in p["playbook"]}, [k["key"] for k in p["playbook"]])
# Sophie's voice note (week 2 flow, the agent's part played here), confirmed.
st = data(call("POST", PA + "/captures/start", SOPHIE, S, {"text": scenes.SCENE3_NOTE, "channel": "voice",
          "opportunity_uuid": SARAH}), 201, "voice note")
IT = st["interaction"]["uuid"]
now = datetime.datetime.now(datetime.timezone.utc)
data(call("POST", PA + "/captures", "agent", S, {"interaction_uuid": IT, "proposals": [
    {"target_table": "pa_events", "new_value": {"kind": "valuation", "at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "title": "Second agent's valuation", "details": {"amount": 240000}, "opportunity_uuid": SARAH},
     "source_quote": "Second agent valued it at £240k"},
    {"target_table": "pa_opportunities", "target_uuid": SARAH, "field": "expectation_price", "new_value": 235000,
     "source_quote": "She won't go below £235k"},
    {"target_table": "pa_opportunities", "target_uuid": SARAH, "field": "decision_makers",
     "new_value": [{"name": "Sarah Hughes", "role": "owner"}, {"name": "Tom", "role": "husband"}],
     "source_quote": "Her husband Tom needs to agree"},
    {"target_table": "pa_opportunities", "target_uuid": SARAH, "field": "our_position",
     "new_value": "£225k might work with completion in 4 weeks", "is_inferred": True,
     "source_quote": "I reckon £225k might work if we can complete in 4 weeks"},
]}), 201, "the PA proposes")
data(call("POST", PA + f"/interactions/{IT}/decide", SOPHIE, S, {"confirm_rest": True}), 200, "Sophie confirms")
p = data(call("GET", PA + f"/prepare/{SARAH}", SOPHIE, S), 200, "Prepare me again")
items = p["snapshot"] + p["price"] + p["decision_makers"] + p["promises"] + p["objections"] + [p["last_interaction"]]
check("every line of the brief has a source", all(i.get("ref") for i in items), [i for i in items if not i.get("ref")])
r = grounded(items, "the whole brief grounds")
check("P02: every material fact in the brief maps to a record (grounding check passes)", r["ok"], r)
texts = " | ".join(i["text"] for i in p["price"])
check("price position: her minimum (stated), the £240k valuation, our position (judgement, unconfirmed)",
      "£235,000" in texts and "£240,000" in texts and any(i["label"] == "judgement, unconfirmed" and "225k" in i["text"]
                                                            for i in p["price"]), p["price"])
check("decision makers now Sarah and Tom; no longer unknown", "Tom" in p["decision_makers"][0]["text"]
      and "decision_makers" not in p["unknowns"] and "expectation_price" not in p["unknowns"], p["unknowns"])

# --- Scene 6: Ashley teaches a rule -------------------------------------------------------------------------------------------
RULE = "An agent's valuation is not the seller's minimum price. Treat it as their anchor."
res = call("POST", PA + "/knowledge/teach", SOPHIE, S, {"statement": RULE, "approve": True})
check("an agent can't teach and approve a company rule (403)", res[0] == 403, res)
t = data(call("POST", PA + "/knowledge/teach", ASHLEY, S, {"statement": RULE, "title": "A valuation is an anchor, not a minimum",
         "scope": "company", "domain": "seller", "triggers": ["valuation", "price"], "rationale": "Scene 6",
         "approve": True}), 201, "Ashley teaches the company")
check("taught, approved and versioned in one step", t["status"] == "approved" and t["current_version"] == 1
      and t["key"] == "a_valuation_is_an_anchor_not_a_minimum" and t["approved_by_user_uuid"] == USERS[ASHLEY][0], t)
p = data(call("GET", PA + f"/prepare/{SARAH}", SOPHIE, S), 200, "Sophie's next brief on Sarah")
check("scene 6: the new rule is in Sophie's next brief about Sarah",
      any(k["key"] == "a_valuation_is_an_anchor_not_a_minimum" and k["rule"] == RULE for k in p["playbook"]), p["playbook"])
mine = data(call("POST", PA + "/knowledge/teach", SOPHIE, S, {"statement": "Call Sarah after school pick-up.",
            "scope": "personal", "approve": True}), 201, "Sophie teaches herself")
check("personal rules: the owner approves her own", mine["status"] == "approved" and mine["scope"] == "personal", mine)
draft = data(call("POST", PA + "/knowledge/teach", SOPHIE, S, {"statement": "Always offer a free valuation.",
             "scope": "company"}), 201, "Sophie suggests a company rule")
check("an agent's company rule waits for a manager", draft["status"] == "proposed", draft)

# --- P06: Coach -------------------------------------------------------------------------------------------------------
c = data(call("GET", PA + f"/coach/{SARAH}?situation=Sarah%20won't%20move%20below%20235k", SOPHIE, S), 200, "coach")
check("P06: coach separates known (cited) from assumed", c["known"] and c["assumed"]
      and all(k.get("ref") for k in c["known"]) and any("225k" in a["text"] for a in c["assumed"]), c)
check("P06: coach suggests questions, with no figure in them", len(c["questions"]) >= 4
      and not any("£" in q or any(ch.isdigit() for ch in q) for q in c["questions"]), c["questions"])
check("P06: and says plainly it won't suggest a higher offer", "higher offer" in c["never"]
      and "authority" in c["next_step"], c)
check("coach points to the relevant rules", {"seller_no_higher_offer", "a_valuation_is_an_anchor_not_a_minimum"}
      <= {k["key"] for k in c["playbook"]}, [k["key"] for k in c["playbook"]])
SRC = [{"type": "opportunity", "id": SARAH}]
mock("POST", "/_ctl", {"pa_answer": pa_answer("I'd increase the offer to £235,000 to get it done.", SRC, "coach")})
run = data(call("POST", PA + "/ask", SOPHIE, S, {"message": "Sarah won't move below £235k. What would you do?",
           "mode": "coach", "opportunity_uuid": SARAH}), 202, "coach me")
got = data(call("GET", PA + f"/ask/{run['uuid']}", SOPHIE, S), 200, "coach answer")
check("P06: a coach answer suggesting a higher offer is withheld (even though £235,000 is on record)",
      got["output"]["grounded"] is False and got["output"].get("answer") is None
      and any(v["kind"] == "higher_offer" for v in got["output"]["violations"])
      and "authority" in got["output"]["withheld"], got["output"])
mock("POST", "/_ctl", {"pa_answer": pa_answer("Before any figure: ask what matters more to Sarah, price or a quick "
                                              "completion, and what Tom thinks. Her stated minimum is £235,000.", SRC, "coach")})
run = data(call("POST", PA + "/ask", SOPHIE, S, {"message": "What would you do?", "mode": "coach",
           "opportunity_uuid": SARAH}), 202, "coach me again")
got = data(call("GET", PA + f"/ask/{run['uuid']}", SOPHIE, S), 200, "coach answer 2")
check("P06: a coach answer with questions (and a cited figure) is shown", got["output"]["grounded"] is True, got["output"])
launch = mock("GET", "/_js")["launches"] + mock("GET", "/_js")["task_runs"]
check("coach runs use the coach skill", launch[-1]["skill_slugs"] == ["pa-coach"], launch[-1])

sys.exit(finish())
