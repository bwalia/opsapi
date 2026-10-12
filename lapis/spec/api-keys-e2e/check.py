"""Self-service personal API key e2e checks (run by run.sh; stdlib only).

Drives the API as the owner and a developer of workspace A and the owner of
workspace B, with JWT sessions and with the minted keys; reads/changes Postgres
through `docker exec psql` only where the API has no lever (backdating expiry).
Every check prints ok/FAIL; exit 1 on any FAIL.
"""
import base64, hashlib, hmac, json, os, subprocess, sys, time, urllib.error, urllib.request, uuid

API = os.environ["API"]
PG = os.environ["PG_CONTAINER"]
API_CONTAINER = os.environ["API_CONTAINER"]
SECRET = open(os.environ["JWT_SECRET_FILE"]).read().strip()
RUN = uuid.uuid4().hex[:8]  # unique names per run
failures = 0


def check(name, ok, detail=None):
    global failures
    if ok:
        print("  ok   " + name)
    else:
        failures += 1
        print("  FAIL " + name + ("  (" + str(detail)[:500] + ")" if detail is not None else ""))
    return ok


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "ak", "-At", "-F", "|",
                          "-v", "ON_ERROR_STOP=1", "-c", q], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr)
    return [line.split("|") for line in out.stdout.strip().split("\n") if line]


def one(q):
    rows = sql(q)
    return rows[0][0] if rows else None


def b64(d):
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()


def jwt(u):
    now = int(time.time())
    head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = b64(json.dumps({"userinfo": {"uuid": u["uuid"], "email": u["email"]}, "iat": now,
                           "exp": now + 7200, "iss": "opsapi"}).encode())
    sig = b64(hmac.new(SECRET.encode(), (head + "." + body).encode(), hashlib.sha256).digest())
    return head + "." + body + "." + sig


def call(method, path, who, ns=None, body=None):
    """who = a user dict (JWT session) or a raw opsk_ key string."""
    token = who if isinstance(who, str) else jwt(who)
    h = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
    if ns:
        h["X-Namespace-Id"] = str(ns)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload, status = r.read(), r.status
    except urllib.error.HTTPError as e:
        payload, status = e.read(), e.code
    try:
        j = json.loads(payload or b"{}")
    except ValueError:
        j = {"_raw": payload[:300]}
    return status, j


def data(j):
    return j.get("data") if isinstance(j, dict) and j.get("data") is not None else {}


def user(name):
    u = {"uuid": str(uuid.uuid4()), "email": "%s-%s@ak.test" % (name, RUN)}
    sql("INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) "
        "VALUES ('%s', '%s', 'Test', '%s', '%s-%s', 'x', true, now(), now())" % (u["uuid"], name, u["email"], name, RUN))
    return u


def add_member(u, ns_id, role_name):
    sql("""INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
           SELECT gen_random_uuid()::text, %s, id, 'active', false, now(), now(), now() FROM users
           WHERE uuid = '%s'""" % (ns_id, u["uuid"]))
    sql("""INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
           SELECT gen_random_uuid()::text, m.id, r.id, now(), now() FROM namespace_members m, namespace_roles r
           WHERE m.namespace_id = %s AND r.namespace_id = %s AND r.role_name = '%s'
             AND m.user_id = (SELECT id FROM users WHERE uuid = '%s')""" % (ns_id, ns_id, role_name, u["uuid"]))
    return one("SELECT m.id FROM namespace_members m JOIN users u ON u.id = m.user_id "
               "WHERE m.namespace_id = %s AND u.uuid = '%s'" % (ns_id, u["uuid"]))


def my_tasks(key, ns=None):
    return call("GET", "/api/v2/kanban/my-tasks", key, ns)


def mint(who, ns, **body):
    body.setdefault("name", "agent-" + uuid.uuid4().hex[:6])
    return call("POST", "/api/v2/me/api-keys", who, ns, body)


# ---------------------------------------------------------------------------
print("== seed")
owner_a, dev, owner_b = user("ownera"), user("dev"), user("ownerb")
SLUG_A, SLUG_B = "ak-a-" + RUN, "ak-b-" + RUN
for u, name, slug in ((owner_a, "Keys A", SLUG_A), (owner_b, "Keys B", SLUG_B)):
    s, j = call("POST", "/api/v2/user/namespaces", u, None, {"name": name + " " + RUN, "slug": slug})
    check("workspace %s created" % slug, s in (200, 201), j)
ID_A = one("SELECT id FROM namespaces WHERE slug = '%s'" % SLUG_A)
ID_B = one("SELECT id FROM namespaces WHERE slug = '%s'" % SLUG_B)
# A developer role with task access only; the dev is in both workspaces.
for ns in (ID_A, ID_B):
    sql("""INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, created_at, updated_at)
           VALUES (gen_random_uuid()::text, %s, 'agent_dev', 'Agent dev',
                   '{"projects":["read","update"]}', now(), now())""" % ns)
DEV_MEMBER_A = add_member(dev, ID_A, "agent_dev")
add_member(dev, ID_B, "agent_dev")
ROLE_A = one("SELECT id FROM namespace_roles WHERE namespace_id = %s AND role_name = 'agent_dev'" % ID_A)

# A task assigned to the dev, made through the API by the owner.
s, j = call("POST", "/api/v2/kanban/projects", owner_a, ID_A, {"name": "Agent work " + RUN})
check("owner creates a project", s == 201, j)
PROJECT = data(j).get("uuid")
s, j = call("GET", "/api/v2/kanban/projects/%s/boards" % PROJECT, owner_a, ID_A)
boards = data(j) if isinstance(data(j), list) else (data(j).get("boards") or data(j).get("data") or [])
BOARD = boards[0]["uuid"] if boards else None
check("project has a default board", BOARD is not None, j)
s, j = call("POST", "/api/v2/kanban/boards/%s/tasks" % BOARD, owner_a, ID_A, {"title": "Fix the login page " + RUN})
check("owner creates a task", s in (200, 201), j)
TASK = data(j).get("uuid")
s, j = call("POST", "/api/v2/kanban/projects/%s/members" % PROJECT, owner_a, ID_A,
            {"user_uuid": dev["uuid"], "role": "member"})
s, j = call("POST", "/api/v2/kanban/tasks/%s/assignees" % TASK, owner_a, ID_A, {"user_uuid": dev["uuid"]})
check("task assigned to the dev", s in (200, 201), j)

# ---------------------------------------------------------------------------
print("== a member mints a personal key and it works")
s, j = mint(dev, ID_A)
check("member mints a key with the default preset (201)", s == 201, j)
K = data(j)
KEY = K.get("key") or ""
check("raw key returned once, opsk_ + 48 hex", len(KEY) == 53 and KEY.startswith("opsk_"), KEY[:8])
check("default preset = kanban read/update + projects read",
      K.get("scopes") == {"kanban": ["read", "update"], "projects": ["read"]}, K.get("scopes"))
check("bound to the caller, marked self-service", K.get("user_uuid") == dev["uuid"] and K.get("created_via") == "self", K)
days = one("SELECT round(EXTRACT(EPOCH FROM (expires_at - created_at)) / 86400) FROM api_keys WHERE uuid = '%s'"
           % K.get("uuid"))
check("expires in 90 days by default", days == "90", days)
check("only the hash is stored", one("SELECT COUNT(*) FROM api_keys WHERE key_hash = '%s'"
                                     % hashlib.sha256(KEY.encode()).hexdigest()) == "1")
s, j = my_tasks(KEY)
check("key works on GET /kanban/my-tasks as the member", s == 200
      and TASK in [t.get("uuid") for t in (j.get("data") or [])], (s, j))
s, j = my_tasks(KEY, ID_A)
check("... also with its own workspace id in X-Namespace-Id", s == 200, (s, j))
s, j = call("GET", "/api/v2/me/api-keys", dev, ID_A)
listed = data(j) if isinstance(data(j), list) else []
check("member lists their key (no secret, no hash)", s == 200 and [k["uuid"] for k in listed] == [K.get("uuid")]
      and "key" not in listed[0] and "key_hash" not in listed[0], j)
check("last_used_at recorded", bool(listed and listed[0].get("last_used_at")), listed)
check("create is audited", one("SELECT COUNT(*) FROM namespace_audit_logs WHERE action = 'api_key.created' "
                               "AND entity_id = '%s' AND namespace_id = %s" % (K.get("uuid"), ID_A)) == "1")

# ---------------------------------------------------------------------------
print("== mint-time refusals")
s, j = mint(dev, ID_A, scopes={"crm_accounts": ["read"]})
check("a module the member lacks -> 422", s == 422 and "crm_accounts.read" in str(j.get("error")), (s, j))
s, j = mint(dev, ID_A, scopes={"projects": ["manage"]})
check("manage without manage -> 422", s == 422, (s, j))
s, j = mint(dev, ID_A, scopes={"projects": ["delete"]})
check("an action the member lacks -> 422", s == 422, (s, j))
s, j = mint(owner_a, ID_A, scopes={"namespace": ["read"]})
check("namespace refused even for the owner -> 422", s == 422, (s, j))
s, j = mint(owner_a, ID_A, scopes={"api_keys": ["read"]})
check("api-key management refused -> 422", s == 422, (s, j))
s, j = mint(dev, ID_A, scopes={"projects": ["read"]})
check("an explicit subset of the member's permissions is fine (201)", s == 201
      and data(j).get("scopes") == {"projects": ["read"]}, (s, j))
SUBSET_UUID = data(j).get("uuid")
for bad in (0, 366, 1.5, "soon"):
    s, j = mint(dev, ID_A, expires_in_days=bad)
    check("expires_in_days=%r -> 422" % (bad,), s == 422, (s, j))
s, j = mint(dev, ID_A, name="")
check("name required -> 422", s == 422, (s, j))
s, j = call("POST", "/api/v2/me/api-keys", dev, ID_A, None)
check("no body -> 400", s == 400, (s, j))
s, j = mint(dev, None)
check("no workspace header -> refused (400/404)", s in (400, 404), (s, j))
s, j = mint(owner_b, ID_A)
check("a non-member of the workspace -> 403", s == 403, (s, j))

# ---------------------------------------------------------------------------
print("== an API key cannot mint keys")
s, j = mint(KEY, ID_A)
check("key on POST /me/api-keys -> 403", s == 403, (s, j))
s, j = call("GET", "/api/v2/me/api-keys", KEY, ID_A)
check("key on GET /me/api-keys -> 403", s == 403, (s, j))
s, j = call("POST", "/api/v2/api-keys", KEY, ID_A, {"name": "x", "scopes": {"projects": ["read"]}})
check("key on the admin mint -> 403", s == 403, (s, j))
# An admin-minted key scoped for "me" passes the URL gate and still hits the route's guard.
s, j = call("POST", "/api/v2/api-keys", owner_a, ID_A, {"name": "me-scoped", "scopes": {"me": ["create", "read"]}})
ME_KEY = data(j).get("key")
s, j = mint(ME_KEY, ID_A)
check("even a key scoped for /me cannot mint (403)", s == 403 and "cannot manage API keys" in str(j), (s, j))

# ---------------------------------------------------------------------------
print("== admin-minted keys behave as before")
s, j = call("POST", "/api/v2/api-keys", owner_a, ID_A, {
    "name": "admin-made", "user_uuid": dev["uuid"], "scopes": {"kanban": ["read", "update"], "projects": ["read"]}})
check("owner mints a personal key for the dev (201)", s == 201, (s, j))
ADMIN_KEY = data(j).get("key")
ADMIN_KEY_UUID = data(j).get("uuid")
s, j = my_tasks(ADMIN_KEY)
check("admin-minted key works on my-tasks", s == 200 and TASK in [t.get("uuid") for t in j.get("data") or []], (s, j))
s, j = call("GET", "/api/v2/api-keys", owner_a, ID_A)
by_uuid = {k["uuid"]: k for k in (data(j) if isinstance(data(j), list) else [])}
check("admin list shows both kinds (created_via self / none)",
      by_uuid.get(K.get("uuid"), {}).get("created_via") == "self"
      and by_uuid.get(ADMIN_KEY_UUID) is not None and by_uuid[ADMIN_KEY_UUID].get("created_via") is None, by_uuid)
s, j = call("GET", "/api/v2/me/api-keys", dev, ID_A)
check("the member's /me list holds only self-service keys",
      ADMIN_KEY_UUID not in [k["uuid"] for k in (data(j) if isinstance(data(j), list) else [])], j)
s, j = call("DELETE", "/api/v2/me/api-keys/" + ADMIN_KEY_UUID, dev, ID_A)
check("the member cannot revoke an admin-minted key via /me (404)", s == 404, (s, j))

# ---------------------------------------------------------------------------
print("== demotion takes effect on the next request")
s, j = call("PUT", "/api/v2/namespace/roles/%s" % ROLE_A, owner_a, ID_A, {"permissions": {"crm_accounts": ["read"]}})
check("owner removes task access from the dev's role", s == 200, (s, j))
s, j = my_tasks(KEY)
check("self-service key loses /kanban access immediately (403)", s == 403, (s, j))
s, j = my_tasks(ADMIN_KEY)
check("admin-minted key keeps its granted scopes (200, as before)", s == 200, (s, j))
s, j = call("GET", "/api/v2/crm/accounts", KEY)
check("the key never gains the role's new module (403)", s == 403, (s, j))
s, j = call("PUT", "/api/v2/namespace/roles/%s" % ROLE_A, owner_a, ID_A, {"permissions": {"projects": ["read"]}})
s, j = my_tasks(KEY)
check("access back as soon as the role allows it again", s == 200, (s, j))

# ---------------------------------------------------------------------------
print("== expiry")
s, j = mint(dev, ID_A, expires_in_days=1)
EXP_KEY, EXP_UUID = data(j).get("key"), data(j).get("uuid")
check("1-day key minted and works", s == 201 and my_tasks(EXP_KEY)[0] == 200)
sql("UPDATE api_keys SET expires_at = NOW() - interval '1 second' WHERE uuid = '%s'" % EXP_UUID)
s, j = my_tasks(EXP_KEY)
check("expired key refused (401)", s == 401 and "expired" in str(j.get("error")), (s, j))

# ---------------------------------------------------------------------------
print("== revoke")
s, j = mint(dev, ID_A)
REV_KEY, REV_UUID = data(j).get("key"), data(j).get("uuid")
s, j = call("DELETE", "/api/v2/me/api-keys/" + REV_UUID, dev, ID_A)
check("member revokes their own key (200)", s == 200, (s, j))
s, j = my_tasks(REV_KEY)
check("revoked key refused (401)", s == 401, (s, j))
s, j = call("DELETE", "/api/v2/me/api-keys/" + REV_UUID, dev, ID_A)
check("revoking again is a no-op (200)", s == 200, (s, j))
check("revoke audited once", one("SELECT COUNT(*) FROM namespace_audit_logs WHERE action = 'api_key.revoked' "
                                 "AND entity_id = '%s'" % REV_UUID) == "1")
s, j = call("GET", "/api/v2/me/api-keys", dev, ID_A)
rev = [k for k in (data(j) if isinstance(data(j), list) else []) if k["uuid"] == REV_UUID]
check("listed as revoked", rev and rev[0].get("revoked") is True, rev)

# ---------------------------------------------------------------------------
print("== other workspaces and other users")
s, j = my_tasks(KEY, ID_B)
check("A's key with workspace B's id -> 403 (dev is a member of B too)", s == 403, (s, j))
s, j = call("GET", "/api/v2/me/api-keys", dev, ID_B)
check("A's keys are not listed in workspace B", s == 200 and (data(j) if isinstance(data(j), list) else []) == [],
      (s, j))
s, j = call("DELETE", "/api/v2/me/api-keys/" + K.get("uuid"), dev, ID_B)
check("A's key cannot be revoked from workspace B (404)", s == 404, (s, j))
s, j = call("GET", "/api/v2/me/api-keys", owner_a, ID_A)
check("the owner's /me list does not show the dev's keys", K.get("uuid") not in
      [k["uuid"] for k in (data(j) if isinstance(data(j), list) else [])], j)
s, j = call("DELETE", "/api/v2/me/api-keys/" + K.get("uuid"), owner_a, ID_A)
check("the owner cannot revoke the dev's key via /me (404, no 403 leak)", s == 404, (s, j))
s, j = call("DELETE", "/api/v2/me/api-keys/" + str(uuid.uuid4()), dev, ID_A)
check("unknown key -> 404", s == 404, (s, j))
check("the dev's key still works after those attempts", my_tasks(KEY)[0] == 200)

# ---------------------------------------------------------------------------
print("== cap and rate limit")
s, j = call("GET", "/api/v2/me/api-keys", owner_a, ID_A)
made = 0
while made < 12:
    s, j = mint(owner_a, ID_A)
    if s != 201:
        break
    made += 1
check("10 live keys per member, the 11th -> 422", made == 10 and s == 422 and "Revoke one" in str(j.get("error")),
      (made, s, j))
last = one("SELECT uuid FROM api_keys WHERE created_via = 'self' AND user_uuid = '%s' ORDER BY id DESC LIMIT 1"
           % owner_a["uuid"])
call("DELETE", "/api/v2/me/api-keys/" + last, owner_a, ID_A)
s, j = mint(owner_a, ID_A)
check("after revoking one, the 11th create in the hour -> 429", s == 429 and j.get("retry_after"), (s, j))

# ---------------------------------------------------------------------------
print("== removal from the workspace")
s, j = call("PUT", "/api/v2/namespace/members/%s" % DEV_MEMBER_A, owner_a, ID_A, {"status": "suspended"})
check("owner suspends the dev", s == 200, (s, j))
s, j = my_tasks(KEY)
check("suspended member's key refused (401)", s == 401, (s, j))
call("PUT", "/api/v2/namespace/members/%s" % DEV_MEMBER_A, owner_a, ID_A, {"status": "active"})
check("reactivated -> key works again", my_tasks(KEY)[0] == 200)
s, j = call("DELETE", "/api/v2/namespace/members/%s" % DEV_MEMBER_A, owner_a, ID_A)
check("owner removes the dev from workspace A", s == 200, (s, j))
s, j = my_tasks(KEY)
check("removed member's key refused (401)", s == 401, (s, j))
s, j = my_tasks(ADMIN_KEY)
check("admin-minted key: unchanged behaviour (not tied to membership, 200)", s == 200, (s, j))
s, j = mint(dev, ID_A)
check("a removed member can no longer mint here (403)", s == 403, (s, j))

# ---------------------------------------------------------------------------
print("== migrations")
out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "migrate"], capture_output=True, text=True)
check("second migrate run is clean", out.returncode == 0, out.stdout[-400:] + out.stderr[-400:])
sql("DELETE FROM lapis_migrations WHERE name = 'zzak1_api_keys_created_via'")
out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "migrate"], capture_output=True, text=True)
check("zzak1 re-runs cleanly on an existing column", out.returncode == 0, out.stdout[-400:] + out.stderr[-400:])
check("created_via survived", one("SELECT created_via FROM api_keys WHERE uuid = '%s'" % K.get("uuid")) == "self")

print("\n%s" % ("All checks passed." if failures == 0 else "%d check(s) FAILED." % failures))
sys.exit(1 if failures else 0)
