"""Personal follow-ups, step 2: the AI drafts, a person approves, then it goes.

  * news from the Companies House watch starts a draft by itself (lead with an owner, AI provider on)
  * the draft opens with the newest news, is addressed from the lead record, and waits for approval
  * approved: email through the workspace SMTP (with an opt-out line), chase logged, news marked used, task done
  * SMS goes through the workspace's own Android SMS Gateway; WhatsApp becomes a click-to-chat link (no paid API)
  * a private person needs a lawful basis before anything is sent; a company contact (B2B) doesn't
  * an opt-out cancels waiting drafts and blocks new ones; vulnerable leads need a manager's approval
  * other workspaces can't touch any of it
"""
import email
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, sql, workspace  # noqa: E402

MOCK = os.environ["PD_MOCK"]
M = "http://pd-mock:8080"
OP = USERS["operator_s"][0]


def mock(method, path, body=None):
    req = urllib.request.Request(MOCK + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"null")


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


def wait_run(run_uuid, timeout=30):
    deadline, r = time.time() + timeout, {}
    while time.time() < deadline:
        r = (call("GET", P + f"/agent-runs/{run_uuid}", "operator_s", S)[1] or {}).get("data") or {}
        if r.get("status") not in ("queued", "running", None):
            return r
        time.sleep(0.4)
    return r


def pending_for(task_uuid):
    return data(call("GET", P + f"/approvals?task_uuid={task_uuid}&status=pending", "manager_s", S), 200, "pending") or []


def payload(a):
    p = a.get("payload")
    return json.loads(p) if isinstance(p, str) else (p or {})


def result(a):
    r = a.get("execution_result")
    return json.loads(r) if isinstance(r, str) else (r or {})


def mail_text(raw):
    msg, out = email.message_from_string(raw), []
    for part in msg.walk():
        if part.get_content_type() == "text/plain":
            out.append((part.get_payload(decode=True) or b"").decode("utf-8", "replace"))
    return "\n".join(out)


def new_lead(body):
    res = expect("lead " + body["first_name"], call("POST", API + "/api/v2/crm/leads", "operator_s", S,
                 dict(body, owner_user_uuid=OP)), 201)
    return (res.get("data") or res)["uuid"]


mock("POST", "/_ctl", {"reset_all": True})
S = workspace("owner_s", "Follow Up Homes", "follow-up-homes")
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
                          ("sms_gateway", {"base_url": M + "/smsgw", "username": "gw"}, "gw-pass")):
    data(call("POST", P + "/connectors", "manager_s", S, {"kind": kind, "name": kind, "config": cfg, "secret": secret}),
         201, "connector " + kind)
expect("SMTP → sink", call("PUT", API + "/api/v2/namespace/mail-settings", "owner_s", S,
       {"host": "pd-mock", "port": 2525, "security": "none", "from_email": "deals@followup.test"}), 200)
data(call("POST", API + "/api/v2/namespace/ai-providers", "owner_s", S, {"name": "Local", "provider_type": "openai_compatible",
     "base_url": M + "/v1", "default_model": "qwen-local", "is_local": True}), 201, "local model")

# --- 1. News starts a draft by itself -------------------------------------------------------------------------------
L = new_lead({"first_name": "Sarah", "last_name": "Lane", "email": "sarah@lane.test", "company_name": "Acme Homes Ltd"})
data(call("PUT", P + f"/leads/{L}/details", "operator_s", S, {"lead_kind": "buyer_investor", "ch_officer_id": "OFF123"}),
     200, "link the officer")
run = data(call("POST", P + "/signals/run", "manager_s", S), 200, "watch")
check("news found and a follow-up draft started", run["watch"]["signals"] >= 1 and run["watch"]["followups"] == 1, run)
task = sql(f"SELECT task_uuid FROM property_deals_task_details WHERE lead_uuid = '{L}' AND agent_key = 'lead_followup'")
check("one follow-up task on the lead", len(task) == 1, task)
T = task[0]
runs = data(call("GET", P + f"/agent-runs?task_uuid={T}", "operator_s", S), 200, "runs")
r = wait_run(runs[0]["uuid"]) if runs else {}
check("the draft run succeeded", r.get("status") == "succeeded" and r.get("trigger") == "news", r)
pend = pending_for(T)
check("one approval waiting", len(pend) == 1 and pend[0]["action"] == "send_lead_followup", pend)
A = pend[0]
p = payload(A)
news = data(call("GET", P + f"/leads/{L}/signals", "operator_s", S), 200, "news")
check("opens with the newest news and names it in the title",
      p["signal_uuid"] == news[0]["uuid"] and "Congratulations on" in p["body"] and news[0]["title"][:30] in A["title"], (p, A["title"]))
check("addressed from the lead record, email, with a subject", p["to"] == "sarah@lane.test" and p["channel"] == "email"
      and p["subject"], p)
check("nothing was sent before approval", not mock("GET", "/_smtp"))
res = call("POST", P + f"/leads/{L}/follow-up", "operator_s", S, {"channel": "email"})
check("a second follow-up while one waits is refused (409)", res[0] == 409, res)

# Approve -> sent
ok = data(call("POST", P + f"/approvals/{A['uuid']}/decide", "operator_s", S, {"decision": "approve"}), 200, "approve")
check("approved → executed", ok["status"] == "executed", ok)
mails = [m for m in mock("GET", "/_smtp") if any("sarah@lane.test" in t for t in m["to"])]
check("emailed through the workspace SMTP with an opt-out line", len(mails) == 1
      and "reply STOP" in mail_text(mails[0]["data"]) and "Congratulations on" in mail_text(mails[0]["data"]),
      mails and mail_text(mails[0]["data"]))
chase = sql(f"SELECT channel || '|' || status || '|' || outcome FROM property_deals_chases WHERE lead_uuid = '{L}'")
check("chase logged on the lead", chase == ["email|sent|followup"], chase)
check("the news is marked used", sql(f"SELECT used_at IS NOT NULL FROM property_deals_lead_signals WHERE uuid = '{p['signal_uuid']}'")
      == ["t"])
st = data(call("GET", P + f"/tasks/{T}", "operator_s", S), 200, "task after send")
check("follow-up task done", st["pd_status"] == "done", st["pd_status"])
check("last follow-up recorded", sql(f"SELECT last_followup_at IS NOT NULL FROM property_deals_lead_details WHERE lead_uuid = '{L}'")
      == ["t"])

# --- 2. A private person: needs a lawful basis; SMS through the workspace's own gateway ---------------------------------
P2 = new_lead({"first_name": "Dan", "last_name": "Home", "phone": "07700 900222"})
res = call("POST", P + f"/leads/{P2}/follow-up", "operator_s", S, {"channel": "email"})
check("email needs an email address (422)", res[0] == 422, res)
f = data(call("POST", P + f"/leads/{P2}/follow-up", "operator_s", S, {"channel": "sms", "note": "keep it short"}), 202,
         "SMS follow-up")
wait_run(f["run_uuid"])
a2 = pending_for(f["task_uuid"])[0]
check("SMS draft has no subject and goes to the lead's phone", payload(a2)["channel"] == "sms" and not payload(a2).get("subject")
      and payload(a2)["to"] == "07700 900222", payload(a2))
mock("POST", "/_ctl", {"reset_alerts": True})
dec = data(call("POST", P + f"/approvals/{a2['uuid']}/decide", "operator_s", S, {"decision": "approve"}), 200, "approve SMS")
check("no lawful basis → not sent, the approval says why", dec["status"] == "failed" and "lawful basis" in json.dumps(dec)
      and not mock("GET", "/_alerts"), dec)
data(call("PUT", P + f"/leads/{P2}/details", "operator_s", S, {"consent_basis": "consent",
     "consent_given_at": "2026-10-01T10:00:00Z"}), 200, "record consent")
ret = data(call("POST", P + f"/approvals/{a2['uuid']}/retry", "manager_s", S), 200, "retry after consent")
sms = mock("GET", "/_alerts")
check("sent from the workspace's SMS gateway to the lead (E.164), with STOP", ret["status"] == "executed" and len(sms) == 1
      and sms[0]["to"] == "+447700900222" and "Reply STOP" in sms[0]["text"], (ret["status"], sms))

# WhatsApp: a click-to-chat link, the task stays open until the person sends it
f = data(call("POST", P + f"/leads/{P2}/follow-up", "operator_s", S, {"channel": "whatsapp"}), 202, "WhatsApp follow-up")
wait_run(f["run_uuid"])
a3 = pending_for(f["task_uuid"])[0]
dec = data(call("POST", P + f"/approvals/{a3['uuid']}/decide", "operator_s", S, {"decision": "approve"}), 200, "approve WhatsApp")
link = result(dec).get("manual_link", "")
check("WhatsApp gives a wa.me link with the approved text", dec["status"] == "executed"
      and link.startswith("https://wa.me/447700900222?text="), (dec["status"], link))
st = data(call("GET", P + f"/tasks/{f['task_uuid']}", "operator_s", S), 200, "WhatsApp task")
check("task stays open (in progress) until it's sent by hand", st["pd_status"] == "in_progress", st["pd_status"])
check("chase logged as a draft", sql(f"SELECT status FROM property_deals_chases WHERE lead_uuid = '{P2}' AND channel = 'whatsapp'")
      == ["draft"])

# --- 3. Opt-out cancels what's waiting and blocks new drafts -----------------------------------------------------------
P3 = new_lead({"first_name": "Opal", "last_name": "Out", "email": "opal@out.test", "company_name": "Opal Lettings Ltd"})
f = data(call("POST", P + f"/leads/{P3}/follow-up", "operator_s", S, {}), 202, "follow-up for Opal")
wait_run(f["run_uuid"])
check("Opal's draft is waiting", len(pending_for(f["task_uuid"])) == 1)
data(call("POST", P + f"/leads/{P3}/replies", "operator_s", S, {"channel": "email", "text": "Please remove me from your list"}),
     201, "opt-out reply")
check("the waiting draft is cancelled", not pending_for(f["task_uuid"]))
st = data(call("GET", P + f"/tasks/{f['task_uuid']}", "operator_s", S), 200, "Opal task")
check("and its task", st["pd_status"] == "cancelled", st["pd_status"])
res = call("POST", P + f"/leads/{P3}/follow-up", "operator_s", S, {})
check("no new follow-up after an opt-out (409)", res[0] == 409, res)

# --- 4. Vulnerable people: a manager approves ---------------------------------------------------------------------------
P4 = new_lead({"first_name": "Vera", "last_name": "Care", "email": "vera@care.test", "company_name": "Care Lets Ltd"})
data(call("PUT", P + f"/leads/{P4}/details", "operator_s", S, {"vulnerability_flag": True,
     "vulnerability_note": "Recently bereaved"}), 200, "flag vulnerable")
f = data(call("POST", P + f"/leads/{P4}/follow-up", "operator_s", S, {}), 202, "follow-up for Vera")
wait_run(f["run_uuid"])
a4 = pending_for(f["task_uuid"])[0]
check("manager rule", a4["rule"] == "manager", a4["rule"])
res = call("POST", P + f"/approvals/{a4['uuid']}/decide", "operator_s", S, {"decision": "approve"})
check("an operator can't approve it (403)", res[0] == 403, res)

# --- 5. Isolation -------------------------------------------------------------------------------------------------------
B = workspace("owner_b", "Other Follow Co", "other-follow")
expect("enable the plugin (B)", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_b", B, {"enabled": True}), 200)
res = call("POST", P + f"/leads/{L}/follow-up", "owner_b", B, {})
check("other workspace can't follow up our lead (404)", res[0] == 404, res)

sys.exit(finish())
