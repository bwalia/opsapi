"""Personal follow-ups, step 1: lead news (Companies House + captured posts) and hot-reply call alerts.

  * the Companies House watch turns a lead's company filings / charges and their new directorships / companies into
    "recent news", once each, only recent items; new property companies in an area become new leads
  * a person captures a post (never fetched by us); officer search links a lead to Companies House
  * a reply (logged WhatsApp, or an email matched to the lead by sender) is scored: rules without AI, the model
    with it, opt-outs always cold; a hot one raises one "call now" task and alerts the owner on app push / in-app,
    ntfy, Telegram and SMS (free / open-source connectors), as their preferences allow
  * a lead owner who left the workspace hears nothing more: the managers are alerted, the task waits unassigned
  * ntfy only reaches people who set their own (random) topic, and never carries names, numbers or text
  * an emailed "unsubscribe" opts out only a verified sender (DMARC pass); otherwise a person confirms it
  * the PA can't log the user's call as the lead's reply, and closes a lead's task only with the chase that did it
  * Companies House errors are counted and recorded, its rate limit stops the run; a failing area doesn't stop others
  * mail sync: a busy inbox catches up over runs (Gmail / Graph paging, oldest first), a message that can't be stored
    is skipped and kept as an error row, other charsets and long names are stored, one broken mailbox doesn't stop
    the others, provider text never reaches the answer
  * other workspaces see none of it
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

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


def as_pa(method, url, user, ns, body=None):
    """A call the page assistant makes for the user (it sends X-OpsAPI-Agent)."""
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + jwt(user), "Content-Type": "application/json",
                                          "X-Namespace-Id": ns, "X-OpsAPI-Agent": "1"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


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
check("one lead watched, four new items, no errors", run["watch"] == {"leads": 1, "signals": 4, "errors": 0, "followups": 0}, run)
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
check("the same news is never stored twice", again["watch"] == {"leads": 1, "signals": 0, "errors": 0, "followups": 0}, again)
NSID = sql(f"SELECT id FROM namespaces WHERE uuid = '{S}'")[0]
ch_error = f"SELECT COALESCE(last_error, '') FROM property_deals_connectors WHERE namespace_id = {NSID} AND kind = 'companies_house'"
mock("POST", "/_ctl", {"ch_429": True})
sql(f"UPDATE property_deals_lead_details SET ch_checked_at = NULL WHERE lead_uuid = '{L}'")
limited = data(call("POST", P + "/signals/run", "manager_s", S), 200, "run while Companies House rate-limits us")
check("rate limit: the run stops, counts it, and the lead stays due for the next run",
      limited["watch"].get("rate_limited") is True and limited["watch"]["errors"] == 1
      and sql(f"SELECT ch_checked_at IS NULL FROM property_deals_lead_details WHERE lead_uuid = '{L}'") == ["t"], limited)
check("...and the connector's last_error says so", "rate limit" in sql(ch_error)[0], sql(ch_error))
res = call("GET", P + "/companies-house/officers?q=Jo%20Smith", "operator_s", S)
check("officer search while limited: 429, without Companies House's own text", res[0] == 429
      and "Rate limit exceeded" not in json.dumps(res[1]), res)
mock("POST", "/_ctl", {"ch_429": False})
again = data(call("POST", P + "/signals/run", "manager_s", S), 200, "run once the limit has passed")
check("a clean run checks the lead and clears last_error", again["watch"]["errors"] == 0 and again["watch"]["leads"] == 1
      and sql(ch_error) in ([], [""]), [again, sql(ch_error)])

# New property companies in an area -> new leads
expect("set the areas (one of them fails at Companies House)", call("PUT", API + "/api/v2/namespace/plugins/property_deals",
       "owner_s", S, {"settings": {"ch_new_company_areas": "Nowhere, Leeds"}}), 200)
run = data(call("POST", P + "/signals/run", "manager_s", S), 200, "run with areas")
check("the failing area is counted and the next one still runs: one new company, one new lead",
      run["new_companies"] == {"areas": 2, "companies": 1, "leads": 1, "errors": 1}, run)
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
prefs = data(call("PUT", P + "/notification-preferences", "operator_s", S, {"telegram_chat_id": "555",
             "ntfy_topic": "generate"}), 200, "operator links Telegram and makes a private ntfy topic")
check("hot_lead is on for every channel by default", prefs["hot_lead"] == {"push": True, "email": True, "ntfy": True,
      "telegram": True, "sms": True} and prefs["telegram_chat_id"] == "555", prefs)
TOPIC = prefs.get("ntfy_topic") or ""
check("the generated ntfy topic has 128 random bits", re.match(r"^opsapi-[0-9a-f]{32}$", TOPIC) is not None, TOPIC)
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
check("the task has the number but not the reply's text (that stays on the lead)", "07700 900456" in task["description"]
      and "call me" not in task["description"], task["description"])
alerts = mock("GET", "/_alerts")
by = {a["channel"]: a for a in alerts}
check("ntfy alert on the owner's own topic, urgent, saying only 'open OpsAPI'", by.get("ntfy", {}).get("to") == TOPIC
      and by["ntfy"]["priority"] == "urgent" and "OpsAPI" in by["ntfy"]["text"]
      and not re.search(r"Sarah|Lane|07700|call me", json.dumps(by["ntfy"])), by.get("ntfy"))
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

# --- A lead owner who left the workspace hears nothing more ----------------------------------------------------------
EX = USERS["reader"][0]
expect("add a second operator", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
       {"email": USERS["reader"][1], "role_ids": [role_id["pd_operator"]]}), 201)
data(call("PUT", P + "/notification-preferences", "reader", S, {"telegram_chat_id": "777"}), 200, "they link Telegram")
sql(f"UPDATE users SET phone_no = '07700 900777' WHERE uuid = '{EX}'")
gone = expect("a lead they own", call("POST", API + "/api/v2/crm/leads", "operator_s", S, {"first_name": "Gail",
              "last_name": "Gone", "phone": "07700 900888", "owner_user_uuid": EX}), 201)
gone = (gone.get("data") or gone)["uuid"]
sql(f"DELETE FROM namespace_members WHERE namespace_id = {NSID} AND user_id = (SELECT id FROM users WHERE uuid = '{EX}')")
mock("POST", "/_ctl", {"reset_alerts": True})
r = data(call("POST", P + f"/leads/{gone}/replies", "operator_s", S, {"channel": "whatsapp",
         "text": "Yes please call me now"}), 201, "a hot reply on the ex-member's lead")
call_task = data(call("GET", P + f"/tasks/{r.get('hot_task_uuid')}", "manager_s", S), 200, "its call task")
check("the call task waits unassigned", r.get("hot_task_uuid") and not call_task.get("owner_user_uuid"), call_task)
check("nothing reached the ex-member (Telegram, SMS)", not [a for a in mock("GET", "/_alerts")
      if a["to"] in ("777", "+447700900777")], mock("GET", "/_alerts"))
st, body = call("GET", API + "/api/v2/notifications?limit=50", "manager_s", S)
check("the managers were alerted instead", "Hot lead: call Gail now" in [n.get("title") for n in (body.get("notifications") or [])],
      body)
check("logged once", sql(f"SELECT COUNT(*) FROM property_deals_inbound_messages WHERE lead_uuid = '{gone}'") == ["1"])

# --- The PA: a call the user made is a chase, and it closes only the task that call did --------------------------------
res = as_pa("POST", P + f"/leads/{tom}/replies", "operator_s", S, {"channel": "phone", "text": "I just spoke to Tom"})
check("the PA can't log the user's call as Tom's reply (422)", res[0] == 422 and "chase" in json.dumps(res[1]), res)
res = as_pa("POST", P + f"/leads/{tom}/replies", "operator_s", S, {"channel": "whatsapp", "text": "Maybe next month"})
check("...but it can log a message Tom wrote", res[0] == 201, res)
t1 = data(call("POST", P + "/tasks", "operator_s", S, {"title": "Call Tom back", "lead_uuid": tom, "owner_user_uuid": OP}),
          201, "task: call Tom back")["task_uuid"]
t2 = data(call("POST", P + "/tasks", "operator_s", S, {"title": "Send Tom our criteria", "lead_uuid": tom,
          "owner_user_uuid": OP}), 201, "task: send Tom our criteria")["task_uuid"]
res = as_pa("PUT", P + f"/tasks/{t1}", "operator_s", S, {"pd_status": "done"})
check("the PA can't close a lead's task without the chase that did it (422)", res[0] == 422, res)
chase = as_pa("POST", P + "/chases", "operator_s", S, {"lead_uuid": tom, "channel": "phone", "to_party": "seller",
              "outcome": "spoke", "status": "sent", "body": "Spoke to Tom"})
check("the PA logs the call as a chase", chase[0] == 201, chase)
CH = (chase[1].get("data") or {}).get("uuid")
res = as_pa("PUT", P + f"/tasks/{t1}", "operator_s", S, {"pd_status": "done", "evidence": {"chase_uuid": CH}})
check("...and closes the task that call did", res[0] == 200 and res[1]["data"]["pd_status"] == "done", res)
res = as_pa("PUT", P + f"/tasks/{t2}", "operator_s", S, {"pd_status": "done", "evidence": {"chase_uuid": CH}})
check("one call closes one task: 'send Tom our criteria' stays open (422)", res[0] == 422
      and data(call("GET", P + f"/tasks/{t2}", "operator_s", S), 200, "t2")["pd_status"] == "todo", res)
data(call("PUT", P + f"/tasks/{t2}", "operator_s", S, {"pd_status": "done"}), 200, "a person closes it themselves")

# --- Email reply matched to the lead by sender ----------------------------------------------------------------------
imap = data(call("POST", P + "/mail-connectors", "manager_s", S, {"name": "Inbox", "kind": "imap", "secret": "imap-pass",
            "config": {"host": "pd-mock", "port": 1143, "ssl": False, "username": "deals@signal.test"}}), 201, "IMAP")
mock("POST", "/_mail/inbox", {"from": "Sarah Lane <sarah@lane.test>", "subject": "Re: your message",
                               "body": "Could you call me tomorrow morning?"})
data(call("POST", P + f"/mail-connectors/{imap['uuid']}/sync", "manager_s", S), 200, "sync the inbox")
emails = [x for x in data(call("GET", P + f"/leads/{L}/replies", "operator_s", S), 200, "replies") if x["channel"] == "email"]
check("the email is on the lead, matched by sender and scored hot", len(emails) == 1 and emails[0]["matched_by"] == "lead"
      and emails[0]["reply_temperature"] == "hot", emails)

# --- An emailed "unsubscribe" opts out only a verified sender -----------------------------------------------------
una = expect("a lead with an email", call("POST", API + "/api/v2/crm/leads", "operator_s", S, {"first_name": "Una",
             "last_name": "Spoof", "email": "una@spoof.test", "owner_user_uuid": OP}), 201)
una = (una.get("data") or una)["uuid"]
opted = f"SELECT opted_out_at IS NOT NULL FROM property_deals_lead_details WHERE lead_uuid = '{una}'"
mock("POST", "/_mail/inbox", {"from": "Una Spoof <una@spoof.test>", "subject": "stop", "body": "Please unsubscribe me"})
data(call("POST", P + f"/mail-connectors/{imap['uuid']}/sync", "manager_s", S), 200, "sync an unverified unsubscribe")
check("an unverified sender doesn't opt the lead out", sql(opted) in ([], ["f"]), sql(opted))
check("...a person is asked to confirm instead", sql(f"SELECT COUNT(*) FROM property_deals_task_details WHERE lead_uuid = '{una}' "
      "AND metadata ->> 'kind' = 'opt_out_check'") == ["1"])
mock("POST", "/_mail/inbox", {"from": "Una Spoof <una@spoof.test>", "subject": "stop", "body": "Please unsubscribe me",
                               "auth": "dmarc=pass (p=none) header.from=spoof.test"})
data(call("POST", P + f"/mail-connectors/{imap['uuid']}/sync", "manager_s", S), 200, "sync a verified unsubscribe")
check("a verified sender is opted out at once", sql(opted) == ["t"], sql(opted))

# --- Mail sync hardening ------------------------------------------------------------------------------------------
MC = P + "/mail-connectors"
res = call("POST", MC, "manager_s", S, {"name": "x", "kind": "imap", "secret": "p\r\nA2 LOGOUT",
                                         "config": {"host": "pd-mock", "username": "u\r\nA1 x"}})
check("IMAP credentials with line breaks are refused (422)", res[0] == 422 and "secret" in res[1]["details"]
      and "config.username" in res[1]["details"], res)
inbound = f"SELECT COUNT(*) FROM property_deals_inbound_messages WHERE namespace_id = {NSID} AND external_id LIKE "
sql("CREATE OR REPLACE FUNCTION pd_test_poison() RETURNS trigger AS $$ BEGIN IF NEW.body_text LIKE '%POISON%' THEN "
    "RAISE EXCEPTION 'poisoned'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql")
sql("CREATE TRIGGER pd_test_poison BEFORE INSERT ON property_deals_inbound_messages FOR EACH ROW EXECUTE FUNCTION pd_test_poison()")
try:
    mock("POST", "/_mail/inbox", {"from": "Bad Mail <bad@mail.test>", "subject": "broken", "body": "POISON pill"})
    mock("POST", "/_mail/inbox", {"from": ("Z" * 300) + " <long@names.test>", "subject": "Caf\u00e9",
                                   "body": "Le caf\u00e9 est ferm\u00e9", "charset": "iso-8859-1"})
    r = data(call("POST", MC + f"/{imap['uuid']}/sync", "manager_s", S), 200, "sync past a message that can't be stored")
    check("the bad message is skipped and counted, the next one is stored", r.get("failed") == 1 and r.get("stored") == 1
          and "could not be stored" in (r.get("error") or ""), r)
    check("the bad message is kept as an error row (not lost)", sql(f"SELECT matched_by || '|' || from_address FROM "
          f"property_deals_inbound_messages WHERE namespace_id = {NSID} AND subject = 'broken' AND external_id LIKE 'imap:%'")
          == ["error|bad@mail.test"])
    got = sql(f"SELECT body_text || '|' || length(from_name) FROM property_deals_inbound_messages WHERE namespace_id = {NSID} "
              "AND external_id LIKE 'imap:%' AND from_address = 'long@names.test'")
    check("a Latin-1 body is stored as UTF-8 and a 300-character name is cut to fit", got == ["Le café est fermé|255"], got)
    r = data(call("POST", MC + f"/{imap['uuid']}/sync", "manager_s", S), 200, "sync again")
    check("the bad message never comes back; last_error is cleared", r.get("fetched") == 0
          and not data(call("GET", MC + f"/{imap['uuid']}", "manager_s", S), 200, "imap").get("last_error"), r)
finally:
    sql("DROP TRIGGER pd_test_poison ON property_deals_inbound_messages")
gmail = data(call("POST", MC, "manager_s", S, {"name": "Gmail", "kind": "gmail", "secret": {"client_secret": "secret-ok",
             "refresh_token": "rt"}, "config": {"client_id": "cid", "token_url": M + "/gmail/token", "api_base": M + "/gmail"}}),
             201, "Gmail connector")
m365 = data(call("POST", MC, "manager_s", S, {"name": "Outlook", "kind": "m365", "secret": "secret-ok",
            "config": {"tenant_id": "t", "client_id": "c", "mailbox": "deals@signal.test", "token_url": M + "/m365/token",
                       "api_base": M + "/m365"}}), 201, "Microsoft 365 connector")
mock("POST", "/_mail/inbox", {"from": "Bulk News <bulk@news.test>", "subject": "Newsletter", "body": "hello", "count": 129})
for c, prefix in ((gmail, "gmail:"), (m365, "m365:")):
    first = data(call("POST", MC + f"/{c['uuid']}/sync", "manager_s", S), 200, f"{prefix} first sync")
    second = data(call("POST", MC + f"/{c['uuid']}/sync", "manager_s", S), 200, f"{prefix} second sync")
    third = data(call("POST", MC + f"/{c['uuid']}/sync", "manager_s", S), 200, f"{prefix} third sync")
    stored = sql(inbound + f"'{prefix}%'")
    check(f"{prefix} a busy inbox catches up over runs, oldest first, nothing skipped (100 + the rest, then nothing)",
          first.get("stored") == 100 and second.get("stored", 0) > 0 and third.get("stored") == 0
          and int(stored[0]) == 100 + second["stored"] and int(stored[0]) > 130, [first, second, third, stored])
oldest = sql(f"SELECT COUNT(*) FROM property_deals_inbound_messages WHERE namespace_id = {NSID} AND external_id = 'gmail:m1'")
check("Gmail read the oldest message too", oldest == ["1"], oldest)
data(call("PUT", MC + f"/{gmail['uuid']}", "manager_s", S, {"secret": {"client_secret": "wrong", "refresh_token": "rt"}}), 200,
     "break Gmail")
res = call("POST", MC + f"/{gmail['uuid']}/sync", "manager_s", S)
check("a broken mailbox says so plainly (502), without the provider's text", res[0] == 502
      and res[1]["error"] == "Gmail sign-in failed" and "bad secret" not in json.dumps(res[1]), res)
sql(f"UPDATE property_deals_mail_connectors SET last_synced_at = NULL WHERE uuid = '{gmail['uuid']}'")
mock("POST", "/_mail/inbox", {"from": "Late Mail <late@mail.test>", "subject": "after", "body": "one more"})
out = data(call("POST", P + "/engine/run", "manager_s", S, {"checks": ["mail"]}), 200, "sync every mailbox")
check("one broken mailbox doesn't stop the others", out["mail"]["errors"] == 1 and out["mail"]["stored"] >= 2
      and out["mail"]["connectors"] == 3, out["mail"])

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
