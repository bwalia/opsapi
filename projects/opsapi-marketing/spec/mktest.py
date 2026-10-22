"""Shared helpers for OpsAPI Marketing Cloud API tests."""
import base64
import hashlib
import hmac
import json
import os
import shlex
import subprocess
import time
import urllib.error
import urllib.request
import uuid

API = os.environ["MKT_API"]
SECRET = os.environ["MKT_JWT_SECRET"]
PSQL = os.environ.get("MKT_PSQL")
P = API + "/api/v2/opsapi-marketing"

USERS = {
    "owner_a": ("a1111111-0000-4000-8000-000000000001", "owner.a@mkt.invalid"),
    "owner_b": ("b2222222-0000-4000-8000-000000000002", "owner.b@mkt.invalid"),
    # Platform admin (JWT role): approves campaigns it didn't create (authors can't self-approve).
    "approver": ("c3333333-0000-4000-8000-000000000003", "approver@mkt.invalid"),
}
ROLES = {"approver": "administrative"}

failures = 0


def jwt(user):
    uid, email = USERS[user]
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
    h = b({"typ": "JWT", "alg": "HS256"})
    info = {"uuid": uid, "email": email}
    if user in ROLES:
        info["roles"] = ROLES[user]
    p = b({"userinfo": info, "iat": int(time.time()), "exp": int(time.time()) + 3600, "iss": "opsapi"})
    sig = base64.urlsafe_b64encode(hmac.new(SECRET.encode(), h + b"." + p, hashlib.sha256).digest()).rstrip(b"=")
    return (h + b"." + p + b"." + sig).decode()


def call(method, url, user, ns=None, body=None):
    headers = {"Authorization": "Bearer " + jwt(user), "Content-Type": "application/json"}
    if ns:
        headers["X-Namespace-Id"] = ns
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, json.loads(raw or b"null")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw.decode(errors="replace")


def check(name, cond, detail=None):
    global failures
    if cond:
        print("ok    " + name)
    else:
        failures += 1
        print("FAIL  " + name + ("  -> " + json.dumps(detail, default=str)[:700] if detail is not None else ""))


def expect(name, res, status):
    check(f"{name} ({status})", res[0] == status, res)
    return res[1] if isinstance(res[1], dict) else {}


def sql(statement):
    out = subprocess.run(shlex.split(PSQL) + [statement], capture_output=True, text=True, check=True)
    return [line for line in out.stdout.splitlines() if line]


def workspace(owner, name, slug):
    res = call("POST", API + "/api/v2/user/namespaces", owner, body={"name": name, "slug": slug})
    if res[0] == 429:
        time.sleep(int((res[1] or {}).get("retry_after") or 60) + 1)
        res = call("POST", API + "/api/v2/user/namespaces", owner, body={"name": name, "slug": slug})
    body = expect(f"{owner} creates workspace {name}", res, 201)
    ns = (body.get("data") or body).get("namespace", body.get("data") or body)
    return str(ns.get("uuid") or ns.get("id"))


def enable(owner, ns):
    return expect("enable marketing plugin",
                  call("PUT", API + "/api/v2/namespace/plugins/opsapi_marketing", owner, ns, {"enabled": True}), 200)


def finish():
    print()
    print("FAILED: %d" % failures if failures else "ALL PASSED")
    return 1 if failures else 0


def new_uuid():
    return str(uuid.uuid4())


def data(b):
    return (b.get("data") or b) if isinstance(b, dict) else {}


def code(res):
    return ((res[1] if isinstance(res[1], dict) else {}).get("details") or {}).get("code")


def run_sender(ns):
    """Run the campaign sender for this workspace once and wait for it to finish."""
    q = (f"SELECT COALESCE(j.last_run_at::text, 'never') FROM plugin_jobs j JOIN namespaces n "
         f"ON n.id = j.namespace_id WHERE j.job = 'opsapi_marketing.campaign_sender' AND n.uuid = '{ns}'")
    deadline = time.time() + 90  # a new workspace's job row is seeded within a minute
    while time.time() < deadline and not sql(q):
        time.sleep(2)
    before = sql(q)
    sql(f"UPDATE plugin_jobs SET next_run_at = NOW() FROM namespaces n WHERE n.id = plugin_jobs.namespace_id "
        f"AND plugin_jobs.job = 'opsapi_marketing.campaign_sender' AND n.uuid = '{ns}'")
    deadline = time.time() + 45
    while time.time() < deadline and sql(q) == before:
        time.sleep(2)
