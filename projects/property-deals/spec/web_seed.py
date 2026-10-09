"""Seed the SPEC §5 scenario for the browser test (opsapi-dashboard/cypress/e2e/property-deals.cy.ts).

Prints JSON: the workspace, the deal, and a session (token + user) for the operator, the manager and a user
of another workspace. Runs against the sandbox (PD_API, PD_JWT_SECRET, PD_PSQL, PD_MOCK as in run.sh).
"""
import datetime
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pdtest  # noqa: E402
from pdtest import API, P, USERS, call, jwt, sql, workspace  # noqa: E402

pdtest.check = lambda *a, **k: None  # quiet: this prints JSON only
MOCK = os.environ["PD_MOCK"]
SUFFIX = datetime.datetime.now().strftime("%H%M%S")


def ok(res):
    if res[0] >= 300:
        sys.stderr.write(json.dumps(res, default=str)[:500] + "\n")
        sys.exit(1)
    b = res[1]
    return (b.get("data") or b) if isinstance(b, dict) else b


S = workspace("owner_s", "Web Demo Ltd", "web-demo-" + SUFFIX)
ok(call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S, {"enabled": True}))
ok(call("POST", P + "/setup", "owner_s", S))
roles = ok(call("GET", API + "/api/v2/namespace/roles", "owner_s", S))
roles = roles if isinstance(roles, list) else roles.get("roles", [])
rid = {r["role_name"]: r["id"] for r in roles}
for u, r in (("manager_s", "pd_manager"), ("operator_s", "pd_operator")):
    ok(call("POST", API + "/api/v2/namespace/members", "owner_s", S, {"email": USERS[u][1], "role_ids": [rid[r]]}))
ok(call("POST", API + "/api/v2/namespace/ai-providers", "owner_s", S, {"name": "Local model", "provider_type": "openai_compatible",
   "base_url": "http://pd-mock:8080/v1", "default_model": "qwen-local", "is_local": True}))
ok(call("PUT", API + "/api/v2/namespace/mail-settings", "owner_s", S, {"host": "pd-mock", "port": 2525, "security": "none",
   "from_email": "deals@web-demo.test"}))

target = (datetime.date.today() + datetime.timedelta(days=13)).isoformat()
prop = ok(call("POST", P + "/properties", "operator_s", S, {"address_line1": "7 Mill Lane", "town": "York", "postcode": "YO1 7AA",
          "tenure": "freehold", "lat": 53.96, "lng": -1.08}))
deal = ok(call("POST", P + "/deals", "operator_s", S, {"property_uuid": prop["uuid"], "deal_type": "buy", "name": "7 Mill Lane",
          "offer_amount": 140000, "target_completion_date": target, "late_penalty_per_day": 500, "late_penalty_cap_days": 20}))
D = deal["uuid"]
firm = ok(call("POST", API + "/api/v2/crm/accounts", "operator_s", S, {"name": "Seller Sol LLP", "email": "sol@seller-sol.test"}))
ok(call("POST", P + "/deal-parties", "operator_s", S, {"deal_uuid": D, "role": "seller_solicitor", "account_uuid": firm["uuid"]}))
for t in ("FENSA certificate", "Boundary dispute with No. 9"):
    ok(call("POST", P + "/enquiries", "operator_s", S, {"deal_uuid": D, "title": t, "owner_party": "seller_solicitor"}))
epc = ok(call("POST", P + "/tasks", "operator_s", S, {"deal_uuid": D, "title": "Book an EPC assessor", "blocking": True}))
sql(f"UPDATE property_deals_task_details SET owner_user_uuid = '{USERS['operator_s'][0]}', sla_minutes = 60, "
    f"sla_started_at = NOW() - interval '65 minutes', due_at = NOW() - interval '5 minutes' WHERE task_uuid = '{epc['task_uuid']}'")
chase = ok(call("POST", P + "/tasks", "operator_s", S, {"deal_uuid": D, "title": "Chase seller's solicitor on enquiries",
            "agent_eligible": True, "agent_key": "legal_chaser", "approval_rule": "any_operator", "blocking": True}))
sql(f"UPDATE property_deals_deals SET predicted_completion_date = target_completion_date + 20 WHERE uuid = '{D}'")
ok(call("POST", P + "/engine/run", "manager_s", S, {"checks": ["sla", "health"]}))

B = workspace("owner_b", "Other Web Co", "other-web-" + SUFFIX)
ok(call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_b", B, {"enabled": True}))
ok(call("POST", P + "/setup", "owner_b", B))


def session(user, ns_uuid, ns_name, ns_slug):
    uuid, email = USERS[user]
    return {"token": jwt(user), "user": {"uuid": uuid, "email": email, "username": email.split("@")[0], "first_name": "PD",
            "last_name": user}, "namespace": {"uuid": ns_uuid, "name": ns_name, "slug": ns_slug}}


print(json.dumps({
    "workspace": S, "deal": D, "epc_task": epc["task_uuid"], "chase_task": chase["task_uuid"], "mock": MOCK,
    "operator": session("operator_s", S, "Web Demo Ltd", "web-demo-" + SUFFIX),
    "manager": session("manager_s", S, "Web Demo Ltd", "web-demo-" + SUFFIX),
    "outsider": session("owner_b", B, "Other Web Co", "other-web-" + SUFFIX),
}))
