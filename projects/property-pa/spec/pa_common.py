"""Shared setup for the Property PA suites: a workspace with both plugins, the roles, the fixtures, and
(optionally) the JobShout link pointing at the sandbox mock."""
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../../property-deals/spec"))
sys.path.insert(0, os.path.join(HERE, "regression"))
from pdtest import API, USERS, call, expect, sql, workspace  # noqa: E402

PA = API + "/api/v2/property-pa"
PD = API + "/api/v2/property-deals"
SOPHIE, ASHLEY = "operator_s", "manager_s"
ADMIN = "pa_platform_admin"  # demo reset is for platform admins only


def platform_admin():
    """A platform admin (the 'administrative' role) for the demo routes. Idempotent."""
    uuid, email = USERS.setdefault(ADMIN, ("c9999999-0000-4000-8000-000000000009", "pa.admin@pd.invalid"))
    sql(f"INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) "
        f"SELECT '{uuid}', 'PA', 'Admin', '{email}', 'pa.admin', 'x', true, now(), now() "
        f"WHERE NOT EXISTS (SELECT 1 FROM users WHERE uuid = '{uuid}')")
    sql(f"INSERT INTO user__roles (uuid, role_id, user_id, created_at, updated_at) "
        f"SELECT gen_random_uuid()::text, r.id, u.id, now(), now() FROM roles r, users u "
        f"WHERE r.role_name = 'administrative' AND u.uuid = '{uuid}' AND NOT EXISTS (SELECT 1 FROM user__roles x "
        f"WHERE x.role_id = r.id AND x.user_id = u.id)")
    return ADMIN


def data(res, status, name):
    body = expect(name, res, status)
    return body.get("data") if isinstance(body, dict) and "data" in body else body


def mock(method, path, body=None):
    req = urllib.request.Request(os.environ["PD_MOCK"] + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"null")


def pa_answer(text, sources, mode):
    out = {"contract": "property-pa.output.v1", "mode": mode, "answer": text, "sources": sources, "unknowns": [],
           "inferences": [], "actions": [], "needs_human": False}
    return text + "\n\n```pa_output\n" + json.dumps(out) + "\n```"


def setup(name, slug, jobshout=False):
    """@return (namespace id, fixtures)"""
    S = workspace("owner_s", name, slug)
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
    fx = data(call("POST", PA + "/demo/reset", platform_admin(), S, {"sophie_user_uuid": USERS[SOPHIE][0],
              "ashley_user_uuid": USERS[ASHLEY][0]}), 200, "fixtures")
    if jobshout:
        js = data(call("POST", API + "/api/v2/namespace/ai-providers", "owner_s", S, {"name": "JobShout PA",
                  "provider_type": "jobshout", "base_url": "http://pd-mock:8080/js/api/v1", "username": "api-key",
                  "secret": "jsk_test_key"}), 201, "JobShout link")
        expect("PA settings", call("PUT", API + "/api/v2/namespace/plugins/property_pa", "owner_s", S, {"settings": {
            "jobshout_provider_uuid": js["uuid"], "jobshout_seller_agent_id": "seller-agent-1",
            "jobshout_manager_agent_id": "manager-agent-1", "jobshout_webhook_secret": "s3cret"}}), 200)
    return S, fx
