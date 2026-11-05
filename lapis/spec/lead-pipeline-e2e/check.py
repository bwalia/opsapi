#!/usr/bin/env python3
"""Lead pipeline end to end, against a running local stack (docs/plans/LEAD_TO_CASH_PIPELINE.md).

    docker exec -i opsapi sh -c 'cat > /tmp/lp_setup.lua' < lapis/spec/lead-pipeline-e2e/setup.lua
    docker exec -w /app opsapi lapis exec "assert(loadfile('/tmp/lp_setup.lua'))()"
    python3 -I lapis/spec/lead-pipeline-e2e/check.py            # API at http://127.0.0.1:4020

setup.lua makes a test workspace with an owner (a lead manager) and two sales reps,
all @e2e.invalid (mail to them is suppressed outside production), and writes their
tokens to /tmp/lp_tokens.json inside the container; this script reads them from
there and never prints them. Leads it creates use @e2e.invalid addresses too.
"""
import json, os, subprocess, sys, time, urllib.request, urllib.error, datetime

API = os.environ.get("API", "http://127.0.0.1:4020")
CONTAINER = os.environ.get("CONTAINER", "opsapi")
TOK = json.loads(subprocess.check_output(["docker", "exec", CONTAINER, "cat", "/tmp/lp_tokens.json"]))
SLUG = TOK["slug"]
USERS = TOK["users"]
failures = 0
RUN = str(int(time.time()))


def check(name, ok, detail=None):
    global failures
    if ok:
        print("  ok   - " + name)
    else:
        failures += 1
        print("  FAIL - " + name + ("  (" + str(detail)[:400] + ")" if detail is not None else ""))


def call(who, method, path, body=None, expect=None):
    headers = {"Authorization": "Bearer " + USERS[who]["token"], "X-Namespace-Slug": SLUG,
               "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    try:
        payload = json.loads(raw or b"{}")
    except ValueError:
        payload = {"raw": raw[:300].decode(errors="replace")}
    if expect is not None and status != expect:
        print("    -> %s %s returned %s: %s" % (method, path, status, json.dumps(payload)[:300]))
    return status, payload


def wait_for(fn, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(1)
    return None


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


now = datetime.datetime.utcnow()
owner, rep1, rep2 = USERS["owner"]["uuid"], USERS["rep1"]["uuid"], USERS["rep2"]["uuid"]

print("create and the automatic start")
s, r = call("rep1", "POST", "/api/v2/crm/leads", {"first_name": "Ann", "last_name": "Lee " + RUN,
    "email": "ann." + RUN + "@e2e.invalid", "phone": "+447700900" + RUN[-3:], "company_name": "Lee Labs " + RUN,
    "source": "website", "notes": "We need 40 business laptops before term starts."}, expect=201)
check("rep creates a lead (201)", s == 201, r)
ann = r.get("data", {})
check("creator owns it, stage new", ann.get("owner_user_uuid") == rep1 and ann.get("stage") == "new", ann)
started = wait_for(lambda: (lambda st, x: x["data"] if st == 200 and x["data"].get("next_action_at") else None)(
    *call("rep1", "GET", "/api/v2/crm/leads/" + ann["uuid"])))
check("pipeline started: first call planned (event outbox)", started is not None)
if started:
    check("first step is a call", started.get("next_action_type") == "call", started.get("next_action_type"))
    check("pipeline_started flag", (started.get("metadata") or {}).get("pipeline_started") is True)

s, r = call("owner", "POST", "/api/v2/crm/leads", {"first_name": "Queue", "last_name": RUN, "email": "queue." + RUN + "@e2e.invalid",
    "owner_user_uuid": None, "source": "website"}, expect=201)
queued = r.get("data", {})
check("owner leaves a lead unassigned", s == 201 and queued.get("owner_user_uuid") in (None, ""), queued.get("owner_user_uuid"))
assigned = wait_for(lambda: (lambda st, x: x["data"] if st == 200 and x["data"].get("owner_user_uuid") else None)(
    *call("owner", "GET", "/api/v2/crm/leads/" + queued["uuid"])))
check("unassigned lead gets an owner by round-robin", assigned is not None and assigned.get("owner_user_uuid") in (owner, rep1, rep2),
      assigned and assigned.get("owner_user_uuid"))

s, r = call("rep1", "POST", "/api/v2/crm/leads", {"first_name": "Dup", "email": "ann." + RUN + "@e2e.invalid"}, expect=201)
dup = r.get("data", {})
flagged = wait_for(lambda: (lambda st, x: x["data"] if st == 200 and (x["data"].get("metadata") or {}).get("pipeline_started") else None)(
    *call("rep1", "GET", "/api/v2/crm/leads/" + dup["uuid"])))
check("same email flagged as a possible duplicate (not merged)", flagged and flagged["metadata"].get("duplicate_of") == ann["uuid"],
      flagged and flagged.get("metadata"))

print("who sees what")
s, r = call("rep2", "GET", "/api/v2/crm/leads/" + ann["uuid"])
check("another rep can't see rep1's lead (404)", s == 404, s)
s, r = call("rep2", "GET", "/api/v2/crm/leads?per_page=200")
check("rep2's list leaves out rep1's leads", s == 200 and all(l.get("owner_user_uuid") in (None, rep2) for l in r["data"]),
      [l.get("owner_user_uuid") for l in r.get("data", [])][:5])
s, r = call("owner", "GET", "/api/v2/crm/leads?per_page=200&search=" + RUN)
check("the manager sees every lead", s == 200 and any(l["uuid"] == ann["uuid"] for l in r["data"]))
s, r = call("rep2", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/stage", {"stage": "qualified"})
check("rep2 can't move rep1's lead", s in (403, 404), s)
s, r = call("rep2", "POST", "/api/v2/crm/leads", {"first_name": "X", "owner_user_uuid": rep1})
check("a rep can't give a new lead to someone else (403)", s == 403, s)

print("calls and next steps")
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/calls", {"outcome": "teleport"})
check("unknown call outcome refused (422)", s == 422 and r.get("fields", {}).get("outcome"), r)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/calls", {"outcome": "no_answer", "duration_minutes": 1}, expect=201)
check("no answer logged (201)", s == 201, r)
lead = r.get("data", {}).get("lead", {})
check("first call moves new -> contacting", lead.get("stage") == "contacting", lead.get("stage"))
check("attempt counted", lead.get("contact_attempts") == 1, lead.get("contact_attempts"))
check("next attempt planned", r.get("data", {}).get("next_step") is not None and lead.get("next_action_type") == "call")
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/calls", {"outcome": "callback"})
check("call back needs a time (422)", s == 422 and r.get("fields", {}).get("next_at"), r)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/calls",
    {"outcome": "callback", "next_at": iso(now - datetime.timedelta(hours=1))})
check("call back in the past refused (422)", s == 422, s)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/calls",
    {"outcome": "connected", "notes": "Wants 40 laptops, budget about 30k, decides with the head teacher.",
     "next_at": iso(now + datetime.timedelta(days=2))}, expect=201)
check("connected call with a follow-up (201)", s == 201, r)

print("stages")
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/stage", {"stage": "converted"})
check("converted only through Convert (422)", s == 422, r)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + dup["uuid"] + "/stage", {"stage": "lost"})
check("lost needs a reason (422)", s == 422 and r.get("fields", {}).get("reason"), r)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + dup["uuid"] + "/stage", {"stage": "lost", "reason": "Duplicate"}, expect=200)
check("lost with a reason", s == 200 and r["data"]["stage"] == "lost" and r["data"].get("next_action_at") is None, r.get("data", {}).get("next_action_at"))
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + dup["uuid"] + "/stage", {"stage": "nurture", "nurture_until": "2020-01-01"})
check("nurture date in the past refused", s == 422, s)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + dup["uuid"] + "/stage", {"stage": "contacting"}, expect=200)
check("reopened lead gets a call planned", s == 200 and r["data"].get("next_action_type") == "call", r.get("data", {}).get("next_action_type"))
s, r = call("rep1", "PUT", "/api/v2/crm/leads/" + dup["uuid"], {"status": "contacted"})
check("old client's 'contacted' is accepted as contacting (no change -> 200)", s == 200, r)

print("qualify")
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/qualify", {"answers": {"budget": "about 30k", "nonsense": "x"}})
check("unknown question refused", s == 422, s)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/qualify",
    {"answers": {"budget": "about 30k", "decision_maker": "Head teacher"}, "estimated_value": 32000, "currency": "gbp",
     "expected_close_date": (now + datetime.timedelta(days=30)).strftime("%Y-%m-%d"), "move": True}, expect=200)
d = r.get("data", {})
check("qualified with answers and value", s == 200 and d.get("stage") == "qualified" and float(d.get("estimated_value") or 0) == 32000,
      (d.get("stage"), d.get("estimated_value")))
check("value marked as the person's", (d.get("metadata") or {}).get("value_from") == "person")

print("meetings")
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/meetings", {"type": "video",
    "starts_at": iso(now - datetime.timedelta(hours=2))})
check("meeting in the past refused", s == 422, s)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/meetings", {"type": "in_person",
    "starts_at": iso(now + datetime.timedelta(days=3))})
check("in-person meeting needs a place", s == 422 and r.get("fields", {}).get("location"), r)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/meetings", {"type": "video",
    "starts_at": iso(now + datetime.timedelta(days=3)), "duration_minutes": 45, "meeting_url": "https://meet.example.com/abc",
    "guests": [{"email": "head." + RUN + "@e2e.invalid", "name": "Head Teacher"}]}, expect=201)
meeting = r.get("data", {})
check("meeting booked (201)", s == 201 and meeting.get("uuid"), r)
check("attendees: lead, owner, guest", len(meeting.get("attendees", [])) == 3, meeting.get("attendees"))
invited = wait_for(lambda: (lambda st, x: x if st == 200 and any(m["uuid"] == meeting["uuid"] and m["invite"]["up_to_date"]
    for m in x["data"].get("meetings", [])) else None)(*call("rep1", "GET", "/api/v2/crm/leads/" + ann["uuid"])), 25)
check("invite delivered from the outbox (sequence 0)", invited is not None)
s, r = call("rep1", "GET", "/api/v2/crm/leads/" + ann["uuid"])
check("lead moved to Meeting", r["data"]["stage"] == "meeting", r["data"]["stage"])
s, r = call("rep1", "PUT", "/api/v2/crm/meetings/" + meeting["uuid"], {"starts_at": iso(now + datetime.timedelta(days=4))}, expect=200)
check("meeting moved: sequence goes up", s == 200 and r["data"]["ics_sequence"] == 1, r.get("data", {}).get("ics_sequence"))
reinvited = wait_for(lambda: (lambda st, x: x if st == 200 and any(m["uuid"] == meeting["uuid"] and m["invite"]["sent_sequence"] == 1
    for m in x["data"].get("meetings", [])) else None)(*call("rep1", "GET", "/api/v2/crm/leads/" + ann["uuid"])), 25)
check("updated invite delivered (sequence 1)", reinvited is not None)
s, r = call("rep1", "POST", "/api/v2/crm/meetings/" + meeting["uuid"] + "/outcome", {"outcome": "held"})
check("can't record an outcome before the meeting", s == 409, s)
s, r = call("rep2", "POST", "/api/v2/crm/meetings/" + meeting["uuid"] + "/cancel", {})
check("another rep can't cancel it", s in (403, 404), s)

print("board, funnel, my steps, timeline")
s, r = call("owner", "GET", "/api/v2/crm/leads/board")
stages = {c["key"]: c for c in r.get("data", {}).get("stages", [])}
check("board has every stage", s == 200 and set(stages) >= {"new", "contacting", "qualified", "meeting", "converted", "nurture", "lost"})
check("board counts the meeting lead", stages.get("meeting", {}).get("count", 0) >= 1)
s, r = call("owner", "GET", "/api/v2/crm/leads/funnel")
f = r.get("data", {})
check("funnel steps", s == 200 and [x["key"] for x in f.get("steps", [])] == ["new", "contacting", "qualified", "meeting", "converted"], f.get("steps"))
check("funnel: speed to lead measured", f.get("speed_to_lead", {}).get("contacted", 0) >= 1, f.get("speed_to_lead"))
s, r = call("owner", "GET", "/api/v2/crm/leads/funnel?from=2026-12-01&to=2026-01-01")
check("funnel dates the wrong way round refused", s == 422, s)
s, r = call("rep1", "GET", "/api/v2/crm/leads/my-steps")
check("my steps", s == 200 and "overdue" in r["data"] and "meetings" in r["data"])
s, r = call("rep1", "GET", "/api/v2/crm/leads/" + ann["uuid"] + "/timeline")
kinds = [t["kind"] for t in r.get("data", [])]
check("timeline has created, stage changes and calls", s == 200 and "created" in kinds and "stage" in kinds and "activity" in kinds, kinds[:10])

print("partners and referrals")
s, r = call("owner", "POST", "/api/v2/crm/partners", {"name": "Laptop Partner " + RUN, "offering": "Business laptops, bulk IT hardware",
    "categories": ["laptops", "hardware"], "referral_email": "partner." + RUN + "@e2e.invalid", "commission_type": "percent",
    "commission_value": 120})
check("commission over 100% refused", s == 422, s)
s, r = call("owner", "POST", "/api/v2/crm/partners", {"name": "Laptop Partner " + RUN, "offering": "Business laptops, bulk IT hardware",
    "categories": ["laptops", "hardware"], "referral_email": "partner." + RUN + "@e2e.invalid", "commission_type": "percent",
    "commission_value": 5}, expect=201)
partner = r.get("data", {})
check("partner added", s == 201 and partner.get("uuid"), r)
s, r = call("rep1", "POST", "/api/v2/crm/referrals", {"lead_uuid": ann["uuid"], "partner_uuid": partner.get("uuid"),
    "share_contact": True})
check("sharing contact details needs the customer's consent", s == 422 and r.get("fields", {}).get("consent_confirmed"), r)
s, r = call("rep1", "POST", "/api/v2/crm/referrals", {"lead_uuid": ann["uuid"], "partner_uuid": partner.get("uuid"),
    "share_contact": True, "consent_confirmed": True, "message": "Delivery before 1 December."}, expect=201)
ref = r.get("data", {})
check("referral sent", s == 201 and ref.get("status") == "sent", ref.get("status"))
check("commission worked out (5% of 32000 = 1600)", float(ref.get("commission_amount") or 0) == 1600, ref.get("commission_amount"))
s, r = call("rep1", "POST", "/api/v2/crm/referrals", {"lead_uuid": ann["uuid"], "partner_uuid": partner.get("uuid")})
check("no second live referral to the same partner (409)", s == 409, s)
s, r = call("rep1", "POST", "/api/v2/crm/referrals/" + ref.get("uuid", "x") + "/status", {"status": "commission_paid"})
check("illegal referral move refused (409)", s == 409, s)
s, r = call("rep1", "POST", "/api/v2/crm/referrals/" + ref.get("uuid", "x") + "/status", {"status": "accepted"}, expect=200)
check("partner accepted (by hand)", s == 200 and r["data"]["status"] == "accepted", r)
s, r = call("rep1", "POST", "/api/v2/crm/referrals/" + ref.get("uuid", "x") + "/status", {"status": "won", "deal_value": 30000}, expect=200)
check("partner won: commission recomputed (1500)", s == 200 and float(r["data"].get("commission_amount") or 0) == 1500, r.get("data", {}).get("commission_amount"))
s, r = call("rep1", "POST", "/api/v2/crm/referrals/" + ref.get("uuid", "x") + "/invoice", {"tax_rate": 20})
check("a rep without invoice rights can't bill the commission (403)", s == 403, s)
s, r = call("owner", "POST", "/api/v2/crm/referrals/" + ref.get("uuid", "x") + "/invoice", {"tax_rate": 20}, expect=201)
check("owner bills the commission to the partner", s == 201 and r["data"]["referral"]["status"] == "commission_invoiced", r)

print("convert")
s, r = call("rep2", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/convert", {})
check("rep2 can't convert rep1's lead", s in (403, 404), s)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/convert", {"value": "lots"})
check("bad deal value refused", s == 422, s)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/convert", {}, expect=200)
conv = r.get("data", {})
check("converted to a deal", s == 200 and conv.get("deal_uuid") and conv.get("contact_uuid"), r)
check("deal keeps the lead's value (32000) and currency", conv.get("deal_value") == 32000 and conv.get("currency") == "GBP",
      (conv.get("deal_value"), conv.get("currency")))
check("company became an account", conv.get("account_uuid") not in (None, ""))
check("lead is converted and read-only", conv.get("lead", {}).get("stage") == "converted")
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/convert", {})
check("can't convert twice (409)", s == 409, s)
s, r = call("rep1", "POST", "/api/v2/crm/leads/" + ann["uuid"] + "/calls", {"outcome": "connected"})
check("no calls on a converted lead (409)", s == 409, s)
s, r = call("rep1", "GET", "/api/v2/crm/leads/" + ann["uuid"])
refs = r.get("data", {}).get("referrals", [])
check("the referral followed the deal", any(x["uuid"] == ref.get("uuid") and x.get("deal_uuid") == conv.get("deal_uuid") for x in refs), refs[:1])

print("settings")
s, r = call("rep1", "PUT", "/api/v2/crm/leads/settings", {"first_response_minutes": 30})
check("only managers change settings (403)", s == 403, s)
s, r = call("owner", "PUT", "/api/v2/crm/leads/settings", {"first_response_minutes": 0, "currency": "pounds",
    "working_hours": {"start": "18:00", "end": "09:00"}})
fields = r.get("fields", {})
check("invalid settings refused field by field", s == 422 and {"first_response_minutes", "currency", "working_hours"} <= set(fields), fields)
s, r = call("owner", "PUT", "/api/v2/crm/leads/settings", {"first_response_minutes": 45, "lost_reasons": ["No budget", "Other"]}, expect=200)
check("valid settings saved", s == 200 and r["data"]["first_response_minutes"] == 45 and r["data"]["lost_reasons"] == ["No budget", "Other"])
call("owner", "PUT", "/api/v2/crm/leads/settings", {"first_response_minutes": 60,
    "lost_reasons": ["Not interested", "No budget", "Couldn't reach them", "Went elsewhere", "Spam", "Duplicate", "Other"]})

print("all passed" if failures == 0 else "%d failed" % failures)
sys.exit(0 if failures == 0 else 1)
