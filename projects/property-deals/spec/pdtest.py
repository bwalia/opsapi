"""Shared helpers for the Property Deals API tests (standard library only)."""
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

API = os.environ["PD_API"]
SECRET = os.environ["PD_JWT_SECRET"]
PSQL = os.environ.get("PD_PSQL")  # e.g. "docker exec -i pd-pg-1 psql -U postgres -d e2e -tA -c"
P = API + "/api/v2/property-deals"

USERS = {
    "owner_a": ("a1111111-0000-4000-8000-000000000001", "owner.a@pd.invalid"),
    "owner_b": ("b2222222-0000-4000-8000-000000000002", "owner.b@pd.invalid"),
    "reader": ("c3333333-0000-4000-8000-000000000003", "reader.a@pd.invalid"),
    "agent": ("d4444444-0000-4000-8000-000000000004", "agent.a@pd.invalid"),
    "operator": ("e5555555-0000-4000-8000-000000000005", "operator.a@pd.invalid"),
    "owner_s": ("f6666666-0000-4000-8000-000000000006", "owner.s@pd.invalid"),
    "manager_s": ("a7777777-0000-4000-8000-000000000007", "manager.s@pd.invalid"),
    "operator_s": ("b8888888-0000-4000-8000-000000000008", "operator.s@pd.invalid"),
}

failures = 0


def jwt(user):
    uuid, email = USERS[user]
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
    h = b({"typ": "JWT", "alg": "HS256"})
    p = b({"userinfo": {"uuid": uuid, "email": email}, "iat": int(time.time()), "exp": int(time.time()) + 3600,
           "iss": "opsapi"})
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
            return r.status, json.loads(r.read() or b"null")
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
    """Run SQL in the sandbox database (time travel for SLA tests). Returns stdout rows."""
    out = subprocess.run(shlex.split(PSQL) + [statement], capture_output=True, text=True, check=True)
    return [line for line in out.stdout.splitlines() if line]


def workspace(owner, name, slug):
    res = call("POST", API + "/api/v2/user/namespaces", owner, body={"name": name, "slug": slug})
    if res[0] == 429:  # 5 workspaces a minute per IP: the suites create more, so wait it out once
        time.sleep(int((res[1] or {}).get("retry_after") or 60) + 1)
        res = call("POST", API + "/api/v2/user/namespaces", owner, body={"name": name, "slug": slug})
    body = expect(f"{owner} creates workspace {name}", res, 201)
    ns = (body.get("data") or body).get("namespace", body.get("data") or body)
    return str(ns.get("uuid") or ns.get("id"))


def finish():
    print()
    print("FAILED: %d" % failures if failures else "ALL PASSED")
    return 1 if failures else 0
