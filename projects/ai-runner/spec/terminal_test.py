"""AI Runs: web terminals (docs/AI_RUNNER_WEB_TERMINAL.md), end to end against a sandbox OpsAPI.

Run by run.sh (AR_API, AR_JWT_SECRET, AR_PSQL, AR_MIGRATE). Standard library only. Covers: connecting a terminal
(ai_runners.manage, the secret shown once and sealed, address and agent checks, rename, switch off, delete); the
Start dialog's offer (terminals, remembered folders, the prompt); launching (who may, folder / agent / prompt checks,
the signed ticket and its claims, the folder remembered, no comment); the webhook (unknown launch, bad signature,
stale time, start and end once each, another workspace's secret, a rotated secret); expired links; isolation between
workspaces; the migration run again.
"""
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
import uuid as uuidlib

API, SECRET, PSQL = os.environ["AR_API"], os.environ["AR_JWT_SECRET"], os.environ["AR_PSQL"]
MIGRATE = os.environ.get("AR_MIGRATE")
P = API + "/api/v2/ai-runner"
TAG = uuidlib.uuid4().hex[:6]
USERS = {
    "owner_a": ("a1111111-0000-4000-8000-000000000001", "owner.a@ar.invalid"),
    "owner_b": ("b2222222-0000-4000-8000-000000000002", "owner.b@ar.invalid"),
    "dev": ("c3333333-0000-4000-8000-000000000003", "dev.a@ar.invalid"),
    "dev2": ("d4444444-0000-4000-8000-000000000004", "dev2.a@ar.invalid"),
    "mgr": ("e5555555-0000-4000-8000-000000000005", "mgr.a@ar.invalid"),
}
failures = 0


def jwt(user):
    uid, email = USERS[user]
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
    h = b({"typ": "JWT", "alg": "HS256"})
    p = b({"userinfo": {"uuid": uid, "email": email}, "iat": int(time.time()), "exp": int(time.time()) + 3600,
           "iss": "opsapi"})
    sig = base64.urlsafe_b64encode(hmac.new(SECRET.encode(), h + b"." + p, hashlib.sha256).digest()).rstrip(b"=")
    return (h + b"." + p + b"." + sig).decode()


def call(method, url, user=None, ns=None, body=None, raw=None, headers=None):
    h = {"Content-Type": "application/json"}
    if user:
        h["Authorization"] = "Bearer " + jwt(user)
    if ns:
        h["X-Namespace-Id"] = ns
    h.update(headers or {})
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            text = r.read()
            return r.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        text = e.read()
        try:
            return e.code, json.loads(text)
        except ValueError:
            return e.code, text.decode(errors="replace")


def check(name, cond, detail=None):
    global failures
    if cond:
        print("ok    " + name)
    else:
        failures += 1
        print("FAIL  " + name + ("  -> " + json.dumps(detail, default=str)[:900] if detail is not None else ""))


def expect(name, res, status):
    check(f"{name} ({status})", res[0] == status, res)
    body = res[1] if isinstance(res[1], dict) else {}
    return body.get("data", body) if isinstance(body, dict) else body


def sql(statement):
    out = subprocess.run(shlex.split(PSQL) + [statement], capture_output=True, text=True, check=True)
    return [line for line in out.stdout.splitlines() if line]


def one(statement):
    rows = sql(statement)
    return rows[0] if rows else None


def workspace(owner, name, slug):
    res = call("POST", API + "/api/v2/user/namespaces", owner, body={"name": name, "slug": slug})
    if res[0] == 429:
        time.sleep(int((res[1] or {}).get("retry_after") or 60) + 1)
        res = call("POST", API + "/api/v2/user/namespaces", owner, body={"name": name, "slug": slug})
    body = expect(f"{owner} creates workspace {name}", res, 201)
    ns = body.get("namespace", body)
    return str(ns.get("uuid") or ns.get("id"))


def verify_ticket(ticket, secret):
    """The terminal's check: payload.sig, sig = hex HMAC-SHA256(secret, payload). @return claims or None"""
    payload, _, sig = ticket.partition(".")
    if not hmac.compare_digest(hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest(), sig):
        return None
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def webhook(payload, secret, sig=None):
    raw = json.dumps(payload, separators=(",", ":")).encode()
    sig = sig or "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()
    return call("POST", P + "/public/terminal/webhook", raw=raw, headers={"X-Opsapi-Signature": sig})


def comments(task_uuid, like):
    return int(one(f"""SELECT COUNT(*)::int FROM kanban_task_comments c JOIN kanban_tasks t ON t.id = c.task_id
        WHERE t.uuid = '{task_uuid}' AND c.content LIKE '{like}'""") or 0)


# --- Workspaces, roles, a task -------------------------------------------------------------------------------
W = workspace("owner_a", "AR Terminal " + TAG, "ar-term-" + TAG)
X = workspace("owner_b", "AR Terminal other " + TAG, "ar-term-x-" + TAG)
for owner, ns in (("owner_a", W), ("owner_b", X)):
    expect(f"{owner} enables AI Runs", call("PUT", API + "/api/v2/namespace/plugins/ai_runner", owner, ns,
                                            {"enabled": True}), 200)
roles = {}
for name, perms in (("tm_dev_" + TAG, {"ai_runs": ["read", "create"]}),
                    ("tm_view_" + TAG, {"ai_runs": ["read"]}),
                    ("tm_mgr_" + TAG, {"ai_runs": ["manage"], "ai_runners": ["manage"]})):
    body = expect(f"create role {name}", call("POST", API + "/api/v2/namespace/roles", "owner_a", W,
                                              {"role_name": name, "display_name": name, "permissions": perms}), 201)
    roles[name.split("_" + TAG)[0]] = body.get("role", body)["id"]
for user, role in (("dev", "tm_dev"), ("dev2", "tm_view"), ("mgr", "tm_mgr")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_a", W,
                                         {"email": USERS[user][1], "role_ids": [roles[role]]}), 201)
proj = expect("create project", call("POST", API + "/api/v2/kanban/projects", "owner_a", W, {"name": "Site " + TAG}),
              201)
BOARD = one(f"SELECT b.uuid FROM kanban_boards b JOIN kanban_projects p ON p.id = b.project_id "
            f"WHERE p.uuid = '{proj['uuid']}' ORDER BY b.id LIMIT 1")
expect("dev joins the project", call("POST", API + f"/api/v2/kanban/projects/{proj['uuid']}/members", "owner_a", W,
                                     {"user_uuid": USERS["dev"][0], "role": "member"}), 201)
T1 = expect("task", call("POST", API + f"/api/v2/kanban/boards/{BOARD}/tasks", "owner_a", W,
                         {"title": "Fix the header " + TAG, "priority": "medium", "description": "Make it sticky."}),
            201)
expect("assign dev", call("POST", API + f"/api/v2/kanban/tasks/{T1['uuid']}/assignees", "owner_a", W,
                          {"user_uuid": USERS["dev"][0]}), 201)

# --- Connecting a terminal ------------------------------------------------------------------------------------
expect("dev can't list terminals", call("GET", P + "/terminals", "dev", W), 403)
expect("dev can't add one", call("POST", P + "/terminals", "dev", W, {"name": "x", "url": "https://x.invalid"}), 403)
for bad in ("ftp://term.invalid", "https://term.invalid/some/path", "term.invalid", ""):
    expect(f"address {bad!r} refused", call("POST", P + "/terminals", "mgr", W, {"name": "Mac", "url": bad}), 422)
expect("duplicate agent ids refused", call("POST", P + "/terminals", "mgr", W, {
    "name": "Mac", "url": "https://term.invalid", "agents": [{"id": "a", "label": "A"}, {"id": "a", "label": "B"}]}), 422)
expect("agent id with a space refused", call("POST", P + "/terminals", "mgr", W, {
    "name": "Mac", "url": "https://term.invalid", "agents": [{"id": "my agent", "label": "A"}]}), 422)
created = expect("manager adds a terminal", call("POST", P + "/terminals", "mgr", W,
                                                 {"name": "Mac Studio", "url": "https://term.example.invalid/"}), 201)
TERM, SEC = created["terminal"], created["secret"]
check("secret: 64 hex characters, shown once", len(SEC) == 64 and all(c in "0123456789abcdef" for c in SEC), SEC[:6])
check("address stored without the trailing slash", TERM["url"] == "https://term.example.invalid", TERM)
check("default agents: Claude Code, Codex, Cursor, Just a terminal",
      [a["id"] for a in TERM["agents"]] == ["claude", "codex", "cursor", "shell"], TERM["agents"])
check("hint is the secret's last 4", TERM["secret_hint"] == "…" + SEC[-4:], TERM)
listed = expect("manager lists terminals", call("GET", P + "/terminals", "mgr", W), 200)
check("the secret is never listed", SEC not in json.dumps(listed) and len(listed) == 1, listed)
sealed = one(f"SELECT secret_sealed FROM ar_terminals WHERE uuid = '{TERM['uuid']}'")
check("stored sealed, not in clear", sealed.startswith("gcm1:") and SEC not in sealed)
upd = expect("rename + own agent list", call("PUT", P + f"/terminals/{TERM['uuid']}", "mgr", W, {
    "name": "Mac Studio (agents)", "agents": [{"id": "claude", "label": "Claude"}, {"id": "shell", "label": "Shell"}]}),
    200)
check("renamed, agents replaced", upd["name"] == "Mac Studio (agents)" and [a["id"] for a in upd["agents"]]
      == ["claude", "shell"], upd)
check("other workspace sees no terminals", expect("other lists", call("GET", P + "/terminals", "owner_b", X), 200)
      == [])
expect("other workspace can't change it", call("PUT", P + f"/terminals/{TERM['uuid']}", "owner_b", X,
                                               {"name": "mine"}), 404)
expect("other workspace can't rotate it", call("POST", P + f"/terminals/{TERM['uuid']}/rotate-secret", "owner_b",
                                               X), 404)

# --- The Start dialog's offer ---------------------------------------------------------------------------------
pv = expect("dev previews", call("POST", P + f"/tasks/{T1['uuid']}/runs/preview", "dev", W, {}), 200)
offer = pv.get("terminals") or []
check("preview offers the terminal with its agents and no folder yet",
      len(offer) == 1 and offer[0]["uuid"] == TERM["uuid"] and [a["id"] for a in offer[0]["agents"]]
      == ["claude", "shell"] and offer[0]["default_path"] is None and offer[0]["recent_paths"] == [], offer)
check("the terminal prompt names the task and the terminal's folder",
      "Fix the header " + TAG in (pv.get("terminal_prompt") or "")
      and "this terminal's current folder" in pv["terminal_prompt"], pv.get("terminal_prompt"))

# --- Launching ------------------------------------------------------------------------------------------------
L = P + f"/tasks/{T1['uuid']}/terminal-sessions"
good = {"terminal_uuid": TERM["uuid"], "path": "/Users/agents/projects/site/", "agent": "claude"}
expect("read-only member can't launch", call("POST", L, "dev2", W, good), 403)
expect("relative folder refused", call("POST", L, "dev", W, dict(good, path="projects/site")), 422)
expect("folder with a newline refused", call("POST", L, "dev", W, dict(good, path="/Users/a\n/b")), 422)
expect("agent not on this terminal refused", call("POST", L, "dev", W, dict(good, agent="codex")), 422)
expect("unknown terminal", call("POST", L, "dev", W, dict(good, terminal_uuid=str(uuidlib.uuid4()))), 404)
expect("prompt over 8000 bytes refused", call("POST", L, "dev", W, dict(good, prompt="x" * 8001)), 422)
expect("other workspace can't launch on this task", call("POST", L, "owner_b", X, good), 404)
before = comments(T1["uuid"], "%web terminal%")
res = expect("dev launches", call("POST", L, "dev", W, good), 201)
S1, URL1 = res["session"], res["launch_url"]
check("launch_url = terminal address + #launch=<ticket>", URL1.startswith("https://term.example.invalid/#launch="),
      URL1[:60])
claims = verify_ticket(URL1.split("#launch=", 1)[1], SEC)
check("ticket verifies with the shared secret", claims is not None)
claims = claims or {}
now = int(time.time())
check("claims: v, id, task, number, title, folder, agent", claims.get("v") == 1 and claims.get("id") == S1["uuid"]
      and claims.get("task") == T1["uuid"] and claims.get("num") == T1.get("task_number")
      and claims.get("title") == "Fix the header " + TAG and claims.get("path") == "/Users/agents/projects/site"
      and claims.get("agent") == "claude", claims)
check("15-minute link", claims.get("exp", 0) - claims.get("iat", 0) == 900 and claims.get("exp", 0) > now, claims)
check("prompt filled from the template", "Fix the header " + TAG in claims.get("prompt", ""), claims.get("prompt"))
check("by, workspace and a https return link", claims.get("by") == "AR Test"
      and claims.get("ws") == "AR Terminal " + TAG
      and claims.get("return", "").startswith("https://dash.example.invalid/dashboard/projects/"), claims)
check("a wrong secret doesn't verify it", verify_ticket(URL1.split("#launch=", 1)[1], "0" * 64) is None)
check("session recorded as launched", S1["status"] == "launched" and S1["path"] == "/Users/agents/projects/site"
      and S1["agent"] == "claude" and S1["agent_label"] == "Claude" and S1["terminal_name"] == "Mac Studio (agents)"
      and S1["opened_by_name"] == "AR Test", S1)
check("no comment on launch", comments(T1["uuid"], "%web terminal%") == before)
pv2 = expect("preview again", call("POST", P + f"/tasks/{T1['uuid']}/runs/preview", "dev", W, {}), 200)
check("the folder is remembered for this project and terminal",
      pv2["terminals"][0]["default_path"] == "/Users/agents/projects/site"
      and pv2["terminals"][0]["recent_paths"] == ["/Users/agents/projects/site"], pv2["terminals"])
check("stored in the project settings", one(f"""SELECT default_repo_paths ->> '{TERM['uuid']}' FROM ar_project_settings
    WHERE project_uuid = '{proj['uuid']}'""") == "/Users/agents/projects/site")
res2 = expect("launch with own prompt", call("POST", L, "dev", W, dict(good, path="/Users/agents/projects/api",
                                                                      prompt="Do only the CSS.")), 201)
c2 = verify_ticket(res2["launch_url"].split("#launch=", 1)[1], SEC) or {}
check("the given prompt is used", c2.get("prompt") == "Do only the CSS.", c2)
pv3 = expect("preview a third time", call("POST", P + f"/tasks/{T1['uuid']}/runs/preview", "dev", W, {}), 200)
check("latest folder first, the earlier one still suggested",
      pv3["terminals"][0]["recent_paths"] == ["/Users/agents/projects/api", "/Users/agents/projects/site"],
      pv3["terminals"][0])

# --- Webhook ------------------------------------------------------------------------------------------------
ev = {"event": "session_start", "launch": S1["uuid"], "session_id": "ab12cd34ef56", "user": "agents",
      "ts": int(time.time()), "exit_code": None, "reason": None}
expect("unknown launch", webhook(dict(ev, launch=str(uuidlib.uuid4())), SEC), 404)
expect("bad signature", webhook(ev, SEC, sig="sha256=" + "0" * 64), 401)
expect("no signature", call("POST", P + "/public/terminal/webhook", raw=json.dumps(ev).encode()), 401)
expect("stale time", webhook(dict(ev, ts=int(time.time()) - 1000), SEC), 400)
expect("unknown event", webhook(dict(ev, event="session_paused"), SEC), 400)
st = expect("session_start", webhook(ev, SEC), 200)
check("now active, with the terminal's session and user", st["status"] == "active"
      and st["session_id"] == "ab12cd34ef56" and st["terminal_user"] == "agents", st)
check("one comment when work starts", comments(T1["uuid"], "%started working on this in the web terminal%") == 1)
expect("session_start again", webhook(dict(ev, ts=int(time.time())), SEC), 200)
check("…posts nothing more", comments(T1["uuid"], "%started working on this in the web terminal%") == 1)
end = expect("session_end", webhook(dict(ev, event="session_end", exit_code=0, reason="process exited",
                                         ts=int(time.time())), SEC), 200)
check("ended, with exit code and reason", end["status"] == "ended" and end["exit_code"] == 0
      and end["ended_reason"] == "process exited", end)
check("one comment when it ends, with the time it took",
      comments(T1["uuid"], "%web terminal session for this task ended after%") == 1)
expect("session_end again", webhook(dict(ev, event="session_end", ts=int(time.time())), SEC), 200)
check("…posts nothing more", comments(T1["uuid"], "%web terminal session for this task ended after%") == 1)

# Another workspace's terminal secret can't speak for this workspace's launch.
TX = expect("other workspace adds its own terminal", call("POST", P + "/terminals", "owner_b", X,
                                                          {"name": "Theirs", "url": "https://x.invalid"}), 201)
ev2 = dict(ev, launch=res2["session"]["uuid"], ts=int(time.time()))
expect("other workspace's secret is refused", webhook(ev2, TX["secret"]), 401)

# Rotating the secret: the old one stops working at once.
rot = expect("rotate the secret", call("POST", P + f"/terminals/{TERM['uuid']}/rotate-secret", "mgr", W), 200)
NEW = rot["secret"]
check("a new secret", NEW != SEC and len(NEW) == 64)
expect("old secret refused", webhook(ev2, SEC), 401)
expect("new secret accepted", webhook(ev2, NEW), 200)

# --- Expired links, the work bundle -------------------------------------------------------------------------
res3 = expect("a third launch", call("POST", L, "dev", W, good), 201)
sql(f"UPDATE ar_terminal_sessions SET expires_at = NOW() - interval '1 minute' WHERE uuid = '{res3['session']['uuid']}'")
work = expect("read-only member reads the task's AI work", call("GET", P + f"/tasks/{T1['uuid']}/work", "dev2", W), 200)
by_id = {s["uuid"]: s for s in work.get("terminal_sessions") or []}
check("unused old link shows as expired", by_id.get(res3["session"]["uuid"], {}).get("status") == "expired", by_id)
check("ended and active sessions listed", by_id.get(S1["uuid"], {}).get("status") == "ended"
      and by_id.get(res2["session"]["uuid"], {}).get("status") == "active", list(by_id.values()))
listed = expect("task's terminal sessions", call("GET", L, "dev2", W), 200)
check("same list on its own endpoint", {s["uuid"] for s in listed} == set(by_id))
expect("other workspace can't read them", call("GET", L, "owner_b", X), 404)

# --- Switch off, delete -------------------------------------------------------------------------------------
expect("switch the terminal off", call("PUT", P + f"/terminals/{TERM['uuid']}", "mgr", W, {"is_active": False}), 200)
pv4 = expect("preview with it off", call("POST", P + f"/tasks/{T1['uuid']}/runs/preview", "dev", W, {}), 200)
check("not offered, no terminal prompt", pv4.get("terminals") == [] and pv4.get("terminal_prompt") is None, pv4)
expect("can't launch on it", call("POST", L, "dev", W, good), 404)
expect("delete it", call("DELETE", P + f"/terminals/{TERM['uuid']}", "mgr", W), 200)
listed = expect("sessions after delete", call("GET", L, "dev", W), 200)
check("its sessions stay on the task", len(listed) == 3 and all(s["terminal_name"] is None for s in listed), listed)
expect("webhook for a deleted terminal's launch", webhook(dict(ev2, ts=int(time.time())), NEW), 404)

MIG = "20261023120000_ai_runner_web_terminals"
if MIGRATE:
    sql(f"DELETE FROM project_migrations WHERE project_code = 'ai_runner' AND migration_name = '{MIG}'")
    out = subprocess.run(shlex.split(MIGRATE), capture_output=True, text=True)
    check("web terminals migration re-runs idempotently", out.returncode == 0
          and f"{MIG}: running" in (out.stdout + out.stderr)
          and one("SELECT to_regclass('ar_terminals')") == "ar_terminals", (out.stdout + out.stderr)[-400:])

print()
print("FAILED: %d" % failures if failures else "ALL PASSED")
raise SystemExit(1 if failures else 0)
