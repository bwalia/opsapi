"""The real MCP server against this sandbox (run by run.sh when WITH_MCP=1, after check.py seeded it).

Mints two self-service keys through POST /api/v2/me/api-keys — the workspace owner with the default
"AI agent" preset, Alice with an explicitly read-only one — into files in the sandbox's temp folder
(never printed), then runs mcp_drive.mjs, which drives @opsapi/mcp over stdio and HTTP with them.
"""
import base64, hashlib, hmac, json, os, subprocess, sys, time, urllib.request

API, PG, SECRET = os.environ["API"], os.environ["PG_CONTAINER"], open(os.environ["JWT_SECRET_FILE"]).read().strip()
KEYS, HERE = os.environ["KEY_DIR"], os.path.dirname(os.path.abspath(__file__))


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "mt", "-At", "-F", "|",
                          "-v", "ON_ERROR_STOP=1", "-c", q], capture_output=True, text=True, check=True)
    return [line.split("|") for line in out.stdout.strip().split("\n") if line]


def b64(d):
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()


def jwt(uuid, email):
    now = int(time.time())
    h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    b = b64(json.dumps({"userinfo": {"uuid": uuid, "email": email}, "iat": now, "exp": now + 3600,
                        "iss": "opsapi"}).encode())
    return h + "." + b + "." + b64(hmac.new(SECRET.encode(), (h + "." + b).encode(), hashlib.sha256).digest())


ns_id, ns_uuid = sql("SELECT id, uuid FROM namespaces WHERE slug = 'mt-a'")[0]
users = dict(sql("SELECT email, uuid FROM users WHERE email IN ('ownera@mt.test', 'alice@mt.test')"))
for name, email, scopes in (("owner", "ownera@mt.test", None),
                            ("alice", "alice@mt.test", {"kanban": ["read"], "projects": ["read"]})):
    body = {"name": "mcp e2e " + name, "expires_in_days": 1}
    if scopes:
        body["scopes"] = scopes
    req = urllib.request.Request(API + "/api/v2/me/api-keys", method="POST", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "X-Namespace-Id": ns_uuid,
                                          "Authorization": "Bearer " + jwt(users[email], email)})
    with urllib.request.urlopen(req, timeout=30) as r:
        key = json.loads(r.read())["data"]["key"]
    path = os.path.join(KEYS, name + ".key")
    with open(path, "w") as f:
        f.write(key)
    os.chmod(path, 0o600)

sys.exit(subprocess.run(["node", os.path.join(HERE, "mcp_drive.mjs"), API, ns_id, KEYS]).returncode)
