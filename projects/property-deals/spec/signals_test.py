"""Personal follow-ups, step 1: lead news (Companies House + captured posts) and hot-reply call alerts.

  * the Companies House watch turns a lead's company filings / charges and their new directorships / companies into
    "recent news", once each, only recent items; new property companies in an area become new leads
  * a person captures a post (never fetched by us); officer search links a lead to Companies House
  * a reply (logged WhatsApp, or an email matched to the lead by sender) is scored: rules without AI, the model
    with it, opt-outs always cold; a hot one raises one "call now" task and alerts the owner on app push / in-app,
    ntfy, Telegram and SMS (free / open-source connectors), as their preferences allow
  * other workspaces see none of it
"""
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, sql, workspace  # noqa: E402

MOCK = os.environ["PD_MOCK"]
M = "http://pd-mock:8080"


def mock(method, path, body=None):
    req = urllib.request.Request(MOCK + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"null")


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


OP = USERS["operator_s"][0]

mock("POST", "/_ctl", {"reset_all": True})
S = workspace("owner_s", "Signal Homes Ltd", "signal-homes")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_s", S), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_s", S), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
role_id = {r["role_name"]: r["id"] for r in roles}
for user, role in (("manager_s", "pd_manager"), ("operator_s", "pd_operator")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
           {"email": USERS[user][1], "role_ids": [role_id[role]]}), 201)
for kind, cfg, secret in (("companies_house", {"base_url": M + "/ch"}, "ch-key"),
                          ("ntfy", {"base_url": M + "/ntfy", "topic_prefix": "pd"}, None),
                          ("telegram", {"base_url": M + "/tg"}, "tg-token"),
                          ("sms_gateway", {"base_url": M + "/smsgw", "username": "gw"}, "gw-pass")):
    body = {"kind": kind, "name": kind, "config": cfg}
    if secret:
        body["secret"] = secret
    data(call("POST", P + "/connectors", "manager_s", S, body), 201, "connector " + kind)

lead = expect("a buyer lead", call("POST", API + "/api/v2/crm/leads", "operator_s", S, {
    "first_name": "Sarah", "last_name": "Lane", "email": "sarah@lane.test", "phone": "07700 900456",
    "company_name": "Acme Homes Ltd", "owner_user_uuid": OP}), 201)
lead = lead.get("data") or lead
L = lead["uuid"]
d = data(call("PUT", P + f"/leads/{L}/details", "operator_s", S, {"lead_kind": "buyer_investor",
         "company_number": "0123 4567", "ch_officer_id": "OFF123"}), 200, "link the lead to Companies House")
check("company number tidied", d["details"]["company_number"] == "01234567", d["details"])
res = call("PUT", P + f"/leads/{L}/details", "operator_s", S, {"lead_kind": "solicitor"})
check("solicitor is a lead kind now", res[0] == 200, res)

# --- Companies House watch ------------------------------------------------------------------------------------------
officers = data(call("GET", P + "/companies-house/officers?q=Jo%20Smith", "operator_s", S), 200, "officer search")
check("officer search returns the officer id", officers and officers[0]["officer_id"] == "OFF123", officers)
res = call("POST", P + "/signals/run", "operator_s", S)
check("only managers run the watch (403)", res[0] == 403, res)
run = data(call("POST", P + "/signals/run", "manager_s", S), 200, "run the watch")
check("one lead watched, four new items, no errors", run["watch"] == {"leads": 1, "signals": 4, "errors": 0}, run)
sig = data(call("GET", P + f"/leads/{L}/signals", "operator_s", S), 200, "lead news")
check("news newest first: charge, formed company, accounts, directorship",
      [s["kind"] for s in sig] == ["charge_registered", "company_formed", "company_filing", "officer_appointed"],
      [(s["kind"], s["occurred_at"]) for s in sig])
check("a new company reads like a person would say it", sig[1]["title"].startswith("Set up ELM PROPERTY HOLDINGS LTD on"),
      sig[1]["title"])
check("old filings and appointments are not news", not [s for s in sig if "2019" in s["occurred_at"] or "OLD CO" in s["title"]])
check("source + link kept", all(s["source"] == "companies_house" and s["url"].startswith("https://find-and-update") for s in sig))
again = data(call("POST", P + "/signals/run", "manager_s", S), 200, "run again at once")
check("a lead checked in the last 20h is skipped", again["watch"]["leads"] == 0, again)
sql(f"UPDATE property_deals_lead_details SET ch_checked_at = NULL WHERE lead_uuid = '{L}'")
again = data(call("POST", P + "/signals/run", "manager_s", S), 200, "run again later")
check("the same news is never stored twice", again["watch"] == {"leads": 1, "signals": 0, "errors": 0}, again)

# New property companies in an area -> new leads
expect("set the area", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S,
       {"settings": {"ch_new_company_areas": "Leeds"}}), 200)
run = data(call("POST", P + "/signals/run", "manager_s", S), 200, "run with an area")
check("one new property company found, one new lead", run["new_companies"] == {"areas": 1, "companies": 1, "leads": 1}, run)
new = data(call("GET", P + "/leads?source=companies_house", "operator_s", S), 200, "new-company leads")
check("lead named after the director, kind buyer, linked to the company",
      len(new) == 1 and new[0]["first_name"] == "Jo" and new[0]["last_name"] == "Smith"
      and new[0]["company_name"] == "ELM PROPERTY HOLDINGS LTD" and new[0]["details"]["lead_kind"] == "buyer_investor"
      and new[0]["details"]["company_number"] == "07654321" and new[0]["details"]["ch_officer_id"] == "OFF123", new)
run = data(call("POST", P + "/signals/run", "manager_s", S), 200, "run the area again")
check("the same company never becomes a second lead", run["new_companies"]["leads"] == 0, run)

# --- Captured posts -------------------------------------------------------------------------------------------------
post = data(call("POST", P + f"/leads/{L}/signals", "operator_s", S, {"kind": "social_post",
            "url": "https://www.linkedin.com/posts/sarah-lane_hmo", "text": "Just completed on our third HMO in Leeds!"}),
            201, "capture a post")
check("captured post is news, titled from its text", post["kind"] == "social_post" and post["source"] == "manual"
      and post["title"].startswith("Just completed"), post)
res = call("POST", P + f"/leads/{L}/signals", "operator_s", S, {"kind": "company_formed", "text": "x"})
check("people can't fake Companies House news (422)", res[0] == 422, res)
res = call("POST", P + f"/leads/{L}/signals", "operator_s", S, {"kind": "note"})
check("a capture needs text or a link (422)", res[0] == 422, res)
check("delete a capture", expect("delete", call("DELETE", P + f"/signals/{post['uuid']}", "operator_s", S), 200))

# --- Replies: rules without AI --------------------------------------------------------------------------------------
r = data(call("POST", P + f"/leads/{L}/replies", "operator_s", S, {"channel": "whatsapp",
         "text": "Thanks, not right now"}), 201, "log a lukewarm WhatsApp")
check("scored by rules without an AI provider, not hot, no task", r["scored_by"] == "rules" and r["reply_temperature"] != "hot"
      and not r.get("hot_task_uuid"), r)
r = data(call("POST", P + f"/leads/{L}/replies", "operator_s", S, {"channel": "sms",
         "text": "Please remove me from your list"}), 201, "log an opt-out")
check("an opt-out is cold and says why", r["reply_temperature"] == "cold" and "not to be contacted" in r["reply_reason"], r)
tom = expect("a second lead", call("POST", API + "/api/v2/crm/leads", "operator_s", S, {"first_name": "Tom",
             "last_name": "Rule", "owner_user_uuid": OP}), 201)
tom = (tom.get("data") or tom)["uuid"]
r = data(call("POST", P + f"/leads/{tom}/replies", "operator_s", S, {"channel": "whatsapp",
         "text": "Yes please, call me this afternoon - free after 2"}), 201, "a call request, no AI")
check("without AI, asking to be called is hot by the rules", r["scored_by"] == "rules" and r["reply_temperature"] == "hot"
      and r["reply_score"] >= 70 and "asks to talk now" in r["reply_reason"] and r.get("hot_task_uuid"), r)
data(call("PUT", P + f"/tasks/{r['hot_task_uuid']}", "operator_s", S, {"pd_status": "done"}), 200, "Tom called")
res = call("POST", P + f"/leads/{L}/replies", "operator_s", S, {"channel": "pigeon", "text": "hi"})
check("unknown channel refused (422)", res[0] == 422, res)

# --- Hot reply with AI: one task, alerts on every channel ------------------------------------------------------------
data(call("POST", API + "/api/v2/namespace/ai-providers", "owner_s", S, {"name": "Local", "provider_type": "openai_compatible",
     "base_url": M + "/v1", "default_model": "qwen-local", "is_local": True}), 201, "local model")
sql(f"UPDATE users SET phone_no = '07700 900111' WHERE uuid = '{OP}'")
prefs = data(call("PUT", P + "/notification-preferences", "operator_s", S, {"telegram_chat_id": "555"}), 200,
             "operator links Telegram")
check("hot_lead is on for every channel by default", prefs["hot_lead"] == {"push": True, "email": True, "ntfy": True,
      "telegram": True, "sms": True} and prefs["telegram_chat_id"] == "555", prefs)
res = call("PUT", P + "/notification-preferences", "operator_s", S, {"telegram_chat_id": "x y;"})
check("a bad chat id is refused (422)", res[0] == 422, res)
mock("POST", "/_ctl", {"reset_alerts": True})
hot = data(call("POST", P + f"/leads/{L}/replies", "operator_s", S, {"channel": "whatsapp",
           "text": "Yes please call me this afternoon, free after 2"}), 201, "log a hot WhatsApp")
check("the model reads it as hot (92)", hot["scored_by"] == "ai" and hot["reply_temperature"] == "hot"
      and hot["reply_score"] == 92 and hot["reply_reason"].startswith("AI:"), hot)
check("a call task was raised and one person alerted", hot.get("hot_task_uuid") and hot["alerted"] == 1, hot)
task = data(call("GET", P + f"/tasks/{hot['hot_task_uuid']}", "operator_s", S), 200, "the call task")
check("call task: for the owner, critical, on the lead, due in 15 minutes",
      task["owner_user_uuid"] == OP and task["priority"] == "critical" and task["lead_uuid"] == L
      and task["sla_minutes"] == 15 and task["title"] == "Call Sarah Lane now — they just replied", task)
check("the task has the number and the reply", "07700 900456" in task["description"] and "call me" in task["description"],
      task["description"])
alerts = mock("GET", "/_alerts")
by = {a["channel"]: a for a in alerts}
check("ntfy alert on the owner's topic, urgent", by.get("ntfy", {}).get("to") == "pd-" + OP.replace("-", "")[:12]
      and by["ntfy"]["priority"] == "urgent" and by["ntfy"]["title"] == "Hot lead: call Sarah now", by.get("ntfy"))
check("Telegram alert to the linked chat", by.get("telegram", {}).get("to") == "555"
      and "Sarah Lane" in by["telegram"]["text"], by.get("telegram"))
check("SMS from the gateway to the owner's mobile (E.164), with the lead's number",
      by.get("sms", {}).get("to") == "+447700900111" and "07700 900456" in by["sms"]["text"], by.get("sms"))
check("nobody else was alerted", len(alerts) == 3, alerts)
st, body = call("GET", API + "/api/v2/notifications?limit=50", "operator_s", S)
titles = [n.get("title") for n in (body.get("notifications") or [])]
check("in-app (and app push) for the owner", "Hot lead: call Sarah now" in titles, titles)

hot2 = data(call("POST", P + f"/leads/{L}/replies", "operator_s", S, {"channel": "phone",
            "text": "Missed you - call me back please"}), 201, "a second hot reply")
check("a second hot reply re-alerts on the same task", hot2["hot_task_uuid"] == hot["hot_task_uuid"], hot2)
n = sql(f"SELECT COUNT(*) FROM property_deals_task_details WHERE lead_uuid = '{L}' AND metadata ->> 'kind' = 'hot_lead_call'")
check("still one call task", n == ["1"], n)
hl = data(call("GET", P + "/hot-leads", "manager_s", S), 200, "hot leads")
check("hot leads: Sarah with her call task", len(hl) == 1 and hl[0]["lead_uuid"] == L
      and hl[0]["call_task_uuid"] == hot["hot_task_uuid"] and hl[0]["hot_score"] == 92, hl)
check("'mine' for the manager is empty", not data(call("GET", P + "/hot-leads?mine=true", "manager_s", S), 200, "mine"))
lead_now = data(call("GET", P + f"/leads/{L}", "operator_s", S), 200, "lead after replies")
check("lead shows hot, why and when", lead_now["details"]["temperature"] == "hot" and lead_now["details"]["last_reply_at"], lead_now)
check("filter leads by temperature", sorted(x["uuid"] for x in data(call("GET", P + "/leads?temperature=hot", "operator_s", S),
      200, "hot filter")) == sorted([L, tom]))

# Preferences are respected: Telegram off for hot leads -> no Telegram alert.
data(call("PUT", P + "/notification-preferences", "operator_s", S, {"hot_lead": {"telegram": False}}), 200, "telegram off")
mock("POST", "/_ctl", {"reset_alerts": True})
data(call("POST", P + f"/leads/{L}/replies", "operator_s", S, {"channel": "sms", "text": "Call me now please"}), 201, "hot again")
check("Telegram muted, ntfy + SMS still sent", sorted(a["channel"] for a in mock("GET", "/_alerts")) == ["ntfy", "sms"],
      mock("GET", "/_alerts"))

data(call("PUT", P + f"/tasks/{hot['hot_task_uuid']}", "operator_s", S, {"pd_status": "done"}), 200, "called: task done")
check("once called, the lead leaves 'call now'", not data(call("GET", P + "/hot-leads", "manager_s", S), 200, "hot after call"))

# --- Email reply matched to the lead by sender ----------------------------------------------------------------------
imap = data(call("POST", P + "/mail-connectors", "manager_s", S, {"name": "Inbox", "kind": "imap", "secret": "imap-pass",
            "config": {"host": "pd-mock", "port": 1143, "ssl": False, "username": "deals@signal.test"}}), 201, "IMAP")
mock("POST", "/_mail/inbox", {"from": "Sarah Lane <sarah@lane.test>", "subject": "Re: your message",
                               "body": "Could you call me tomorrow morning?"})
data(call("POST", P + f"/mail-connectors/{imap['uuid']}/sync", "manager_s", S), 200, "sync the inbox")
emails = [x for x in data(call("GET", P + f"/leads/{L}/replies", "operator_s", S), 200, "replies") if x["channel"] == "email"]
check("the email is on the lead, matched by sender and scored hot", len(emails) == 1 and emails[0]["matched_by"] == "lead"
      and emails[0]["reply_temperature"] == "hot", emails)

# --- Isolation ------------------------------------------------------------------------------------------------------
B = workspace("owner_b", "Other Signals Co", "other-signals")
expect("enable the plugin (B)", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_b", B, {"enabled": True}), 200)
for method, path, body in (("GET", f"/leads/{L}/signals", None), ("POST", f"/leads/{L}/signals", {"kind": "note", "text": "x"}),
                           ("GET", f"/leads/{L}/replies", None),
                           ("POST", f"/leads/{L}/replies", {"channel": "sms", "text": "call me"})):
    res = call(method, P + path, "owner_b", B, body)
    check(f"other workspace: {method} {path.split('/')[-1]} is 404", res[0] == 404, res)
check("other workspace has no hot leads", not data(call("GET", P + "/hot-leads", "owner_b", B), 200, "B hot"))

sys.exit(finish())
