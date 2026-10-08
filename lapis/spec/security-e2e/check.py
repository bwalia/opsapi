"""Live security checks for the auth-hardening fixes (A1-A7), run by run.sh in a no-internet sandbox.

Every check states the SAFE behaviour, so on code without the fixes the exploit checks fail."""
import base64, hashlib, hmac, json, os, time, urllib.error, urllib.request, uuid as uuidlib

B = "http://sec-api"
SECRET = open("/sec/jwt_secret").read().strip()
U = json.load(open("/sec/users.json"))  # name -> {uuid, email}
PASSWORD = "Sec-test-Passw0rd!"
fails = []

def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else f"   {str(detail)[:300]}"))
    if not ok: fails.append(name)

def b64(d): return base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
def token(who, alg="HS256", exp=True):
    now = int(time.time())
    p = {"userinfo": {"uuid": U[who]["uuid"], "email": U[who]["email"]}, "iat": now, "iss": "opsapi"}
    if exp: p["exp"] = now + 3600
    h = b64({"typ": "JWT", "alg": alg}); body = b64(p)
    if alg == "none": return (h + b"." + body + b".").decode()
    mac = {"HS256": hashlib.sha256, "HS512": hashlib.sha512}[alg]
    sig = base64.urlsafe_b64encode(hmac.new(SECRET.encode(), h + b"." + body, mac).digest()).rstrip(b"=")
    return (h + b"." + body + b"." + sig).decode()

def req(method, path, body=None, tok=None, headers=None, form=None, raw=None):
    h = {"Accept": "application/json"}
    data = None
    if raw is not None: data = raw
    elif form is not None:
        data = "&".join(f"{k}={urllib.request.quote(str(v))}" for k, v in form.items()).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    if tok: h["Authorization"] = "Bearer " + tok
    h.update(headers or {})
    r = urllib.request.Request(B + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as x:
            out = x.read(); return x.status, (json.loads(out) if out[:1] in (b"{", b"[") else out)
    except urllib.error.HTTPError as e:
        out = e.read()
        try: return e.code, json.loads(out)
        except Exception: return e.code, out[:200]

n = [0]
def ip():  # a different client address each call, as an edge proxy would append it
    n[0] += 1; return f"203.0.113.{n[0] % 250 + 1}"
def via_proxy(real, spoof=None):
    return {"X-Forwarded-For": f"{spoof or uuidlib.uuid4().hex[:8]}, {real}"}

ALICE, BOB, EVE = token("alice"), token("bob"), token("eve")
def items(r, key):  # a list endpoint's rows, whatever the envelope
    for c in (r, r.get("data") if isinstance(r, dict) else None):
        if isinstance(c, list): return c
        if isinstance(c, dict):
            for k in (key, "data", "items"):
                if isinstance(c.get(k), list): return c[k]
    return []
def ns(tok, slug): return {"X-Namespace-Slug": slug}

print("setup")
for who, tok, slug in (("alice", ALICE, "sec-a"), ("bob", BOB, "sec-b")):
    st, r = req("POST", "/api/v2/user/namespaces", {"name": slug, "slug": slug}, tok)
    check(f"{who} creates workspace {slug}", st == 201, r)
spaces = {w["slug"]: w for w in req("GET", "/api/v2/user/namespaces", tok=ALICE)[1]["data"]}
A = spaces["sec-a"]["id"]
B_ID = [w for w in req("GET", "/api/v2/user/namespaces", tok=BOB)[1]["data"] if w["slug"] == "sec-b"][0]["id"]
st, r = req("POST", "/api/v2/crm/accounts", {"name": "Alice Secret Ltd"}, ALICE, ns(ALICE, "sec-a"))
check("alice adds a CRM account", st in (200, 201), r)
st, r = req("GET", "/api/v2/crm/accounts", tok=ALICE, headers=ns(ALICE, "sec-a"))
check("alice reads her CRM accounts", st == 200 and "Alice Secret" in json.dumps(r), r)
st, r = req("POST", "/api/v2/namespace/roles", {"role_name": "hr", "display_name": "HR", "permissions": {
    "roles": ["create", "read", "update"], "users": ["create", "read", "update", "delete"], "crm_accounts": ["read"]}}, ALICE, ns(ALICE, "sec-a"))
check("alice creates role hr", st == 201, r)
HR = ((r.get("data") or {}).get("role") or r.get("role") or {}).get("id") if isinstance(r, dict) else None
st, r = req("POST", "/api/v2/namespace/members", {"email": U["eve"]["email"], "role_ids": [HR]}, ALICE, ns(ALICE, "sec-a"))
check("alice adds eve with role hr", st == 201, r)
members = req("GET", "/api/v2/namespace/members", tok=ALICE, headers=ns(ALICE, "sec-a"))[1]
mlist = items(members, "members")
alice_member = [m for m in mlist if m.get("email") == U["alice"]["email"] or (m.get("user") or {}).get("email") == U["alice"]["email"]]

print("A1: X-Public-Browse")
st, r = req("GET", "/api/v2/crm/accounts", tok=BOB, headers={"X-Public-Browse": "true", "X-Namespace-Id": str(A)})
check("bob + X-Public-Browse + alice's workspace id -> refused", st in (401, 403) and "Alice Secret" not in json.dumps(r), (st, r))
st, r = req("GET", "/api/v2/crm/accounts", headers={"X-Public-Browse": "true", "X-Namespace-Id": str(A)})
check("no login + X-Public-Browse -> refused", st in (401, 403) and "Alice Secret" not in json.dumps(r), (st, r))
st, r = req("GET", "/api/v2/crm/accounts", tok=BOB, headers={"X-Namespace-Id": str(A)})
check("bob without the header -> 403 (as before)", st == 403, (st, r))
st, r = req("POST", "/api/v2/storeproducts", form={"name": "Injected", "price": "1"}, headers={"X-Public-Browse": "true", "X-Namespace-Id": str(A)})
check("anonymous POST /api/v2/storeproducts (+header) -> 401", st == 401, (st, r))
st, r = req("POST", "/api/v2/products", {"name": "Injected"}, headers={"X-Public-Browse": "true"})
check("anonymous POST /api/v2/products (a public GET route) -> 401", st == 401, (st, r))
for path in ("/api/v2/products", "/api/v2/categories", "/api/v2/stores"):
    st, r = req("GET", path)
    check(f"anonymous GET {path} still works (storefront)", st == 200, (st, r))
st, r = req("GET", "/api/v2/products", headers={"X-Public-Browse": "true"})
check("a storefront still sending X-Public-Browse keeps working", st == 200, (st, r))

print("A2: client IP")
seen429 = False
for i in range(14):
    st, _ = req("POST", "/auth/login", form={"username": f"nobody{i}@x.test", "password": "x"}, headers=via_proxy("198.51.100.7"))
    seen429 = seen429 or st == 429
check("login limit keyed on the proxy-appended address, not a spoofed X-Forwarded-For", seen429)

print("A3: logins and OTP")
for i in range(10):
    req("POST", "/auth/login", form={"username": U["carol"]["email"], "password": "wrong-" + str(i)}, headers=via_proxy(ip()))
st, r = req("POST", "/auth/login", form={"username": U["carol"]["email"], "password": PASSWORD}, headers=via_proxy(ip()))
check("10 failed passwords (from 10 addresses) lock the account: the right password is refused", st == 429, (st, r))
st, r = req("POST", "/auth/login", form={"username": U["dave"]["email"], "password": PASSWORD}, headers=via_proxy(ip()))
check("another account is unaffected", st == 200 and r.get("requires_2fa"), (st, r))
sess = r.get("session_token") if isinstance(r, dict) else None
codes = []
for i in range(8):
    st, _ = req("POST", "/auth/2fa/resend", {"session_token": sess}, headers=via_proxy(ip()))
    codes.append(st)
check("OTP resends are capped per account (from any address)", 429 in codes, codes)
open("/sec/out/otp_user.txt", "w").write(U["dave"]["uuid"])
# A full sign-in still works with hashed codes, and the test-only peek still reads them.
st, r = req("POST", "/auth/login", form={"username": U["gail"]["email"], "password": PASSWORD}, headers=via_proxy(ip()))
gsess = r.get("session_token") if isinstance(r, dict) else None
st, w = req("POST", "/auth/2fa/verify", {"session_token": gsess, "code": "000000"}, headers=via_proxy(ip()))
check("a wrong code is refused", st == 401, (st, w))
st, pk = req("POST", "/auth/e2e/peek-otp", {"session_token": gsess}, headers={"X-E2E-OTP-Secret": open("/sec/peek_secret").read().strip()})
check("the E2E peek reads the code for a test mailbox", st == 200 and len(str(pk.get("code", ""))) == 6, (st, pk))
st, v = req("POST", "/auth/2fa/verify", {"session_token": gsess, "code": pk.get("code") if isinstance(pk, dict) else ""}, headers=via_proxy(ip()))
check("the right code completes sign-in", st == 200 and isinstance(v, dict) and (v.get("token") or v.get("access_token") or v.get("data")), (st, v))

print("A4: JWT")
st, r = req("GET", "/api/v2/user/namespaces", tok=token("alice", exp=False))
check("a token without exp -> 401", st == 401, (st, r))
st, r = req("GET", "/api/v2/user/namespaces", tok=token("alice", alg="HS512"))
check("a token signed with HS512 -> 401 (HS256 only)", st == 401, (st, r))
st, r = req("GET", "/api/v2/user/namespaces", tok=token("alice", alg="none"))
check("alg none -> 401", st == 401, (st, r))
st, r = req("GET", "/api/v2/user/namespaces", tok=ALICE)
check("a normal token works", st == 200, (st, r))

print("A5: webhooks reach their signature checks")
st, r = req("POST", "/api/v2/webhooks/stripe", raw=b'{"id":"evt_1"}', headers={"Content-Type": "application/json", "Stripe-Signature": "t=1,v1=00"})
check("Stripe (ecommerce) webhook without a login -> its own 400, not the login 401", st == 400, (st, r))
st, r = req("POST", "/api/v2/webhooks/github", raw=b'{"zen":"x"}', headers={"Content-Type": "application/json", "X-GitHub-Event": "ping"})
check("GitHub webhook, unsigned -> 401 Missing signature (its own check)", st == 401 and "signature" in json.dumps(r).lower(), (st, r))
gh_body = b'{"zen":"keep it logically awesome"}'
gh_sig = "sha256=" + hmac.new(open("/sec/gh_secret").read().strip().encode(), gh_body, hashlib.sha256).hexdigest()
st, r = req("POST", "/api/v2/webhooks/github", raw=gh_body, headers={"Content-Type": "application/json", "X-GitHub-Event": "ping",
    "X-Hub-Signature-256": gh_sig})
check("GitHub webhook, correctly signed -> accepted", st == 200, (st, r))

print("A6: public URI patterns")
st, r = req("GET", "/api/v2/crm/public/anything")
check("/api/v2/<core module>/public/... is not public -> 401", st == 401, (st, r))
st, r = req("GET", "/api/v2/delivery/fee-estimate-extra")
check("/api/v2/delivery/fee-estimate<anything> is not public -> 401", st == 401, (st, r))

print("A7: you can't grant what you don't hold")
H = {"X-Namespace-Slug": "sec-a"}
st, r = req("POST", "/api/v2/namespace/roles", {"role_name": "crm_boss", "permissions": {"crm_accounts": ["manage"]}}, EVE, H)
check("eve (crm_accounts.read) creates a role with crm_accounts.manage -> 403", st == 403, (st, r))
st, r = req("POST", "/api/v2/namespace/roles", {"role_name": "crm_reader", "permissions": {"crm_accounts": ["read"]}}, EVE, H)
check("eve creates a role within her own permissions -> 201", st == 201, (st, r))
st, r = req("POST", "/api/v2/users", {"email": f"evil{uuidlib.uuid4().hex[:6]}@sec.test", "password": PASSWORD, "first_name": "E", "last_name": "V", "role": "administrative"}, EVE, H)
check("eve creates a user with platform role administrative -> 403", st == 403, (st, r))
st, r = req("POST", "/api/v2/users", {"email": f"evil{uuidlib.uuid4().hex[:6]}@sec.test", "password": PASSWORD, "first_name": "E", "last_name": "V", "namespace_id": B_ID}, EVE, H)
check("eve creates a user inside bob's workspace -> 403", st == 403, (st, r))
st, r = req("POST", "/api/v2/users", {"email": f"evil{uuidlib.uuid4().hex[:6]}@sec.test", "password": PASSWORD, "first_name": "E", "last_name": "V", "namespace_role": "admin"}, EVE, H)
check("eve creates a user with role admin (manage all) -> 403", st == 403, (st, r))
st, r = req("POST", "/api/v2/users", {"email": f"ok{uuidlib.uuid4().hex[:6]}@sec.test", "password": PASSWORD, "first_name": "E", "last_name": "V", "namespace_role": "member"}, EVE, H)
check("eve creates a plain member -> 201", st == 201, (st, r))
if alice_member:
    st, r = req("PUT", f"/api/v2/namespace/members/{alice_member[0]['id']}", {"role_ids": [HR]}, EVE, H)
    check("eve changes the owner's roles -> 403", st == 403, (st, r))
else:
    check("found alice's member row", False, members)
rl = items(req("GET", "/api/v2/namespace/roles", tok=ALICE, headers=H)[1], "roles")
admin_role = [x for x in rl if isinstance(x, dict) and x.get("role_name") == "admin"]
check("found the admin role", bool(admin_role), rl)
if admin_role:
    st, r = req("POST", "/api/v2/namespace/invitations", {"email": f"inv{uuidlib.uuid4().hex[:6]}@sec.test", "role_id": admin_role[0]["id"]}, EVE, H)
    check("eve invites someone as admin -> 403", st == 403, (st, r))
    st, r = req("POST", "/api/v2/namespace/members", {"email": U["frank"]["email"], "role_ids": [admin_role[0]["id"]]}, EVE, H)
    check("eve adds a member as admin -> 403", st == 403, (st, r))

print("\nFAILURES:", len(fails), fails)
