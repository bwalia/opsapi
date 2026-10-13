"""AI Runs: the built-in runner (docs/AI_RUNNER.md §28.6), end to end against a sandbox OpsAPI and mock_ai_github.py.

Run by run.sh (AR_API, AR_MOCK, AR_JWT_SECRET, AR_PSQL). Standard library only (plus the openssl CLI to make the
GitHub App key and check the app JWT's signature). Covers: the built-in runner appears in every workspace, always
online, the platform model as its profile and the default when no machine is online; a plan-only run (task tools,
subtask, comments, turns, usage); the platform's GitHub App settings (platform admin only, secrets sealed and never
returned, key checked); connecting an installation (OAuth-proved, state bound to the workspace and person, someone
else's installation refused); a code run (scoped installation token, RS256 app JWT, reads, a commit on the run's own
branch, secret and workflow files refused, the pull request, main untouched); needs_input and the answer; a follow-up;
cancel; the step limit; a model failure; the per-workspace limit; pause, access, no token, no revoke; isolation.
"""
import base64
import hashlib
import hmac
import json
import os
import shlex
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid as uuidlib

API, MOCK = os.environ["AR_API"], os.environ["AR_MOCK"]
SECRET, PSQL = os.environ["AR_JWT_SECRET"], os.environ["AR_PSQL"]
P = API + "/api/v2/ai-runner"
TAG = uuidlib.uuid4().hex[:6]
USERS = {
    "owner_a": ("a1111111-0000-4000-8000-000000000001", "owner.a@ar.invalid"),
    "owner_b": ("b2222222-0000-4000-8000-000000000002", "owner.b@ar.invalid"),
    "dev": ("c3333333-0000-4000-8000-000000000003", "dev.a@ar.invalid"),
    "mgr": ("e5555555-0000-4000-8000-000000000005", "mgr.a@ar.invalid"),
    "platform": ("a7777777-0000-4000-8000-000000000007", "platform.admin@ar.invalid"),
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


def call(method, url, user=None, ns=None, body=None):
    h = {"Content-Type": "application/json"}
    if user:
        h["Authorization"] = "Bearer " + jwt(user)
    if ns:
        h["X-Namespace-Id"] = ns
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
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


def mock():
    with urllib.request.urlopen(MOCK + "/_log", timeout=10) as r:
        return json.loads(r.read())


def wait_for(name, fn, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(1)
    check(name, False, "timed out")
    return None


def workspace(owner, name, slug):
    res = call("POST", API + "/api/v2/user/namespaces", owner, body={"name": name, "slug": slug})
    if res[0] == 429:
        time.sleep(int((res[1] or {}).get("retry_after") or 60) + 1)
        res = call("POST", API + "/api/v2/user/namespaces", owner, body={"name": name, "slug": slug})
    body = expect(f"{owner} creates workspace {name}", res, 201)
    ns = body.get("namespace", body)
    return str(ns.get("uuid") or ns.get("id"))


def run_of(uuid):
    return call("GET", P + f"/runs/{uuid}", "mgr", W)[1]["data"]


def wait_status(name, uuid, statuses, timeout=60):
    return wait_for(name, lambda: (lambda r: r if r["status"] in statuses else None)(run_of(uuid)), timeout)


def platform(body, status=200, user="platform"):
    return expect("platform settings " + ",".join(body), call("PUT", P + "/platform/settings", user, body=body), status)


# --- Workspaces, roles, tasks -------------------------------------------------------------------------------
W = workspace("owner_a", "AR Built-in " + TAG, "ar-builtin-" + TAG)
X = workspace("owner_b", "AR Built-in other " + TAG, "ar-builtin-x-" + TAG)
for owner, ns in (("owner_a", W), ("owner_b", X)):
    expect(f"{owner} enables AI Runs", call("PUT", API + "/api/v2/namespace/plugins/ai_runner", owner, ns,
                                            {"enabled": True}), 200)
roles = {}
for name, perms in (("bi_dev_" + TAG, {"ai_runs": ["read", "create"]}),
                    ("bi_mgr_" + TAG, {"ai_runs": ["manage"], "ai_runners": ["manage"],
                                       "ai_runs_settings": ["manage"]})):
    body = expect(f"create role {name}", call("POST", API + "/api/v2/namespace/roles", "owner_a", W,
                                              {"role_name": name, "display_name": name, "permissions": perms}), 201)
    roles[name.split("_" + TAG)[0]] = body.get("role", body)["id"]
for user, role in (("dev", "bi_dev"), ("mgr", "bi_mgr")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_a", W,
                                         {"email": USERS[user][1], "role_ids": [roles[role]]}), 201)
proj = expect("create project", call("POST", API + "/api/v2/kanban/projects", "owner_a", W, {"name": "Web " + TAG}),
              201)
BOARD = one(f"SELECT b.uuid FROM kanban_boards b JOIN kanban_projects p ON p.id = b.project_id "
            f"WHERE p.uuid = '{proj['uuid']}' ORDER BY b.id LIMIT 1")
expect("dev joins the project", call("POST", API + f"/api/v2/kanban/projects/{proj['uuid']}/members", "owner_a", W,
                                     {"user_uuid": USERS["dev"][0], "role": "member"}), 201)


def task(title):
    t = expect(f"task {title}", call("POST", API + f"/api/v2/kanban/boards/{BOARD}/tasks", "owner_a", W,
                                     {"title": title, "priority": "medium", "description": "Do it well."}), 201)
    expect(f"assign {title}", call("POST", API + f"/api/v2/kanban/tasks/{t['uuid']}/assignees", "owner_a", W,
                                   {"user_uuid": USERS["dev"][0]}), 201)
    return t


# --- The built-in runner: always there, the default when no machine is online -------------------------------
runners = expect("dev lists runners", call("GET", P + "/runners", "dev", W), 200)
bi = next((r for r in runners if r.get("kind") == "builtin"), None)
check("every workspace has a built-in runner, online, open to everyone who may start runs",
      bi and bi["status"] == "online" and bi["name"] == "OpsAPI built-in", runners)
BI = bi["uuid"]
plat = next((p for p in bi["capabilities"]["profiles"] if p["key"] == "platform"), None)
check("its profile is the platform model (Ollama, mock-qwen), available", plat and plat["available"] is True
      and "mock-qwen" in plat["label"] and plat["models"] == ["mock-qwen"], bi["capabilities"])
check("with GitHub not set up it offers only 'none' (no repository)", [r["path"] for r in bi["repos"]] == ["none"],
      bi["repos"])
check("one built-in runner per workspace, whoever asks",
      one(f"SELECT COUNT(*) FROM ar_runners r JOIN namespaces n ON n.id = r.namespace_id "
          f"WHERE n.uuid = '{W}' AND r.kind = 'builtin'") == "1")
mac = expect("manager registers a machine runner too", call("POST", P + "/runners", "mgr", W, {"name": "mac"}), 201)
expect("open to everyone", call("PUT", P + f"/runners/{mac['runner']['uuid']}/access", "mgr", W, {"mode": "everyone"}),
       200)

T_PLAN = task("[plan] Plan the billing work")
pv = expect("preview a task", call("POST", P + f"/tasks/{T_PLAN['uuid']}/runs/preview", "dev", W, {}), 200)
check("no machine is online: the preview picks the built-in runner and 'none'",
      pv["runner_uuid"] == BI and pv["repo_path"] == "none", {k: pv.get(k) for k in ("runner_uuid", "repo_path")})
check("the prompt says there is no repository and what happens to the work",
      "no repository" in pv["prompt"] and "add_comment" in pv["prompt"], pv["prompt"][:600])
check("the built-in runner is listed after the machines", [r["kind"] for r in pv["runners"]] == ["runner", "builtin"],
      [r["kind"] for r in pv["runners"]])


def start(t, repo="none", user="dev", status=201, **extra):
    return expect(f"start {t['title']} on {repo}", call("POST", P + f"/tasks/{t['uuid']}/runs", user, W,
                                                        dict({"runner_uuid": BI, "profile": "platform",
                                                              "repo_path": repo, "confirm_similar": True}, **extra)),
                  status)


expect("an unknown repository is refused (422)", call("POST", P + f"/tasks/{T_PLAN['uuid']}/runs", "dev", W,
       {"runner_uuid": BI, "profile": "platform", "repo_path": "/Users/me/web"}), 422)
r = start(T_PLAN)
done = wait_status("the plan run finishes", r["uuid"], ("succeeded", "failed"))
check("the plan run succeeded with the model's summary", done and done["status"] == "succeeded"
      and done["summary"] == "Planned it: one subtask and a comment.", done)
check("no folder lock for a built-in run", one(f"SELECT COUNT(*) FROM ar_locks WHERE run_uuid = '{r['uuid']}'") == "0")
check("the subtask was added under the task",
      one(f"SELECT s.title FROM kanban_tasks s JOIN kanban_tasks p ON p.id = s.parent_task_id "
          f"WHERE p.uuid = '{T_PLAN['uuid']}'") == "Write the migration")
comments = sql(f"SELECT c.content FROM kanban_task_comments c JOIN kanban_tasks t ON t.id = c.task_id "
               f"WHERE t.uuid = '{T_PLAN['uuid']}' ORDER BY c.id")
check("its comment and its summary are on the task, as the requester",
      "[AI run] Plan: 1) migration 2) API" in comments
      and "[AI run] Planned it: one subtask and a comment." in comments, comments)
check("the conversation has the final turn and the usage", len(done["turns"]) == 1
      and done["turns"][0]["text"] == "Planned it: one subtask and a comment." and done["turns"][0]["num_turns"] == 4
      and done["usage"]["tokens_in"] == 400 and done["usage"]["tokens_out"] == 80, done["turns"])
check("every model call is metered as agent_run for the requester",
      one(f"SELECT COUNT(*) FROM ai_usage WHERE run_uuid = '{r['uuid']}' AND feature = 'agent_run' "
          f"AND user_uuid = '{USERS['dev'][0]}' AND model = 'mock-qwen'") == "4")
check("the log shows each tool", [e["text"] for e in done["events"] if e["type"] == "tool"][:3]
      == ["get_task", "add_subtask Write the migration", "add_comment Plan: 1) migration 2) API"], done["events"])
chats = [c for c in mock()["chats"] if c["scenario"] == "plan"]
check("without a repository the agent gets only the task tools",
      chats and chats[0]["tools"] == ["get_task", "add_comment", "add_subtask"], chats[:1])

# --- Platform settings: the GitHub App -----------------------------------------------------------------------
KEYDIR = tempfile.mkdtemp()
subprocess.run(["openssl", "genrsa", "-out", KEYDIR + "/app.pem", "2048"], check=True, capture_output=True)
subprocess.run(["openssl", "rsa", "-in", KEYDIR + "/app.pem", "-pubout", "-out", KEYDIR + "/pub.pem"], check=True,
               capture_output=True)
PEM = open(KEYDIR + "/app.pem").read()
GH = {"api_url": "http://ar-mock:8080/gh", "web_url": "http://ar-mock:8080/ghweb", "app_id": "4242",
      "app_slug": "opsapi-ai-runs", "client_id": "Iv1.mockclient", "client_secret": "mocksecret0123456789",
      "private_key": PEM}
expect("a workspace owner can't change the platform settings", call("PUT", P + "/platform/settings", "owner_a",
                                                                    body={"github": GH}), 403)
platform({"github": dict(GH, private_key="not a key")}, 422)
platform({"github": dict(GH, private_key=open(KEYDIR + "/pub.pem").read())}, 422)
platform({"github": dict(GH, api_url="ftp://x")}, 422)
v = platform({"github": GH, "dashboard_url": "https://dash.example.invalid"})
check("the view says the secrets are set, never what they are", v["github"]["configured"] is True
      and v["github"]["has_private_key"] and v["github"]["has_client_secret"] and "BEGIN" not in json.dumps(v)
      and GH["client_secret"] not in json.dumps(v), v["github"])
check("it shows the callback URL to give GitHub", v["github"]["callback_url"]
      == "https://dash.example.invalid/dashboard/ai-runner/github", v["github"])
stored = one("SELECT settings::text FROM ar_platform_settings")
check("stored sealed", "BEGIN" not in stored and GH["client_secret"] not in stored and "gcm1:" in stored)
v = platform({"github": {"app_slug": "opsapi-ai-runs"}})
check("a partial save keeps the secrets", v["github"]["configured"] is True, v["github"])

# --- Connecting an installation ------------------------------------------------------------------------------
g = expect("dev sees the GitHub status", call("GET", P + "/github", "dev", W), 200)
check("dev sees it but no install link", g["configured"] and g["install_url"] is None and g["installations"] == [], g)
g = expect("manager sees the install link", call("GET", P + "/github", "mgr", W), 200)
check("install link is the App's", g["install_url"] == "http://ar-mock:8080/ghweb/apps/opsapi-ai-runs/installations/new",
      g)
expect("dev can't start a connection", call("POST", P + "/github/authorize", "dev", W, {"installation_id": 1001}), 403)
a = expect("manager starts connecting installation 1001", call("POST", P + "/github/authorize", "mgr", W,
                                                               {"installation_id": 1001}), 200)
check("the sign-in URL comes back to the dashboard", a["url"].startswith(
    "http://ar-mock:8080/ghweb/login/oauth/authorize?client_id=Iv1.mockclient&redirect_uri="
    "https%3A%2F%2Fdash.example.invalid%2Fdashboard%2Fai-runner%2Fgithub&state="), a)
STATE = urllib.parse.unquote(a["url"].split("state=")[1]) if "state=" in a["url"] else ""
expect("a changed state is refused", call("POST", P + "/github/installations", "mgr", W,
                                          {"code": "ok-1001", "state": STATE[:-2] + "xx"}), 400)
expect("someone else can't finish it", call("POST", P + "/github/installations", "owner_a", W,
                                            {"code": "ok-1001", "state": STATE}), 400)
expect("nor in another workspace", call("POST", P + "/github/installations", "owner_b", X,
                                        {"code": "ok-1001", "state": STATE}), 400)
expect("a bad code is refused", call("POST", P + "/github/installations", "mgr", W,
                                     {"code": "bad", "state": STATE}), 403)
a2 = expect("start connecting someone else's installation 2002", call("POST", P + "/github/authorize", "mgr", W,
                                                                      {"installation_id": 2002}), 200)
expect("GitHub says this person can't reach 2002: refused", call("POST", P + "/github/installations", "mgr", W, {
    "code": "ok-1001", "state": urllib.parse.unquote(a2["url"].split("state=")[1])}), 403)
inst = expect("connect 1001", call("POST", P + "/github/installations", "mgr", W, {"code": "ok-1001", "state": STATE}),
              201)
check("it is acme's", inst["account_login"] == "acme" and inst["installation_id"] == 1001, inst)
check("GitHub was asked with the same redirect_uri", mock()["oauth"][-1]["redirect_uri"]
      == "https://dash.example.invalid/dashboard/ai-runner/github")
bi = next(r for r in expect("runners now", call("GET", P + "/runners?refresh=1", "dev", W), 200)
          if r["kind"] == "builtin")
check("the built-in runner offers acme's repositories, not other's",
      [r["path"] for r in bi["repos"]] == ["none", "github:acme/web", "github:acme/api"], bi["repos"])
check("the other workspace has no installations", expect("X github", call("GET", P + "/github", "owner_b", X), 200)
      ["installations"] == [])
jwt0 = mock()["jwts"][-1]
h, p_, s_ = jwt0.split(".")
open(KEYDIR + "/data", "w").write(h + "." + p_)
open(KEYDIR + "/sig", "wb").write(base64.urlsafe_b64decode(s_ + "=" * (-len(s_) % 4)))
ver = subprocess.run(["openssl", "dgst", "-sha256", "-verify", KEYDIR + "/pub.pem", "-signature", KEYDIR + "/sig",
                      KEYDIR + "/data"], capture_output=True, text=True)
check("the app JWT is RS256-signed with the App's key", ver.returncode == 0, ver.stdout + ver.stderr)

# --- A code run: read, commit to its own branch, open the pull request ----------------------------------------
T_CODE = task("[code] Add a greeting")
pv = expect("preview the code task on acme/web", call("POST", P + f"/tasks/{T_CODE['uuid']}/runs/preview", "dev", W,
                                                     {"runner_uuid": BI, "repo_path": "github:acme/web"}), 200)
check("the prompt names the repository and the branch", "the GitHub repository acme/web" in pv["prompt"]
      and pv["work_branch"] in pv["prompt"], pv["prompt"][:500])
start(T_CODE, "github:other/secret", status=422)
r = start(T_CODE, "github:acme/web")
done = wait_status("the code run finishes", r["uuid"], ("succeeded", "failed"))
check("it succeeded with a pull request, the commit and the branch", done and done["status"] == "succeeded"
      and done["pr_url"] == "https://github.example/acme/web/pull/1" and done["commit_sha"].startswith("c-acme-web-")
      and done["work_branch"] == pv["work_branch"], done)
log = mock()
web = log["state"]["acme/web"]
check("the change is on the run's branch only; main is untouched",
      web[pv["work_branch"]]["README.md"] == "# Web\n\nHello from the agent\n" and web["main"]["README.md"] == "# Web\n",
      web)
check("secret and workflow files were refused, not written",
      web[pv["work_branch"]][".env"] == "KEY=x\n" and ".github/workflows/x.yml" not in web[pv["work_branch"]])
tools = [e["text"] for e in done["events"] if e["type"] == "tool"]
check("the log says why each was refused", any(t.startswith("write_file .env — secret files") for t in tools)
      and any("workflow files are off limits" in t for t in tools) and any("may not contain" in t for t in tools)
      and any(t.startswith("read_file .env — secret files") for t in tools), tools)
commits = [c for c in log["github"] if c["method"] == "COMMIT"]
check("one commit, on the run's branch, naming the run", len(commits) == 1
      and commits[0]["path"] == f"acme/web:{pv['work_branch']}:README.md" and r["uuid"] in commits[0]["message"],
      commits)
pr = log["pulls"][f"acme/web:{pv['work_branch']}"]
check("the pull request is a draft to main with the summary and the task link", pr["draft"] is True
      and pr["base"] == "main" and "Added a greeting to README.md." in pr["body"]
      and T_CODE["uuid"] in pr["body"] and pr["title"].endswith("[code] Add a greeting"), pr)
repo_calls = [c for c in log["github"] if c["path"].startswith("/repos/acme/web")]
check("the run's GitHub token was scoped to acme/web alone", repo_calls
      and all(c["scope"] == ["acme/web"] for c in repo_calls), repo_calls[:3])
check("the repo tools were offered", "write_file" in next(c for c in log["chats"] if c["scenario"] == "code")["tools"])
comments = sql(f"SELECT replace(c.content, chr(10), ' ') FROM kanban_task_comments c "
               f"JOIN kanban_tasks t ON t.id = c.task_id WHERE t.uuid = '{T_CODE['uuid']}' ORDER BY c.id DESC LIMIT 1")
check("the summary and the pull request are on the task", comments and "Pull request: https://github.example/acme/web/pull/1"
      in comments[0], comments)
r2 = expect("retry the code run", call("POST", P + f"/runs/{r['uuid']}/retry", "dev", W, {}), 201)
done2 = wait_status("the retry finishes", r2["uuid"], ("succeeded", "failed"))
check("a retry carries on with the same branch and finds the open pull request", done2
      and done2["status"] == "succeeded" and done2["pr_url"] == done["pr_url"]
      and any("Carrying on with the existing branch" in (e["text"] or "") for e in done2["events"]), done2)

# --- needs_input, follow-ups, cancel, limits, failures ---------------------------------------------------------
T_ASK = task("[ask] Paint the button")
r = start(T_ASK)
q = wait_status("the agent asks", r["uuid"], ("needs_input",))
check("the question is on the run", q and q["question"] == "Which colour should the button be?", q)
expect("the requester answers", call("POST", P + f"/runs/{r['uuid']}/turns", "dev", W, {"text": "Make it blue"}), 201)
done = wait_status("then it finishes", r["uuid"], ("succeeded", "failed"))
check("with the answer", done and done["summary"] == "Painted the button blue." and len(done["turns"]) == 3, done)

T_FU = task("[followup] Listen")
r = start(T_FU)
wait_status("the follow-up run works", r["uuid"], ("running",))
expect("send a follow-up while it works", call("POST", P + f"/runs/{r['uuid']}/turns", "dev", W,
                                               {"text": "Use British spelling"}), 201)
done = wait_status("it finishes", r["uuid"], ("succeeded", "failed"))
check("the agent got the follow-up", done and done["summary"] == "Got your note: Use British spelling", done)

T_SLOW = task("[slow] Long job")
T_WAIT = task("[plan] Waits its turn")
r = start(T_SLOW)
wait_status("the slow run works", r["uuid"], ("running",))
w2 = start(T_WAIT)
time.sleep(4)
check("one built-in run at a time per workspace (platform default): the next one waits",
      run_of(w2["uuid"])["status"] == "queued")
expect("cancel the slow run", call("POST", P + f"/runs/{r['uuid']}/cancel", "dev", W, {}), 200)
c = wait_status("it stops", r["uuid"], ("cancelled", "failed", "succeeded"))
check("cancelled", c and c["status"] == "cancelled", c)
done = wait_status("then the waiting one runs", w2["uuid"], ("succeeded", "failed"))
check("and succeeds", done and done["status"] == "succeeded", done)

platform({"builtin_max_steps": 5})
r = start(task("[loop] Never ends"))
done = wait_status("a run that never finishes", r["uuid"], ("succeeded", "failed"))
check("stops at the platform's step limit", done and done["status"] == "failed"
      and done["error_category"] == "step_limit" and "5 steps" in done["error"], done)
platform({"builtin_max_steps": None})
r = start(task("[fail] Model breaks"))
done = wait_status("a run whose model fails", r["uuid"], ("succeeded", "failed"))
check("fails as model_error", done and done["status"] == "failed" and done["error_category"] == "model_error", done)

# --- Managing the built-in runner ------------------------------------------------------------------------------
expect("it has no token to rotate", call("POST", P + f"/runners/{BI}/rotate-token", "mgr", W), 409)
expect("it can't be revoked", call("DELETE", P + f"/runners/{BI}", "mgr", W), 409)
expect("it stays built-in", call("PUT", P + f"/runners/{BI}", "mgr", W, {"kind": "runner"}), 422)
expect("pause it", call("POST", P + f"/runners/{BI}/pause", "mgr", W), 200)
T_P = task("[plan] While paused")
expect("a paused built-in runner takes no runs", call("POST", P + f"/tasks/{T_P['uuid']}/runs", "dev", W,
       {"runner_uuid": BI, "profile": "platform", "repo_path": "none"}), 409)
expect("resume it", call("POST", P + f"/runners/{BI}/resume", "mgr", W), 200)
expect("limit it to its managers", call("PUT", P + f"/runners/{BI}/access", "mgr", W, {"mode": "owner"}), 200)
expect("then dev can't use it", call("POST", P + f"/tasks/{T_P['uuid']}/runs", "dev", W,
       {"runner_uuid": BI, "profile": "platform", "repo_path": "none"}), 403)
expect("open it again", call("PUT", P + f"/runners/{BI}/access", "mgr", W, {"mode": "everyone"}), 200)
other = next(r for r in expect("X runners", call("GET", P + "/runners", "owner_b", X), 200) if r["kind"] == "builtin")
check("the other workspace has its own built-in runner", other["uuid"] != BI)
xp = expect("X project", call("POST", API + "/api/v2/kanban/projects", "owner_b", X, {"name": "X " + TAG}), 201)
xb = one(f"SELECT b.uuid FROM kanban_boards b JOIN kanban_projects p ON p.id = b.project_id "
         f"WHERE p.uuid = '{xp['uuid']}' ORDER BY b.id LIMIT 1")
xt = expect("X task", call("POST", API + f"/api/v2/kanban/boards/{xb}/tasks", "owner_b", X, {"title": "[plan] X"}), 201)
expect("W's built-in runner is not X's to use", call("POST", P + f"/tasks/{xt['uuid']}/runs", "owner_b", X,
       {"runner_uuid": BI, "profile": "platform", "repo_path": "none"}), 422)
g = expect("disconnect acme", call("DELETE", P + f"/github/installations/{inst['uuid']}", "mgr", W), 200)
bi = next(r for r in expect("runners", call("GET", P + "/runners", "dev", W), 200) if r["kind"] == "builtin")
check("its repositories are gone", [r["path"] for r in bi["repos"]] == ["none"], bi["repos"])
platform({"github": None})

print(f"\n{'FAILED: ' + str(failures) if failures else 'All built-in runner checks passed'}")
raise SystemExit(1 if failures else 0)
