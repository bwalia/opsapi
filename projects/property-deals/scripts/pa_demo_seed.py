"""Seed the PA demo (docs/property-deals/pa-demo.md) into a workspace through the API.

  python3 pa_demo_seed.py <api-url> <token> <namespace-id>

The token's user owns the demo leads (log in as the demo user). Everything is marked "(demo)". Safe to run
again: leads are matched by email and reused.
"""
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

API, TOKEN, NS = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
P = API + "/api/v2/property-deals"


def call(method, url, body=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + TOKEN, "X-Namespace-Id": NS,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def ok(res, what):
    st, b = res
    if st >= 300:
        sys.exit(f"{what}: HTTP {st} {b}")
    print("ok", what)
    return b.get("data", b)


me = ok(call("GET", API + "/auth/me"), "who am I")
me = me.get("user", me)
ME = me["uuid"]
soon = lambda h: (datetime.now(timezone.utc) + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731

LEADS = [
    {"first_name": "Sarah", "last_name": "Lane", "email": "sarah.lane.demo@example.invalid", "phone": "07700 900456",
     "company_name": "Lane Property Holdings Ltd (demo)", "kind": "buyer_investor",
     "news": [("news", "Set up Lane Property Holdings Ltd last week (demo)"),
              ("social_post", "(demo) Posted on LinkedIn: 'Just completed on our third HMO in Leeds — looking for the next one!'")]},
    {"first_name": "Tom", "last_name": "Rule", "email": "tom.rule.demo@example.invalid", "phone": "07700 900789",
     "company_name": None, "kind": "seller", "situation": "probate", "consent": "consent",
     "news": [("note", "(demo) Inherited 14 Elm Grove from his mother; house is empty and needs work")]},
    {"first_name": "Mark", "last_name": "Agent", "email": "mark.agent.demo@example.invalid", "phone": "07700 900321",
     "company_name": "Leeds Homes Estate Agents (demo)", "kind": "agent",
     "news": [("social_post", "(demo) Posted: 'Three probate properties just landed on our books — all need a full refurb'")]},
]

leads = ok(call("GET", P + "/leads?per_page=100"), "existing leads")
by_email = {l.get("email"): l["uuid"] for l in leads}
for L in LEADS:
    uuid = by_email.get(L["email"])
    if not uuid:
        body = {k: L[k] for k in ("first_name", "last_name", "email", "phone") if L.get(k)}
        if L.get("company_name"):
            body["company_name"] = L["company_name"]
        body.update(owner_user_uuid=ME, source="demo", notes="(demo) PA demo lead")
        uuid = ok(call("POST", API + "/api/v2/crm/leads", body), "lead " + L["first_name"])["uuid"]
    details = {"lead_kind": L["kind"]}
    if L.get("situation"):
        details["situation"] = L["situation"]
    if L.get("consent"):
        details.update(consent_basis=L["consent"], consent_given_at=soon(-72))
    ok(call("PUT", P + f"/leads/{uuid}/details", details), "details " + L["first_name"])
    existing = {s["title"] for s in ok(call("GET", P + f"/leads/{uuid}/signals"), "news " + L["first_name"])}
    for kind, text in L["news"]:
        if text not in existing:
            ok(call("POST", P + f"/leads/{uuid}/signals", {"kind": kind, "title": text, "text": text}), "add news")
    L["uuid"] = uuid

ok(call("POST", P + "/tasks", {"title": "(demo) Call Tom Rule back about 14 Elm Grove", "lead_uuid": LEADS[1]["uuid"],
     "owner_user_uuid": ME, "due_at": soon(-3), "blocking": True, "priority": "high"}), "overdue task")
ok(call("POST", P + "/tasks", {"title": "(demo) Send Mark Agent our buying criteria", "lead_uuid": LEADS[2]["uuid"],
     "owner_user_uuid": ME, "due_at": soon(5)}), "task due today")
ok(call("POST", P + f"/leads/{LEADS[2]['uuid']}/replies", {"channel": "email",
     "text": "(demo) Thanks — not this month, maybe after Christmas."}), "a warm reply from Mark")
print("\nDemo ready. Sarah's 'call me' reply is left for the live demo (step 6).")
