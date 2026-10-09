"""SPEC §5 scenario — the rules part (Phase 3): workflow engine, SLA, health, digest, gates.

"Demo Buyers Ltd" uses the UK template. A deal is at Searches, target completion in 9 working
days, late penalty £500/day capped at 20 days, the EPC task not started, and the seller's
solicitor last replied 50 hours ago with 2 open enquiries. Expected:
  1. EPC booking task with a 60-minute SLA: owner warned at 45 min; manager told + overdue at 60.
  2. If a valid EPC is found (register check), the booking task closes itself with evidence.
  3. Deal health is red; money at risk is shown with the reason.
  4. The owner's daily digest lists the deal at the top.
  7. Exchange is blocked while buyer AML is incomplete, with a clear reason.
  8. A user from another workspace sees none of it.
(5 and 6, the AI chaser and JobShout, are Phase 5.) Time passes by moving the task's clock in SQL.
"""
import datetime
import json
import os
import sys
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, sql, workspace, finish  # noqa: E402

S = workspace("owner_s", "Demo Buyers Ltd", "demo-buyers")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S,
                                 {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_s", S), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_s", S), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
role_id = {r["role_name"]: r["id"] for r in roles}
for user, role in (("manager_s", "pd_manager"), ("operator_s", "pd_operator")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
           {"email": USERS[user][1], "role_ids": [role_id[role]]}), 201)

# Working days, the same way the server counts them.
hol = expect("holidays", call("GET", P + "/holidays?per_page=100", "owner_s", S), 200)["data"]
holidays = {h["holiday_date"][:10] for h in hol}
today = datetime.datetime.now(ZoneInfo("Europe/London")).date()


def add_wd(d, n):
    step = 1 if n > 0 else -1
    while n:
        d += datetime.timedelta(days=step)
        if d.weekday() < 5 and d.isoformat() not in holidays:
            n -= step
    return d


target = add_wd(today, 9)
target_exchange = add_wd(today, 7)

# --- The deal --------------------------------------------------------------------
prop = expect("property without an EPC", call("POST", P + "/properties", "operator_s", S,
              {"address_line1": "7 Mill Lane", "town": "York", "postcode": "YO1 7AA", "tenure": "freehold",
               "lat": 53.96, "lng": -1.08}), 201)["data"]
lead = expect("seller lead", call("POST", API + "/api/v2/crm/leads", "operator_s", S,
              {"first_name": "Pat", "last_name": "Probate", "source": "website_form"}), 201)
lead = lead.get("data") or lead
deal = expect("deal (operator owns it)", call("POST", P + "/deals", "operator_s", S,
              {"lead_uuid": lead["uuid"], "property_uuid": prop["uuid"], "deal_type": "buy",
               "offer_amount": 140000, "target_completion_date": target.isoformat(),
               "late_penalty_per_day": 500, "late_penalty_cap_days": 20}), 201)["data"]
D = deal["uuid"]

tasks = expect("first-stage tasks", call("GET", P + f"/tasks?deal_uuid={D}&per_page=100", "operator_s", S), 200)["data"]
by_key = {t["template_key"]: t for t in tasks}
check("engine created the New-lead tasks", set(by_key) >= {"call_back", "log_situation"}, list(by_key))
check("call back: 60-minute SLA, owned by the deal owner",
      by_key["call_back"]["sla_minutes"] == 60 and by_key["call_back"]["owner_user_uuid"] == USERS["operator_s"][0],
      by_key["call_back"])
check("log situation waits for the call back (no clock yet)",
      by_key["log_situation"].get("due_at") is None and by_key["log_situation"]["metadata"]["waiting_on"] == ["call_back"],
      by_key["log_situation"])
expect("finish the call back", call("PUT", P + f"/tasks/{by_key['call_back']['task_uuid']}", "operator_s", S,
       {"pd_status": "done"}), 200)
ls = expect("log situation", call("GET", P + f"/tasks/{by_key['log_situation']['task_uuid']}", "operator_s", S), 200)["data"]
check("dependency done -> its clock starts (due in 4h)", ls.get("due_at") is not None and ls["sla_minutes"] == 240, ls)

res = call("POST", P + f"/deals/{D}/stage", "operator_s", S, {"to": "nowhere"})
check("unknown stage refused (422)", res[0] == 422, res)
moved = expect("move to Searches", call("POST", P + f"/deals/{D}/stage", "operator_s", S, {"to": "searches"}), 200)["data"]
created = {t["template_key"] for t in moved["tasks_created"]}
check("Searches starts its parallel stages too (EPC, survey)",
      created >= {"order_searches", "epc_register_check", "book_epc", "book_survey"} and "request_lease_pack" not in created,
      sorted(created))
check("deal is at Searches", moved["deal"]["stage_key"] == "searches", moved["deal"]["stage_key"])

tasks = expect("deal tasks", call("GET", P + f"/tasks?deal_uuid={D}&per_page=100", "operator_s", S), 200)["data"]
by_key = {t["template_key"]: t for t in tasks}
epc = by_key["book_epc"]
check("1. EPC booking task has a 60-minute SLA", epc["sla_minutes"] == 60 and epc["pd_status"] == "todo", epc)

# Seller's solicitor: 2 open enquiries, last reply 50 hours ago.
for title in ("Missing FENSA certificate", "Boundary dispute details"):
    expect("open enquiry", call("POST", P + "/enquiries", "operator_s", S,
           {"deal_uuid": D, "title": title, "owner_party": "seller_solicitor", "blocking": True}), 201)
now = datetime.datetime.now(datetime.timezone.utc)
iso = lambda dt: dt.strftime("%Y-%m-%dT%H:%M:%SZ")
expect("chase log: replied 50h ago", call("POST", P + "/chases", "operator_s", S,
       {"deal_uuid": D, "channel": "email", "to_party": "seller_solicitor", "subject": "Enquiries",
        "status": "replied", "sent_at": iso(now - datetime.timedelta(hours=60)),
        "reply_at": iso(now - datetime.timedelta(hours=50))}), 201)


def run(*checks):
    return expect("run engine " + "+".join(checks), call("POST", P + "/engine/run", "manager_s", S,
                  {"checks": list(checks)}), 200)["data"]


def notes(user):
    st, body = call("GET", API + "/api/v2/notifications?limit=100", user, S)
    return [n for n in (body.get("notifications") or []) if str(n.get("type", "")).startswith("property_deals.")]


def clock(task_uuid, started_min_ago, due_min_from_now):
    sql(f"UPDATE property_deals_task_details SET sla_started_at = NOW() - interval '{started_min_ago} minutes', "
        f"due_at = NOW() + interval '{due_min_from_now} minutes' WHERE task_uuid = '{task_uuid}'")


# 45 minutes in: 75% -> the owner is warned.
clock(epc["task_uuid"], 46, 14)
out = run("sla")
t = expect("EPC task", call("GET", P + f"/tasks/{epc['task_uuid']}", "operator_s", S), 200)["data"]
check("1. at 45 min (75%) the task is flagged and the owner warned",
      t.get("sla_warned_at") and not t.get("sla_breached_at") and out["sla"]["warned"] >= 1, (t, out))
check("1. owner got a 'Due soon' notification",
      any(n["title"] == "Due soon" and "Book an EPC assessor" in n["message"] for n in notes("operator_s")),
      notes("operator_s"))
check("1. manager not bothered yet", not any(n["title"] == "Overdue" for n in notes("manager_s")))

# 60 minutes: 100% -> overdue, manager told.
clock(epc["task_uuid"], 61, -1)
out = run("sla")
t = expect("EPC task", call("GET", P + f"/tasks/{epc['task_uuid']}", "operator_s", S), 200)["data"]
check("1. at 60 min the task is overdue (escalation level 2)", t.get("sla_breached_at") and t["escalation_level"] == 2, t)
check("1. manager got the 'Overdue' notification",
      any(n["title"] == "Overdue" and "Book an EPC assessor" in n["message"] for n in notes("manager_s")))
check("1. owner told too", any(n["title"] == "Overdue" for n in notes("operator_s")))
out2 = run("sla")
check("SLA steps happen once (second tick sends nothing new)", out2["sla"]["overdue"] == 0 and out2["sla"]["warned"] == 0, out2)

# --- 3. Health and money at risk -----------------------------------------------------------
h = expect("deal health", call("GET", P + f"/deals/{D}/health", "operator_s", S), 200)["data"]
reasons = " | ".join(h["reasons"])
check("3. deal health is red", h["health"] == "red", h)
check("3. reasons: overdue blocking task + few working days with open blockers",
      "blocking task(s) overdue" in reasons and "9 working day(s) to completion with 2 open blocker(s)" in reasons, reasons)
f = h["facts"]
check("3. 2 open enquiries, ~50h of silence", f["open_blocking_enquiries"] == 2 and 49 <= f["hours_since_third_party_reply"] <= 51, f)
expected_money = 500 * min(f["days_late"], 20)
check("3. money at risk = £500 × days late (cap 20)", f["days_late"] > 0 and float(h["money_at_risk"]) == expected_money,
      (h["money_at_risk"], f))
check("3. money at risk explained", "at risk:" in reasons and "£500" in reasons, reasons)
check("3. completion forecast after the target", h["predicted_completion_date"] > h["target_completion_date"], h)
t = expect("EPC task urgency", call("GET", P + f"/tasks/{epc['task_uuid']}", "operator_s", S), 200)["data"]
factors = {p["factor"]: p for p in t["urgency_why"]}
check("urgency score with a 'why' per factor", float(t["urgency_score"]) > 50 and factors["time"]["points"] > 0
      and factors["blocking"]["points"] == 15 and factors["money"]["points"] > 0, (t["urgency_score"], t["urgency_why"]))
mine = expect("my tasks by urgency", call("GET", P + f"/tasks?owner_user_uuid={USERS['operator_s'][0]}&open=true", "operator_s", S), 200)["data"]
check("the overdue EPC task tops my list", mine and mine[0]["task_uuid"] == epc["task_uuid"], [m["title"] for m in mine[:3]])

# --- 4. Daily digest ------------------------------------------------------------------------
dg = expect("digest", call("GET", P + "/digest", "operator_s", S), 200)["data"]
check("4. digest lists the deal at the top of deals at risk",
      dg["deals_at_risk"] and dg["deals_at_risk"][0]["uuid"] == D and dg["deals_at_risk"][0]["health"] == "red", dg["deals_at_risk"][:1])
check("4. digest lists the overdue EPC task", any(x["task_uuid"] == epc["task_uuid"] for x in dg["overdue"]), dg["overdue"])
sent = run("digest")
check("4. digest sent once per person per day", sent["digest"]["sent"] >= 1, sent)
again = run("digest")
check("4. second run sends nothing", again["digest"]["sent"] == 0, again)
check("4. owner got 'Your day' in-app", any(n["title"] == "Your day" for n in notes("operator_s")))

# --- 125%: reassign to a manager ---------------------------------------------------------------
clock(epc["task_uuid"], 80, -20)
out = run("sla")
t = expect("EPC task", call("GET", P + f"/tasks/{epc['task_uuid']}", "operator_s", S), 200)["data"]
check("125%: reassigned to the manager", t["owner_user_uuid"] == USERS["manager_s"][0] and t["escalation_level"] == 3, t)
check("manager got 'Escalated to you'", any(n["title"] == "Escalated to you" for n in notes("manager_s")))

# --- 7. Exchange gate ------------------------------------------------------------------------------
res = call("POST", P + f"/deals/{D}/stage", "operator_s", S, {"to": "exchange"})
missing = (res[1].get("details") or {}).get("missing", []) if isinstance(res[1], dict) else []
keys = {m["key"] for m in missing}
check("7. Exchange blocked (409)", res[0] == 409, res)
check("7. reason names buyer AML", "aml_cdd_buyer" in keys and "AML customer due diligence — buyer" in res[1]["error"], res[1])
check("7. and the other missing items (tasks, documents, fields, enquiries)",
      {"order_searches", "buyer_aml", "title", "searches", "agreed_price", "open_blocking"} <= keys, sorted(keys))
expect("start buyer AML", call("POST", P + "/compliance-checks", "operator_s", S,
       {"check_type": "aml_cdd_buyer", "subject_type": "deal", "deal_uuid": D, "party_role": "buyer", "status": "in_progress"}), 201)
g = expect("gate preview", call("GET", P + f"/deals/{D}/gate?to=exchange", "operator_s", S), 200)["data"]
msg = next(m["message"] for m in g["missing"] if m["key"] == "aml_cdd_buyer")
check("7. gate says the AML check is in progress", g["ok"] is False and msg.endswith("is not passed (in progress)"), msg)
check("deal still at Searches", expect("deal", call("GET", P + f"/deals/{D}", "operator_s", S), 200)["data"]["stage_key"] == "searches")

# --- 2. Valid EPC found -> booking task closes itself ------------------------------------------------
prop2 = expect("second property", call("POST", P + "/properties", "operator_s", S,
               {"address_line1": "9 Mill Lane", "tenure": "freehold"}), 201)["data"]
d2 = expect("second deal", call("POST", P + "/deals", "operator_s", S, {"property_uuid": prop2["uuid"],
            "target_completion_date": target.isoformat(), "target_exchange_date": target_exchange.isoformat()}), 201)["data"]
expect("second deal to Searches", call("POST", P + f"/deals/{d2['uuid']}/stage", "operator_s", S, {"to": "searches"}), 200)
t2 = {t["template_key"]: t for t in expect("tasks", call("GET", P + f"/tasks?deal_uuid={d2['uuid']}&per_page=100", "operator_s", S), 200)["data"]}
expires = (today + datetime.timedelta(days=3000)).isoformat()
expect("register check finds a valid EPC", call("PUT", P + f"/tasks/{t2['epc_register_check']['task_uuid']}", "operator_s", S,
       {"pd_status": "done", "evidence": {"epc_valid": True, "certificate_number": "1234-5678-9012-3456-7890",
                                         "expires_on": expires, "rating": "C", "source": "register"}}), 200)
b = expect("booking task", call("GET", P + f"/tasks/{t2['book_epc']['task_uuid']}", "operator_s", S), 200)["data"]
check("2. booking task closed itself", b["pd_status"] == "done", b)
check("2. with the certificate as evidence", b["evidence"].get("auto") and b["evidence"].get("epc_certificate_number") == "1234-5678-9012-3456-7890", b["evidence"])
p2 = expect("property", call("GET", P + f"/properties/{prop2['uuid']}", "operator_s", S), 200)["data"]
check("2. property now holds the EPC", p2["epc_rating"] == "C" and p2["epc_expires_on"][:10] == expires, p2)

# Target-relative deadline in working days (bank holidays skipped).
expect("second deal to Enquiries", call("POST", P + f"/deals/{d2['uuid']}/stage", "operator_s", S, {"to": "enquiries"}), 200)
t2 = {t["template_key"]: t for t in expect("tasks", call("GET", P + f"/tasks?deal_uuid={d2['uuid']}&per_page=100", "operator_s", S), 200)["data"]}
want = add_wd(target_exchange, -5)
got = sql(f"SELECT (due_at AT TIME ZONE 'Europe/London')::text FROM property_deals_task_details WHERE task_uuid = '{t2['buyer_funds']['task_uuid']}'")
check("buyer funds due 5 working days before target exchange, 17:00 local",
      got and got[0].startswith(want.isoformat() + " 17:00"), (got, want.isoformat()))
expect("move target exchange", call("PUT", P + f"/deals/{d2['uuid']}", "operator_s", S,
       {"target_exchange_date": add_wd(target_exchange, 5).isoformat()}), 200)
got2 = sql(f"SELECT (due_at AT TIME ZONE 'Europe/London')::date::text FROM property_deals_task_details WHERE task_uuid = '{t2['buyer_funds']['task_uuid']}'")
check("changing the target re-times the task", got2 and got2[0] == add_wd(add_wd(target_exchange, 5), -5).isoformat(), got2)

# Templates: a stage that applies only to leaseholds is skipped for a freehold.
g = expect("next stage gate", call("GET", P + f"/deals/{d2['uuid']}/gate", "operator_s", S), 200)["data"]
check("advance skips parallel/optional stages (next is exchange)", g["stage"] == "exchange", g)

# --- Compliance expiry ---------------------------------------------------------------------------
c = expect("passed check", call("POST", P + "/compliance-checks", "owner_s", S,
           {"check_type": "aml_cdd_seller", "subject_type": "deal", "deal_uuid": D, "status": "passed"}), 201)["data"]
sql(f"UPDATE property_deals_compliance_checks SET expires_at = NOW() - interval '1 day' WHERE uuid = '{c['uuid']}'")
out = run("compliance_expiry")
c2 = expect("check after expiry", call("GET", P + f"/compliance-checks/{c['uuid']}", "owner_s", S), 200)["data"]
check("expired check re-opens (status expired)", c2["status"] == "expired" and out["compliance_expiry"]["expired"] >= 1, c2)

# --- Events offered to webhooks; native iOS push tokens ---------------------------------------------
ev = expect("webhook events", call("GET", API + "/api/v2/namespace/webhooks/events", "owner_s", S), 200)
names = json.dumps(ev)
check("webhook catalogue offers engine events",
      all(e in names for e in ("property_deals.deal.stage_changed", "property_deals.deal.health_changed",
                               "property_deals.task.overdue", "property_deals.task.escalated",
                               "property_deals.compliance_check.expiring")), None)
tok = "ab" * 32
res = call("POST", API + "/api/v2/device-tokens", "operator_s", None,
           {"token": tok, "token_type": "apns", "apns_environment": "development", "bundle_id": "uk.co.workstation.wslcrm",
            "device_name": "iPhone"})
check("iOS app can register a raw APNs token (201)", res[0] == 201 and res[1]["data"]["token_type"] == "apns", res)
res = call("POST", API + "/api/v2/device-tokens", "operator_s", None, {"token": "not-hex", "token_type": "apns"})
check("bad APNs token refused (400)", res[0] == 400, res)

# --- 8. Another workspace sees none of it -------------------------------------------------------------
B = sql("SELECT uuid FROM namespaces WHERE slug = 'other-co'")[0]
for method, path in (("GET", f"/deals/{D}"), ("GET", f"/deals/{D}/health"), ("GET", f"/deals/{D}/gate?to=exchange"),
                     ("POST", f"/deals/{D}/stage"), ("GET", f"/tasks/{epc['task_uuid']}")):
    res = call(method, P + path, "owner_b", B, {"to": "exchange"} if method == "POST" else None)
    check(f"8. other workspace: {method} {path.split('?')[0]} -> 404", res[0] == 404, res)
dg_b = expect("other workspace digest", call("GET", P + "/digest", "owner_b", B), 200)["data"]
check("8. other workspace's digest doesn't show the deal", D not in json.dumps(dg_b), None)
check("8. other workspace's owner got no notifications about it", not any(D in json.dumps(n) for n in notes("owner_b")))
res = call("POST", P + "/engine/run", "operator_s", S, {"checks": ["sla"]})
check("operators can't run the engine by hand (403)", res[0] == 403, res)

sys.exit(finish())
