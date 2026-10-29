"""AI Runs: web terminals (docs/AI_RUNNER_WEB_TERMINAL.md), end to end against a sandbox OpsAPI.

Run by run.sh (AR_API, AR_JWT_SECRET, AR_PSQL, AR_MIGRATE). Standard library only. Covers: connecting a terminal
(ai_runners.manage, the secret shown once and sealed, address and agent checks, rename, switch off, delete); the
Start dialog's offer (terminals, remembered folders, the prompt); launching (who may, folder / agent / prompt checks,
the signed ticket and its claims, the folder remembered, no comment); the webhook (unknown launch, bad signature,
stale time, start and end once each, another workspace's secret, a rotated secret); expired links; isolation between
workspaces; auto sign-in (§8: the permission, the terminal switch, the emailed-code step-up, the login claim and the
2-minute link); agents reporting their pull request (§9: the token, the task moved to Review, once per URL); the
migrations run again.
"""
import base64
import gzip
import hashlib
import hmac
import json
import os
import shlex
import struct
import subprocess
import time
import urllib.error
import urllib.request
import uuid as uuidlib

API, SECRET, PSQL = os.environ["AR_API"], os.environ["AR_JWT_SECRET"], os.environ["AR_PSQL"]
MIGRATE = os.environ.get("AR_MIGRATE")
EXEC = os.environ.get("AR_EXEC")
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
for bad in ("ftp://term.invalid", "https://term.invalid/some/path", "term.invalid", "", "http://term.invalid"):
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
check("default agents: Claude Code, unattended, Codex, Cursor, Just a terminal",
      [a["id"] for a in TERM["agents"]] == ["claude", "claude_auto", "codex", "cursor", "shell"], TERM["agents"])
check("auto sign-in is off for a new terminal", TERM["autologin"] is False, TERM)
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
check("the terminal prompt names the task and leaves the folder to fill in",
      "Fix the header " + TAG in (pv.get("terminal_prompt") or "")
      and "Work in the folder {{repo_path}} on the branch" in pv["terminal_prompt"], pv.get("terminal_prompt"))

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
check("…with the folder chosen", "Work in the folder /Users/agents/projects/site on the branch" in claims.get("prompt", "")
      and "{{repo_path}}" not in claims.get("prompt", ""), claims.get("prompt"))
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
NEW = SEC2 = rot["secret"]
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

# --- Auto sign-in (§8) ----------------------------------------------------------------------------------------
A = P + "/terminal-autologin"
check("dev may not be signed in automatically",
      expect("dev asks", call("GET", A, "dev", W), 200) == {"allowed": False, "stepup": None})
expect("dev can't ask for a code", call("POST", A + "/code", "dev", W), 403)
expect("dev can't launch with auto sign-in", call("POST", L, "dev", W, dict(good, autologin=True)), 403)
check("the owner may", expect("owner asks", call("GET", A, "owner_a", W), 200) == {"allowed": True, "stepup": None})
expect("auto sign-in refused on a terminal that doesn't allow it",
       call("POST", L, "owner_a", W, dict(good, autologin=True)), 409)
on = expect("manager allows auto sign-in", call("PUT", P + f"/terminals/{TERM['uuid']}", "mgr", W,
                                                 {"autologin": True}), 200)
check("…saved", on["autologin"] is True, on)
pv5 = expect("preview shows it", call("POST", P + f"/tasks/{T1['uuid']}/runs/preview", "owner_a", W, {}), 200)
check("offer says the terminal allows auto sign-in", pv5["terminals"][0]["autologin"] is True, pv5["terminals"])
nostep = call("POST", L, "owner_a", W, dict(good, autologin=True))
check("no step-up yet: 403 stepup_required", nostep[0] == 403 and (nostep[1] or {}).get("code") == "stepup_required",
      nostep)
expect("owner asks for a code", call("POST", A + "/code", "owner_a", W), 200)
code = one(f"""SELECT o.peek_code FROM admin_otp_codes o JOIN users u ON u.id = o.user_id
    WHERE u.uuid = '{USERS['owner_a'][0]}' ORDER BY o.id DESC LIMIT 1""")
check("a code was made for the owner", code is not None and len(code) == 6, code)
wrong = "000000" if code != "000000" else "111111"
expect("a wrong code", call("POST", A + "/verify", "owner_a", W, {"code": wrong}), 401)
vs = expect("the right code", call("POST", A + "/verify", "owner_a", W, {"code": code}), 200)
st = vs.get("stepup") or {}
check("step-up remembered for 12 hours", st.get("expires_at", 0) - st.get("verified_at", 0) == 43200, vs)
expect("the same code doesn't work twice", call("POST", A + "/verify", "owner_a", W, {"code": code}), 401)
check("…and is still remembered", (expect("owner asks again", call("GET", A, "owner_a", W), 200).get("stepup")
                                   or {}).get("verified_at") == st.get("verified_at"))
check("the step-up is per workspace", expect("other workspace", call("GET", A, "owner_b", X), 200)["stepup"] is None)
sql(f"UPDATE users SET email = 'renamed.a@ar.invalid' WHERE uuid = '{USERS['owner_a'][0]}'")
check("a step-up is void once the account's email changes",
      expect("owner asks after an email change", call("GET", A, "owner_a", W), 200)["stepup"] is None)
sql(f"UPDATE users SET email = '{USERS['owner_a'][1]}' WHERE uuid = '{USERS['owner_a'][0]}'")
auto = expect("owner launches with auto sign-in", call("POST", L, "owner_a", W, dict(good, autologin=True)), 201)
ac = verify_ticket(auto["launch_url"].split("#launch=", 1)[1], SEC2) or {}
check("login claim: email, user, step-up time", ac.get("login") == {"email": USERS["owner_a"][1],
      "user": USERS["owner_a"][0], "stepup": st.get("verified_at")}, ac.get("login"))
check("2-minute link", ac.get("exp", 0) - ac.get("iat", 0) == 120, ac)
check("session marked as auto sign-in", auto["session"]["autologin"] is True, auto["session"])
rep_ = ac.get("report") or {}
check("report claim: the report address and a token",
      rep_.get("url", "").endswith("/api/v2/ai-runner/public/terminal/report")
      and len(rep_.get("token", "")) == 43, rep_)
stored = one(f"SELECT report_token_hash FROM ar_terminal_sessions WHERE uuid = '{auto['session']['uuid']}'")
check("only the token's SHA-256 is stored", stored == hashlib.sha256(rep_.get("token", "").encode()).hexdigest()
      and rep_.get("token", "-") not in json.dumps(auto), stored)
plain = expect("dev launches normally", call("POST", L, "dev", W, good), 201)
pc = verify_ticket(plain["launch_url"].split("#launch=", 1)[1], SEC2) or {}
check("no login claim, 15-minute link, still a report token", "login" not in pc
      and pc.get("exp", 0) - pc.get("iat", 0) == 900 and len((pc.get("report") or {}).get("token", "")) == 43, pc)
check("the prompt tells the agent how to report", "OPSAPI_REPORT_URL" in pc.get("prompt", "")
      and "OPSAPI_REPORT_TOKEN" in pc.get("prompt", "") and pc.get("report", {}).get("token", "-")
      not in pc.get("prompt", ""), pc.get("prompt"))
expect("forget the step-up", call("DELETE", A, "owner_a", W), 200)
expect("…then auto sign-in needs a code again", call("POST", L, "owner_a", W, dict(good, autologin=True)), 403)
sql(f"""INSERT INTO ar_terminal_stepups (namespace_id, user_uuid, email, verified_at, expires_at)
    SELECT id, '{USERS['owner_a'][0]}', '{USERS['owner_a'][1]}', NOW() - interval '13 hours', NOW() - interval '1 hour'
    FROM namespaces
    WHERE uuid::text = '{W}' OR id::text = '{W}'""")
expect("an expired step-up doesn't count", call("POST", L, "owner_a", W, dict(good, autologin=True)), 403)

# --- Agents report their pull request (§9) --------------------------------------------------------------------
R_ = P + "/public/terminal/report"
TOK = rep_.get("token", "")


def report(body, token=TOK):
    return call("POST", R_, raw=json.dumps(body).encode(),
                headers={"Authorization": "Bearer " + token} if token is not None else {})


expect("no token", report({"pr_url": "https://github.com/acme/web/pull/7"}, token=None), 401)
expect("unknown token", report({"pr_url": "https://github.com/acme/web/pull/7"}, token="x" * 43), 401)
expect("not a pull request URL", report({"pr_url": "https://evil.invalid/acme/web/pull/7"}), 422)
expect("nothing to report", report({}), 422)
TS = lambda: one(f"SELECT status FROM kanban_tasks WHERE uuid = '{T1['uuid']}'")
check("task not in review yet", TS() != "review", TS())
r1 = expect("agent reports its PR", report({"pr_url": "https://github.com/acme/web/pull/7/", "note": "Sticky header."}),
            200)
check("PR attached to the task: repo, number, open", (r1.get("pr") or {}).get("repo") == "acme/web"
      and r1["pr"].get("pr_number") == 7 and r1["pr"].get("state") == "open"
      and r1["pr"].get("pr_url") == "https://github.com/acme/web/pull/7" and r1.get("task_uuid") == T1["uuid"], r1)
check("task moved to review (on_pr_open default)", TS() == "review", TS())
check("one comment with the PR and the note",
      comments(T1["uuid"], "%opened a pull request from the web terminal: https://github.com/acme/web/pull/7%"
               "Sticky header.%") == 1)
expect("the same PR again", report({"pr_url": "https://github.com/acme/web/pull/7"}), 200)
check("…attached once, no second comment", int(one(f"""SELECT COUNT(*) FROM ar_task_prs
    WHERE task_uuid = '{T1['uuid']}' AND pr_url = 'https://github.com/acme/web/pull/7'""")) == 1
      and comments(T1["uuid"], "%opened a pull request from the web terminal%") == 1)
expect("a note on its own", report({"note": "Tests pass."}), 200)
check("…posted as a comment", comments(T1["uuid"], "%: Tests pass.") == 1)
prs = expect("the task's PRs", call("GET", P + f"/tasks/{T1['uuid']}/prs", "dev2", W), 200)
check("listed with the task's PRs, ready for sign-off", any(p["pr_url"] == "https://github.com/acme/web/pull/7"
      and p["review_status"] == "pending" for p in prs), prs)
expect("the project names its repository", call("PUT", P + f"/projects/{proj['uuid']}/settings", "owner_a", W,
                                                {"target_repo_url": "https://github.com/acme/web.git"}), 200)
expect("a PR in another repository is refused (it could finish the task when it merges)",
       report({"pr_url": "https://github.com/someone/else/pull/1"}), 422)
expect("a PR in the project's repository (any case) is fine", report({"pr_url": "https://github.com/Acme/Web/pull/8"}),
       200)
sql(f"UPDATE ar_terminal_sessions SET created_at = NOW() - interval '8 days' WHERE uuid = '{auto['session']['uuid']}'")
expect("a week-old token stops working", report({"note": "late"}), 401)
s_ = expect("settings", call("GET", P + "/settings", "owner_a", W), 200)["task_automation"]
check("defaults: Review when a PR opens, Done when it merges",
      s_.get("on_pr_open") == {"enabled": True, "status": "review", "column": "Review"}
      and s_.get("on_pr_merged") == {"enabled": True, "status": "completed", "column": "Done"}, s_)
saved = expect("switch off the merge move", call("PUT", P + "/settings", "owner_a", W,
                                                 {"task_automation": {"on_pr_merged": {"enabled": False}}}), 200)
check("…saved, the rest kept", saved["task_automation"]["on_pr_merged"]["enabled"] is False
      and saved["task_automation"]["on_pr_open"]["enabled"] is True, saved["task_automation"])

# --- Keys managers issue (§10) --------------------------------------------------------------------------------
K = P + f"/terminals/{TERM['uuid']}/keys"


def pubkey():
    """An ssh-ed25519 public key line (the dashboard makes the pair in the manager's browser; only this comes here)."""
    blob = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + os.urandom(32)
    return "ssh-ed25519 " + base64.b64encode(blob).decode() + " made-in-test"


def fetch_keys(term_uuid=None, secret=None, ts=None, sig=None):
    """What the terminal does: a signed GET. @return status, raw body, the answer's X-Opsapi-Signature"""
    term_uuid, secret = term_uuid or TERM["uuid"], secret or SEC2
    ts = str(int(time.time()) if ts is None else ts)
    sig = sig or "sha256=" + hmac.new(secret.encode(), f"keys\n{term_uuid}\n{ts}".encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(P + "/public/terminal/keys", headers={
        "X-Opsapi-Terminal": term_uuid, "X-Opsapi-Timestamp": ts, "X-Opsapi-Signature": sig})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read(), r.headers.get("X-Opsapi-Signature", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), ""


def live_keys():
    """The terminal's view: the keys, only if the answer's signature checks out."""
    st, raw, sig = fetch_keys()
    good = "sha256=" + hmac.new(SEC2.encode(), raw, hashlib.sha256).hexdigest()
    return json.loads(raw)["keys"] if st == 200 and hmac.compare_digest(sig, good) else None


expect("a member can't see the keys", call("GET", K, "dev", W), 403)
expect("another workspace can't see them", call("GET", K, "owner_b", X), 404)
kl = expect("manager lists keys", call("GET", K, "mgr", W), 200)
check("no keys yet; the people list has the workspace's members",
      kl["keys"] == [] and {USERS[u][0] for u in ("dev", "dev2", "mgr")} <= {p["uuid"] for p in kl["people"]}, kl)
expect("not an ed25519 public key", call("POST", K, "mgr", W, {"user_uuid": USERS["dev"][0],
                                                               "public_key": "ssh-rsa AAAAB3Nza"}), 422)
expect("only members of this workspace", call("POST", K, "mgr", W, {"user_uuid": USERS["owner_b"][0],
                                                                    "public_key": pubkey()}), 422)
expect("a member can't issue keys", call("POST", K, "dev", W, {"user_uuid": USERS["dev"][0],
                                                               "public_key": pubkey()}), 403)
k1_line = pubkey()
k1 = expect("manager issues dev a key", call("POST", K, "mgr", W, {"user_uuid": USERS["dev"][0],
                                                                   "public_key": k1_line}), 201)
check("active, named after the email, fingerprinted", k1.get("status") == "active" and k1.get("terminal_user")
      == "dev.a" and k1.get("fingerprint", "").startswith("SHA256:") and k1.get("person_email") == USERS["dev"][1], k1)
check("works for 90 days", one(f"""SELECT EXTRACT(EPOCH FROM expires_at - created_at)::int FROM ar_terminal_keys
    WHERE uuid = '{k1['uuid']}'""") == str(90 * 86400))
check("only the public half is stored, without its comment", one(f"""SELECT public_key FROM ar_terminal_keys
    WHERE uuid = '{k1['uuid']}'""") == k1_line.rsplit(" ", 1)[0])
expect("the same key can't be issued twice", call("POST", K, "mgr", W, {"user_uuid": USERS["dev"][0],
                                                                        "public_key": k1_line}), 409)
k2_line = pubkey()
k2 = expect("a new key for dev", call("POST", K, "mgr", W, {"user_uuid": USERS["dev"][0], "public_key": k2_line}), 201)
st_ = {k["uuid"]: k["status"] for k in expect("list again", call("GET", K, "mgr", W), 200)["keys"]}
check("the old one is replaced; same terminal user", st_ == {k1["uuid"]: "replaced", k2["uuid"]: "active"}
      and k2["terminal_user"] == "dev.a", st_)

# The terminal fetching its keys, and the card's connection status (§12) following along.
def connection():
    terms = expect("manager lists terminals", call("GET", P + "/terminals", "mgr", W), 200)
    return next(t for t in terms if t["uuid"] == TERM["uuid"])["connection"]


sql(f"UPDATE ar_terminals SET last_contact_at = NULL, last_refused_at = NULL, last_refused_reason = NULL "
    f"WHERE uuid = '{TERM['uuid']}'")
check("status: waiting until the terminal first calls", connection() == {"state": "waiting"}, connection())
check("unknown terminal: 401", fetch_keys(term_uuid=str(uuidlib.uuid4()))[0] == 401)
check("wrong signature: 401", fetch_keys(sig="sha256=" + "0" * 64)[0] == 401)
c = connection()
check("status: the secret doesn't match", c["state"] == "secret" and c["refused_secs_ago"] <= 5, c)
check("signed with the old secret: 401", fetch_keys(secret=SEC)[0] == 401)
check("an old request can't be replayed", fetch_keys(ts=int(time.time()) - 3600)[0] == 400)
c = connection()
check("status: the right secret but the clock is off", c["state"] == "clock", c)
lk = live_keys()
c = connection()
check("status: connected once a good call comes in", c["state"] == "connected" and c["seen_secs_ago"] <= 5, c)
sql(f"UPDATE ar_terminals SET last_contact_at = NOW() - interval '5 minutes', last_refused_at = NULL "
    f"WHERE uuid = '{TERM['uuid']}'")
c = connection()
check("status: lost after two minutes without a call", c["state"] == "lost" and 290 <= c["seen_secs_ago"] <= 320, c)
sql(f"UPDATE ar_terminals SET last_refused_at = NOW() - interval '20 minutes', last_refused_reason = 'secret' "
    f"WHERE uuid = '{TERM['uuid']}'")
check("an old refusal no longer shows", connection()["state"] == "lost", connection())
lk = live_keys()
check("the card's list never shows the secret", "secret_sealed" not in json.dumps(
    expect("list", call("GET", P + "/terminals", "mgr", W), 200)))
check("the terminal gets dev's live key, signed", lk is not None and len(lk) == 1 and lk[0]["user"] == "dev.a"
      and lk[0]["public_key"] == k2_line.rsplit(" ", 1)[0] and lk[0]["email"] == USERS["dev"][1]
      and lk[0]["expires_unix"] > time.time() + 89 * 86400, lk)

# A person with a live key may be signed in by the link (after the emailed code), on that terminal.
check("dev with a key may be signed in automatically",
      expect("dev asks", call("GET", A, "dev", W), 200)["allowed"] is True)
pv6 = expect("dev previews", call("POST", P + f"/tasks/{T1['uuid']}/runs/preview", "dev", W, {}), 200)
check("the offer lets dev be signed in there", pv6["terminals"][0]["autologin"] is True, pv6["terminals"])
check("dev2 without a key still may not", expect("dev2 asks", call("GET", A, "dev2", W), 200)["allowed"] is False)
expect("dev asks for a code", call("POST", A + "/code", "dev", W), 200)
dcode = one(f"""SELECT o.peek_code FROM admin_otp_codes o JOIN users u ON u.id = o.user_id
    WHERE u.uuid = '{USERS['dev'][0]}' ORDER BY o.id DESC LIMIT 1""")
expect("dev confirms it", call("POST", A + "/verify", "dev", W, {"code": dcode}), 200)
dl = expect("dev launches signed in", call("POST", L, "dev", W, dict(good, autologin=True)), 201)
dc = verify_ticket(dl["launch_url"].split("#launch=", 1)[1], SEC2) or {}
check("…the link signs dev in by email", (dc.get("login") or {}).get("email") == USERS["dev"][1], dc.get("login"))

# Blocking, leaving, expiring.
expect("a member can't block keys", call("POST", K + f"/{k2['uuid']}/block", "dev", W), 403)
expect("manager blocks dev's key", call("POST", K + f"/{k2['uuid']}/block", "mgr", W), 200)
expect("blocking twice: not found", call("POST", K + f"/{k2['uuid']}/block", "mgr", W), 404)
check("the terminal no longer gets it", live_keys() == [], live_keys())
check("…and dev can't be signed in automatically any more",
      expect("dev asks again", call("GET", A, "dev", W), 200)["allowed"] is False)
expect("dev's launch with auto sign-in is refused", call("POST", L, "dev", W, dict(good, autologin=True)), 403)
kb = [k for k in expect("list", call("GET", K, "mgr", W), 200)["keys"] if k["uuid"] == k2["uuid"]][0]
check("listed as blocked, with who blocked it", kb["status"] == "blocked" and kb["revoked_by_name"], kb)

k3 = expect("a key for dev2", call("POST", K, "mgr", W, {"user_uuid": USERS["dev2"][0], "public_key": pubkey()}), 201)
check("dev2's key is live", [k["user"] for k in live_keys()] == ["dev2.a"])
sql(f"UPDATE users SET active = false WHERE uuid = '{USERS['dev2'][0]}'")
check("a deactivated person's key stops at once", live_keys() == [])
sql(f"UPDATE users SET active = true WHERE uuid = '{USERS['dev2'][0]}'")
check("…for good: reactivating them doesn't bring the old key back", live_keys() == [])
check("listed as left", [k["status"] for k in expect("list", call("GET", K, "mgr", W), 200)["keys"]
                         if k["uuid"] == k3["uuid"]] == ["left"])

k4 = expect("a new key for dev2", call("POST", K, "mgr", W, {"user_uuid": USERS["dev2"][0], "public_key": pubkey()}),
            201)
sql(f"UPDATE ar_terminal_keys SET expires_at = NOW() + interval '5 days' WHERE uuid = '{k4['uuid']}'")
REMIND = f"""SELECT COUNT(*)::int FROM kanban_notifications WHERE recipient_user_uuid = '{USERS['mgr'][0]}'
    AND title = 'A web terminal key expires soon'"""
live_keys()
check("the manager who issued it is reminded before it expires", one(REMIND) == "1", one(REMIND))
live_keys()
check("…once", one(REMIND) == "1", one(REMIND))
sql(f"UPDATE ar_terminal_keys SET expires_at = NOW() - interval '1 minute' WHERE uuid = '{k4['uuid']}'")
check("an expired key isn't sent", live_keys() == [])
check("listed as expired", [k["status"] for k in expect("list", call("GET", K, "mgr", W), 200)["keys"]
                            if k["uuid"] == k4["uuid"]] == ["expired"])
k5 = expect("dev gets a key again", call("POST", K, "mgr", W, {"user_uuid": USERS["dev"][0], "public_key": pubkey()}),
            201)
check("dev's name is kept; never given to someone else", k5["terminal_user"] == "dev.a")

# --- Work log (§11) ---------------------------------------------------------------------------------------------
ACT, REC = P + "/public/terminal/activity", P + "/public/terminal/recordings"


def signed(path, body, headers=None, secret=None, msg=None):
    """A request from the terminal, signed with its secret (over the body, or `msg`)."""
    sig = hmac.new((secret or SEC2).encode(), body if msg is None else msg, hashlib.sha256).hexdigest()
    h = {"X-Opsapi-Terminal": TERM["uuid"], "X-Opsapi-Signature": "sha256=" + sig}
    h.update(headers or {})
    return call("POST", path, raw=body, headers=h)


def get_raw(url, user, ns):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + jwt(user), "X-Namespace-Id": ns})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def page(user, ns, query=""):
    res = call("GET", P + "/work-log" + query, user, ns)
    body = res[1] if isinstance(res[1], dict) else {}
    return res[0], body.get("data") or [], body.get("meta") or {}


NOW, LAUNCH = time.time(), dl["session"]["uuid"]
SECRET_TXT = "ghp_" + "A1b2C3d4" * 5
tabs = [
    {"id": "tab0a", "user": "dev.a", "key": "SHA256:a-file-key", "via": "opsapi_launch", "ip": "203.0.113.4",
     "launch": LAUNCH, "kind": "local", "cwd": "/Users/agents/projects/site", "agent": "claude",
     "opened_at": NOW - 600, "closed_at": None, "active_secs": 420, "input_bytes": 1200, "output_bytes": 88000},
    {"id": "tab0b", "user": "dev.a", "key": k5["fingerprint"], "via": "key", "ip": "203.0.113.4", "launch": None,
     "kind": "local", "cwd": "/Users/agents/projects", "agent": None, "opened_at": NOW - 300, "closed_at": NOW - 60,
     "end_reason": "closed", "exit_code": 0, "active_secs": 120, "input_bytes": 50, "output_bytes": 900},
    {"id": "tab0c", "user": "ownerfile", "key": "SHA256:not-an-opsapi-key", "via": "key", "kind": "local",
     "opened_at": NOW - 200, "active_secs": 10},
]


def ev(i, tab, typ, attrs):
    return {"id": f"{tab}:{i}", "tab": tab, "at": NOW - 500 + i, "type": typ, "session": "cs-1", "prompt_id": "p-1",
            "attrs": attrs}


events = [
    ev(1, "tab0a", "user_prompt", {"prompt": f"Fix the header. Use token {SECRET_TXT}", "prompt_length": 50,
                                   "user.email": "shared-account@claude.invalid"}),
    ev(2, "tab0a", "api_request", {"model": "claude-opus-5-5", "input_tokens": "2", "output_tokens": 400,
                                   "cache_read_tokens": 23910, "cache_creation_tokens": 16690, "cost_usd": 0.13839,
                                   "duration_ms": 2560}),
    ev(3, "tab0a", "tool_result", {"tool_name": "Bash", "success": "true", "duration_ms": 900,
                                   "tool_parameters": '{"command":"npm test"}'}),
    ev(4, "tab0a", "tool_decision", {"tool_name": "Edit", "decision": "accept", "source": "config"}),
    ev(5, "tab0a", "api_error", {"model": "claude-opus-5-5", "error": "overloaded", "status_code": "529"}),
    ev(6, "tab0a", "metric", {"name": "claude_code.lines_of_code.count", "type": "added", "value": 12}),
    ev(7, "tab0a", "metric", {"name": "claude_code.lines_of_code.count", "type": "removed", "value": "3"}),
    ev(8, "tab0a", "metric", {"name": "claude_code.commit.count", "value": 1}),
    ev(9, "tab0a", "metric", {"name": "claude_code.pull_request.count", "value": 1}),
    ev(10, "tab0b", "api_request", {"model": "claude-haiku-5-5", "input_tokens": 1000, "output_tokens": 10,
                                    "cost_usd": 0.0001}),
    {"id": "none:1", "tab": None, "at": NOW - 100, "type": "user_prompt", "attrs": {"prompt": "unattributed"}},
    {"id": "tab0a:99", "tab": "tab0a", "at": NOW, "type": "hook_registered", "attrs": {}},
]
report_body = json.dumps({"terminal": TERM["uuid"], "sent_at": int(NOW), "tabs": tabs, "events": events}).encode()
expect("activity without a signature", call("POST", ACT, raw=report_body, headers={"X-Opsapi-Terminal": TERM["uuid"]}),
       401)
expect("activity signed with the old secret", signed(ACT, report_body, secret=SEC), 401)
expect("activity that isn't JSON", signed(ACT, b"not json"), 400)
got = expect("the terminal reports tabs and events", signed(ACT, report_body), 200)
check("3 tabs, 11 events (other event types dropped)", got == {"tabs": 3, "events": 11}, got)
check("the same report again adds nothing", expect("report again", signed(ACT, report_body), 200).get("events") == 0)

st_, rows, meta = page("owner_a", W, "?per_page=50")
tabs_by = {r["tab_id"]: r for r in rows}
check("the owner sees every tab", st_ == 200 and {"tab0a", "tab0b", "tab0c"} <= set(tabs_by)
      and meta.get("sees_everyone") is True, (st_, list(tabs_by), meta))
a = tabs_by.get("tab0a") or {}
check("a tab from a task link is its opener's, on that task", a.get("user_uuid") == USERS["dev"][0]
      and a.get("task_uuid") == T1["uuid"] and a.get("session_uuid") == LAUNCH and a.get("person_email") == USERS["dev"][1],
      a)
check("…with its totals: prompts, requests, actions, tokens, cost, lines, commits, PRs, active time",
      a.get("prompts") == 1 and a.get("requests") == 1 and a.get("tool_calls") == 1 and a.get("input_tokens") == 2
      and a.get("output_tokens") == 400 and a.get("cache_read_tokens") == 23910 and a.get("cache_write_tokens") == 16690
      and abs((a.get("cost_usd") or 0) - 0.13839) < 1e-6 and a.get("lines_added") == 12 and a.get("lines_removed") == 3
      and a.get("commits") == 1 and a.get("pull_requests") == 1 and a.get("active_secs") == 420 and a.get("open") is True,
      a)
b = tabs_by.get("tab0b") or {}
check("a tab signed in with an OpsAPI key is that person's", b.get("user_uuid") == USERS["dev"][0]
      and b.get("task_uuid") is None and b.get("end_reason") == "closed" and b.get("open") is False, b)
c = tabs_by.get("tab0c") or {}
check("a key from the terminal's own file: no person, its terminal user", c.get("user_uuid") is None
      and c.get("terminal_user") == "ownerfile", c)
_, dev_rows, dev_meta = page("dev", W)
check("dev sees only their own tabs", sorted(r["tab_id"] for r in dev_rows) == ["tab0a", "tab0b"]
      and dev_meta.get("sees_everyone") is False, [r["tab_id"] for r in dev_rows])
check("…and can't widen it", sorted(r["tab_id"] for r in page("dev", W, f"?user_uuid={USERS['owner_a'][0]}")[1])
      == ["tab0a", "tab0b"])
check("dev2 sees nothing of theirs", page("dev2", W)[1] == [])
check("another workspace sees none", page("owner_b", X)[1] == [])
check("filter by task", [r["tab_id"] for r in page("owner_a", W, f"?task_uuid={T1['uuid']}")[1]] == ["tab0a"])
expect("totals per person need the permission", call("GET", P + "/work-log/people", "dev", W), 403)
people = expect("owner: totals per person", call("GET", P + "/work-log/people", "owner_a", W), 200)
dp = [x for x in people if x["user_uuid"] == USERS["dev"][0]]
check("dev: 2 tabs, 540 s active, 1 prompt, 2 requests, its cost", len(dp) == 1 and dp[0]["tabs"] == 2
      and dp[0]["active_secs"] == 540 and dp[0]["prompts"] == 1 and dp[0]["requests"] == 2
      and abs(dp[0]["cost_usd"] - 0.13849) < 1e-6, dp)

d = expect("dev opens their tab", call("GET", P + f"/work-log/tabs/{a.get('uuid')}", "dev", W), 200)
evs = d.get("events") or []
check("the timeline in order", [e["type"] for e in evs][:5] == ["user_prompt", "api_request", "tool_result",
                                                                    "tool_decision", "api_error"], [e["type"] for e in evs])
check("the prompt is kept word for word, a secret in it masked, Claude's account email dropped",
      evs and "Fix the header" in (evs[0].get("text") or "") and SECRET_TXT not in (evs[0].get("text") or "")
      and "user.email" not in evs[0].get("attrs", {}), evs[:1])
check("the command the AI ran", len(evs) > 2 and "npm test" in (evs[2].get("text") or "") and evs[2]["tool_name"] == "Bash"
      and evs[2]["success"] is True, evs[2:3])
check("retention is stated", d.get("text_days") == 90 and d.get("recording_days") == 30)
expect("dev2 can't open dev's tab", call("GET", P + f"/work-log/tabs/{a.get('uuid')}", "dev2", W), 404)
expect("another workspace can't", call("GET", P + f"/work-log/tabs/{a.get('uuid')}", "owner_b", X), 404)
au = one(f"""SELECT COUNT(*) || '|' || SUM(input_tokens) || '|' || SUM(cached_input_tokens) FROM ai_usage
    WHERE user_uuid = '{USERS['dev'][0]}' AND feature = 'web_terminal'""")
check("model requests count in AI usage, as the person's", au == f"2|{2 + 16690 + 23910 + 1000}|23910", au)
sess = [s for s in expect("the task's sessions", call("GET", L, "dev", W), 200) if s["uuid"] == LAUNCH]
check("the task's session shows its work log", sess and (sess[0].get("work_log") or {}).get("uuid") == a.get("uuid")
      and sess[0]["work_log"]["prompts"] == 1, sess)

CAST = (json.dumps({"version": 2, "width": 80, "height": 24, "timestamp": int(NOW)}) + "\n"
        + json.dumps([0.5, "o", "hello $ "]) + "\n").encode()


def rec(part, body, final="0", tab="tab0a", secret=None):
    return signed(REC, body, secret=secret, msg=f"{tab}\n{part}\n".encode() + body,
                  headers={"X-Opsapi-Tab": tab, "X-Opsapi-Part": str(part), "X-Opsapi-Final": final,
                           "Content-Type": "application/gzip"})


expect("a recording part signed with the old secret", rec(0, gzip.compress(CAST), secret=SEC), 401)
expect("a part that isn't gzipped", rec(0, CAST), 400)
check("a recording part is stored", expect("part 0", rec(0, gzip.compress(CAST)), 200) == {"stored": True})
check("…once", expect("part 0 again", rec(0, gzip.compress(CAST)), 200) == {"stored": False})
expect("the final part", rec(1, gzip.compress(json.dumps([1.0, "o", "bye"]).encode() + b"\n"), final="1"), 200)
d2 = expect("the tab again", call("GET", P + f"/work-log/tabs/{a.get('uuid')}", "dev", W), 200)
check("its parts are listed", [x["part"] for x in d2.get("recording", [])] == [0, 1]
      and d2["recording"][1]["final"] is True and d2.get("recording_parts") == 2, d2.get("recording"))
PART0 = P + f"/work-log/tabs/{a.get('uuid')}/recording/0"
st0, raw0 = get_raw(PART0, "dev", W)
check("the recording comes back as recorded", st0 == 200 and gzip.decompress(raw0) == CAST, st0)
check("dev2 can't fetch it", get_raw(PART0, "dev2", W)[0] == 404)

if EXEC:
    sql("UPDATE ar_terminal_events SET created_at = NOW() - interval '91 days' WHERE event_id = 'tab0a:1'")
    sql("""UPDATE ar_terminal_recordings SET created_at = NOW() - interval '31 days' WHERE part = 0
        AND tab_ref = (SELECT id FROM ar_terminal_tabs WHERE tab_id = 'tab0a')""")
    out = subprocess.run(shlex.split(EXEC) + [
        "package.path = '/app/projects/ai-runner/?.lua;' .. package.path; require('ai_runner.worklog').sweep()"],
        capture_output=True, text=True)
    check("the retention sweep runs", out.returncode == 0, (out.stdout + out.stderr)[-300:])
    check("text older than 90 days is blanked; its numbers stay", one("""SELECT COALESCE(text, 'none') || '|' || type
        FROM ar_terminal_events WHERE event_id = 'tab0a:1'""") == "none|user_prompt")
    d3 = expect("the tab after the sweep", call("GET", P + f"/work-log/tabs/{a.get('uuid')}", "dev", W), 200)
    check("recordings older than 30 days are deleted", [x["part"] for x in d3.get("recording", [])] == [1]
          and d3.get("recording_parts") == 1 and get_raw(PART0, "dev", W)[0] == 404, d3.get("recording"))
    sql("UPDATE ar_terminal_tabs SET updated_at = NOW() - interval '13 hours' WHERE tab_id = 'tab0a'")
    subprocess.run(shlex.split(EXEC) + [
        "package.path = '/app/projects/ai-runner/?.lua;' .. package.path; require('ai_runner.worklog').sweep()"],
        capture_output=True, text=True)
    lost = expect("the tab after 13 hours without news", call("GET", P + f"/work-log/tabs/{a.get('uuid')}", "dev", W), 200)
    check("a tab the terminal stopped reporting is closed", lost.get("open") is False
          and lost.get("end_reason") == "the terminal stopped reporting", lost.get("end_reason"))
    alive = json.dumps({"terminal": TERM["uuid"], "tabs": [dict(tabs[0], active_secs=480)], "events": []}).encode()
    expect("the terminal reports it open again", signed(ACT, alive), 200)
    back = expect("the tab again", call("GET", P + f"/work-log/tabs/{a.get('uuid')}", "dev", W), 200)
    check("…and it reopens", back.get("open") is True and back.get("end_reason") is None
          and back.get("active_secs") == 480, (back.get("open"), back.get("end_reason")))

# --- Switch off, delete -------------------------------------------------------------------------------------
expect("switch the terminal off", call("PUT", P + f"/terminals/{TERM['uuid']}", "mgr", W, {"is_active": False}), 200)
check("a switched-off terminal gets no keys", live_keys() == [], live_keys())
pv4 = expect("preview with it off", call("POST", P + f"/tasks/{T1['uuid']}/runs/preview", "dev", W, {}), 200)
check("not offered, no terminal prompt", pv4.get("terminals") == [] and pv4.get("terminal_prompt") is None, pv4)
expect("can't launch on it", call("POST", L, "dev", W, good), 404)
expect("delete it", call("DELETE", P + f"/terminals/{TERM['uuid']}", "mgr", W), 200)
listed = expect("sessions after delete", call("GET", L, "dev", W), 200)
check("its sessions stay on the task", len(listed) == 6 and all(s["terminal_name"] is None for s in listed), listed)
expect("webhook for a deleted terminal's launch", webhook(dict(ev2, ts=int(time.time())), NEW), 404)
check("its work log stays", "tab0a" in [r["tab_id"] for r in page("owner_a", W, "?per_page=50")[1]])

for MIG, table in (("20261023120000_ai_runner_web_terminals", "ar_terminals"),
                   ("20261024120000_ai_runner_terminal_autologin", "ar_terminal_stepups"),
                   ("20261026120000_ai_runner_terminal_keys", "ar_terminal_keys"),
                   ("20261026130000_ai_runner_work_log", "ar_terminal_tabs"),
                   ("20261028120000_ai_runner_terminal_contact", "ar_terminals")):
    if not MIGRATE:
        break
    sql(f"DELETE FROM project_migrations WHERE project_code = 'ai_runner' AND migration_name = '{MIG}'")
    out = subprocess.run(shlex.split(MIGRATE), capture_output=True, text=True)
    check(f"{MIG} re-runs idempotently", out.returncode == 0
          and f"{MIG}: running" in (out.stdout + out.stderr)
          and one(f"SELECT to_regclass('{table}')") == table, (out.stdout + out.stderr)[-400:])

print()
print("FAILED: %d" % failures if failures else "ALL PASSED")
raise SystemExit(1 if failures else 0)
