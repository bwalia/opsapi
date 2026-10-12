"""The real PromptPilot runner against this sandbox (docs/AI_RUNNER.md §22).

Run by run.sh when PROMPTPILOT_BIN points at a built `promptpilot` binary (bwalia/promptpilot, branch with runner
mode) and PROMPTPILOT_DIR at its source folder (for scripts/fake-agent.sh). Sets up a workspace, a task and a
runner through the API, makes a real git repo with a bare `origin`, starts `promptpilot runner`, then:
  1. a run with the fake agent goes queued → succeeded: new branch, commit pushed to origin, folder back on main;
  2. a slow run is cancelled from OpsAPI and the runner stops it;
  3. the runner's sessions and repos show up for the dashboard's folder picker;
  4. (Phase 3, §23.6) with `promptpilot fake-agent` speaking Claude's stdio protocol: a permission allowed and one
     denied from OpsAPI, a safety-list command denied by the runner without asking, NEEDS_INPUT answered and a
     follow-up delivered through the user API, the run's MCP tools (get_task, add_comment), a start that needs a
     manager's approval, and usage on the run and in ai_usage.
"""
import base64, hashlib, hmac, json, os, shlex, shutil, subprocess, sys, tempfile, time, urllib.error, urllib.request

API, SECRET = os.environ["AR_API"], os.environ["AR_JWT_SECRET"]
BIN, PPDIR = os.environ["PROMPTPILOT_BIN"], os.environ["PROMPTPILOT_DIR"]
P = API + "/api/v2/ai-runner"
OWNER = ("a1111111-0000-4000-8000-000000000001", "owner.a@ar.invalid")
failures = 0


def jwt(user):
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
    h, p = b({"typ": "JWT", "alg": "HS256"}), b({"userinfo": {"uuid": user[0], "email": user[1]},
                                                  "iat": int(time.time()), "exp": int(time.time()) + 3600,
                                                  "iss": "opsapi"})
    sig = base64.urlsafe_b64encode(hmac.new(SECRET.encode(), h + b"." + p, hashlib.sha256).digest()).rstrip(b"=")
    return (h + b"." + p + b"." + sig).decode()


def call(method, url, ns=None, body=None):
    h = {"Content-Type": "application/json", "Authorization": "Bearer " + jwt(OWNER)}
    if ns:
        h["X-Namespace-Id"] = ns
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw.decode(errors="replace")


def data(res):
    body = res[1] if isinstance(res[1], dict) else {}
    return body.get("data", body)


def check(name, cond, detail=None):
    global failures
    print(("ok    " if cond else "FAIL  ") + name + ("" if cond or detail is None else "  -> " + str(detail)[:600]))
    failures += 0 if cond else 1
    return cond


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def wait_for(what, fn, timeout=60, every=1):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(every)
    check(what + " (timed out)", False)
    return None


# --- Workspace, task, runner (through the API) ---------------------------------------------------------------
slug = "pp-" + str(int(time.time()))
res = call("POST", API + "/api/v2/user/namespaces", body={"name": "PromptPilot E2E", "slug": slug})
NS = str((data(res).get("namespace") or data(res)).get("uuid"))
check("workspace created", res[0] == 201, res)
check("ai_runner switched on", call("PUT", API + "/api/v2/namespace/plugins/ai_runner", NS, {"enabled": True})[0] == 200)
check("output mode: push the branch", call("PUT", P + "/settings", NS, {"output_mode": "branch"})[0] == 200)
proj = data(call("POST", API + "/api/v2/kanban/projects", NS, {"name": "Runner repo"}))
board = data(call("GET", API + f"/api/v2/kanban/projects/{proj['uuid']}/boards", NS))
board = board[0] if isinstance(board, list) else (board.get("boards") or board.get("data"))[0]


def task(title):
    t = data(call("POST", API + f"/api/v2/kanban/boards/{board['uuid']}/tasks", NS, {"title": title}))
    call("POST", API + f"/api/v2/kanban/tasks/{t['uuid']}/assignees", NS, {"user_uuid": OWNER[0]})
    return t


t1, t2 = task("Write the release notes"), task("A slow refactor")
reg = data(call("POST", P + "/runners", NS, {"name": "local-mac"}))
TOKEN = reg.get("token", "")
check("runner registered, token shown once", TOKEN.startswith("oprn_"), reg)

# --- A real git repo with a bare origin, and the runner ----------------------------------------------------
tmp = tempfile.mkdtemp(prefix="pp-e2e-")
root, origin = os.path.join(tmp, "projects"), os.path.join(tmp, "origin.git")
repo = os.path.join(root, "website")
os.makedirs(root)
subprocess.run(["git", "init", "-q", "--bare", "-b", "main", origin], check=True)
subprocess.run(["git", "clone", "-q", origin, repo], check=True, capture_output=True)
for k, v in (("user.email", "runner@e2e.invalid"), ("user.name", "E2E Runner")):
    git("config", k, v, cwd=repo)
with open(os.path.join(repo, "README.md"), "w") as f:
    f.write("# website\n")
git("add", ".", cwd=repo)
git("commit", "-qm", "init", cwd=repo)
git("push", "-q", "-u", "origin", "main", cwd=repo)

token_file = os.path.join(tmp, "runner.token")
with open(token_file, "w") as f:
    f.write(TOKEN + "\n")
os.chmod(token_file, 0o600)
fake = os.path.join(PPDIR, "scripts", "fake-agent.sh")
cfg = {
    "registrations": [{"name": "local-mac", "opsapi_url": API, "token_file": token_file, "allowed_roots": [root],
                       "max_concurrency": 1}],
    "profiles": [
        {"key": "fake", "label": "Fake agent", "approval": "none", "models": [],
         "command": [fake, "{{prompt}}", "{{run_uuid}}"], "env": {"FAKE_AGENT_SLEEP": "1"}},
        {"key": "fake-slow", "label": "Fake agent (slow)", "approval": "none", "models": [],
         "command": [fake, "{{prompt}}", "{{run_uuid}}"], "env": {"FAKE_AGENT_SLEEP": "60"}},
        # Phase 3: the Go fake agent speaks Claude's stdio protocol (the runner is its permission host).
        *({"key": key, "label": key, "approval": "bridge", "io": "stream-json", "models": ["fake-model"],
           "command": [BIN, "fake-agent", "--session-id", "{{run_uuid}}", "--model", "{{model}}",
                       "--mcp-config", "{{mcp_config}}"], "env": {"FAKE_AGENT_SCRIPT": script}}
          for key, script in (("p3-perm", "perm:Bash:npm test;perm:Bash:make deploy;edit"),
                              ("p3-safety", "perm:Bash:git push origin main;edit"),
                              ("p3-ask", "ask:Which colour should the button be?;edit"),
                              ("p3-follow", "sleep:6;edit"),
                              ("p3-mcp", "mcp:get_task;mcp:add_comment:Started on it;edit"))),
        {"key": "p3-noask", "label": "Needs approval to start", "approval": "unsupported", "models": [],
         "command": [fake, "{{prompt}}", "{{run_uuid}}"], "env": {"FAKE_AGENT_SLEEP": "1"}},
    ],
    "restore_branch": True,
}
cfg_file = os.path.join(tmp, "runner.json")
with open(cfg_file, "w") as f:
    json.dump(cfg, f)
log = open(os.path.join(tmp, "runner.log"), "w")
proc = subprocess.Popen([BIN, "runner", "-config", cfg_file], stdout=log, stderr=subprocess.STDOUT,
                        env={**os.environ, "LABELS_FILE": os.path.join(tmp, "labels.json")})
try:
    runner = wait_for("runner online with the repo", lambda: next(
        (r for r in (data(call("GET", P + "/runners", NS)) or [])
         if r.get("status") == "online" and any(x.get("path") == os.path.realpath(repo) or x.get("path") == repo
                                                for x in (r.get("repos") or []))), None), timeout=90)
    check("runner reports itself online with its repo for the folder picker", bool(runner), runner)
    profiles = [p.get("key") for p in ((runner or {}).get("capabilities") or {}).get("profiles") or []]
    check("its profiles reach OpsAPI", set(profiles) >= {"fake", "fake-slow"}, profiles)
    folder = next(x["path"] for x in runner["repos"])

    # 1. A run that succeeds
    pv = data(call("POST", P + f"/tasks/{t1['uuid']}/runs/preview", NS,
                   {"runner_uuid": runner["uuid"], "profile": "fake", "repo_path": folder}))
    check("preview renders the prompt with the task", "Write the release notes" in (pv.get("prompt") or ""), pv)
    res = call("POST", P + f"/tasks/{t1['uuid']}/runs", NS,
               {"runner_uuid": runner["uuid"], "profile": "fake", "repo_path": folder})
    run = data(res)
    check("run started (201)", res[0] == 201, res)
    done = wait_for("run 1 finishes", lambda: (lambda r: r if r.get("status") in (
        "succeeded", "failed", "cancelled", "lost") else None)(data(call("GET", P + f"/runs/{run['uuid']}", NS))),
        timeout=120)
    check("run succeeded", (done or {}).get("status") == "succeeded", done)
    branch = (done or {}).get("work_branch") or ""
    check("worked on a new ai/ branch, not main", branch.startswith("ai/") and branch != "main", branch)
    check("commit reported", bool((done or {}).get("commit_sha")), done)
    remote_branches = git("ls-remote", "--heads", origin, cwd=repo)
    check("branch pushed to origin", ("refs/heads/" + branch) in remote_branches, remote_branches)
    check("main on origin untouched", git("rev-parse", "main", cwd=origin) == git("rev-parse", "origin/main",
                                                                                 cwd=repo))
    check("the agent's change is in the pushed commit", "AI_RUN_NOTES.md" in git(
        "show", "--name-only", "--format=", (done or {}).get("commit_sha") or "HEAD", cwd=repo), done)
    check("folder switched back to main", git("rev-parse", "--abbrev-ref", "HEAD", cwd=repo) == "main")
    texts = " ".join((e.get("text") or "") for e in (done or {}).get("events") or [])
    check("the agent's output is in the run log", len((done or {}).get("events") or []) > 0 and texts.strip() != "",
          (done or {}).get("events"))

    # 2. A run cancelled from OpsAPI
    res = call("POST", P + f"/tasks/{t2['uuid']}/runs", NS,
               {"runner_uuid": runner["uuid"], "profile": "fake-slow", "repo_path": folder})
    run2 = data(res)
    check("slow run started (201)", res[0] == 201, res)
    wait_for("slow run is running", lambda: data(call("GET", P + f"/runs/{run2['uuid']}", NS)).get("status")
             == "running", timeout=90)
    check("cancel accepted", call("POST", P + f"/runs/{run2['uuid']}/cancel", NS)[0] == 200)
    end = wait_for("slow run stops", lambda: (lambda r: r if r.get("status") in (
        "cancelled", "failed", "lost") else None)(data(call("GET", P + f"/runs/{run2['uuid']}", NS))), timeout=90)
    check("the runner stopped it: cancelled", (end or {}).get("status") == "cancelled", end)
    check("folder clean and back on main after the cancel",
          git("status", "--porcelain", cwd=repo) == "" and git("rev-parse", "--abbrev-ref", "HEAD", cwd=repo)
          == "main", git("status", "--short", "--branch", cwd=repo))

    # 4. Phase 3 (§23.6): the permission bridge, conversation, run MCP tools, start approval, usage.
    def sql(statement):
        out = subprocess.run(shlex.split(os.environ["AR_PSQL"]) + [statement], capture_output=True, text=True,
                             check=True)
        return [line for line in out.stdout.splitlines() if line]

    def detail(uuid):
        return data(call("GET", P + f"/runs/{uuid}", NS))

    def start3(title, profile):
        t = task(title)
        body = {"runner_uuid": runner["uuid"], "profile": profile, "repo_path": folder}
        if profile != "p3-noask":
            body["model"] = "fake-model"
        res = call("POST", P + f"/tasks/{t['uuid']}/runs", NS, body)
        check(f"{profile}: run created", res[0] == 201, res)
        return t, data(res)

    def finished(uuid, timeout=120):
        return wait_for(f"run {uuid[:8]} ends", lambda: (lambda r: r if r.get("status") in (
            "succeeded", "failed", "cancelled", "lost") else None)(detail(uuid)), timeout=timeout) or {}

    def pending_request(uuid):
        return wait_for("a pending permission request", lambda: next(
            (q for q in detail(uuid).get("requests") or [] if q.get("status") == "pending"), None), timeout=60)

    def has_file(branch, name):
        return name in git("ls-tree", "--name-only", branch, cwd=repo).split()

    if "p3-perm" in profiles:
        # 4a. Allow, then deny — decided in OpsAPI by a manager while the agent waits.
        _, run = start3("Run the tests", "p3-perm")
        q1 = pending_request(run["uuid"])
        check("4a: run waits for permission", detail(run["uuid"]).get("status") == "waiting_permission")
        check("4a: request names the tool and command", q1 and q1.get("tool") == "Bash"
              and "npm test" in json.dumps(q1.get("input")), q1)
        check("4a: allowed", call("POST", P + f"/runs/{run['uuid']}/requests/{q1['uuid']}/decide", NS,
                                  {"decision": "allow"})[0] == 200)
        q2 = wait_for("second request", lambda: next((q for q in detail(run["uuid"]).get("requests") or []
                                                       if q.get("status") == "pending" and q["uuid"] != q1["uuid"]),
                                                      None), timeout=60)
        check("4a: denied", call("POST", P + f"/runs/{run['uuid']}/requests/{q2['uuid']}/decide", NS,
                                 {"decision": "deny", "reason": "Not from an AI run"})[0] == 200)
        end = finished(run["uuid"])
        check("4a: run succeeded", end.get("status") == "succeeded", end)
        br = end.get("work_branch") or ""
        check("4a: the allowed step ran", has_file(br, "fake-perm-bash-npm-test.txt"), br)
        check("4a: the denied step did not", not has_file(br, "fake-perm-bash-make-deploy.txt"), br)
        reqs = {q["status"] for q in end.get("requests") or []}
        check("4a: both decisions recorded", reqs == {"allowed", "denied"}, end.get("requests"))
        u = end.get("usage") or {}
        check("4a: usage on the run", (u.get("tokens_in") or 0) > 0 and (u.get("turns") or 0) >= 1, u)
        rows = sql(f"SELECT feature, input_tokens FROM ai_usage WHERE run_uuid = '{run['uuid']}'")
        check("4a: ai_usage row per turn (feature agent_run)", len(rows) >= 1 and all(r.startswith("agent_run|")
              for r in rows), rows)
        check("4a: folder back on main and clean", git("status", "--porcelain", cwd=repo) == ""
              and git("rev-parse", "--abbrev-ref", "HEAD", cwd=repo) == "main")

        # 4b. The safety list: denied by the runner, nobody is asked.
        _, run = start3("Push it", "p3-safety")
        end = finished(run["uuid"])
        check("4b: run succeeded", end.get("status") == "succeeded", end)
        check("4b: no request reached OpsAPI", not end.get("requests"), end.get("requests"))
        check("4b: the push step did not run", not has_file(end.get("work_branch") or "",
                                                            "fake-perm-bash-git-push-origin-main.txt"))
        check("4b: origin main untouched", git("rev-parse", "main", cwd=origin) == git("rev-parse", "main", cwd=repo))

        # 4c. NEEDS_INPUT: the agent asks, a person answers from OpsAPI, the agent carries on.
        _, run = start3("Pick a colour", "p3-ask")
        asked = wait_for("needs_input", lambda: (lambda r: r if r.get("status") == "needs_input" else None)(
            detail(run["uuid"])), timeout=60) or {}
        check("4c: the question is on the run", "Which colour" in (asked.get("question") or ""), asked)
        check("4c: answer accepted", call("POST", P + f"/runs/{run['uuid']}/turns", NS, {"text": "Blue"})[0] == 201)
        end = finished(run["uuid"])
        check("4c: run succeeded", end.get("status") == "succeeded", end)
        roles = [(t.get("role"), t.get("status")) for t in end.get("turns") or []]
        check("4c: conversation = agent asks, person answers, agent finishes",
              roles[:3] == [("assistant", "delivered"), ("user", "delivered"), ("assistant", "delivered")], roles)
        check("4c: question cleared", not end.get("question"), end.get("question"))

        # 4d. A follow-up sent while the agent works is delivered after its turn.
        _, run = start3("Refactor", "p3-follow")
        wait_for("p3-follow running", lambda: detail(run["uuid"]).get("status") == "running", timeout=60)
        check("4d: follow-up accepted", call("POST", P + f"/runs/{run['uuid']}/turns", NS,
                                            {"text": "Also add a test"})[0] == 201)
        end = finished(run["uuid"])
        check("4d: run succeeded", end.get("status") == "succeeded", end)
        turns = end.get("turns") or []
        # Listed in the order they happened: the person wrote while the agent's first turn was still running.
        users = [t for t in turns if t.get("role") == "user"]
        check("4d: the follow-up was delivered and the agent took a second turn",
              len(users) == 1 and users[0].get("text") == "Also add a test" and users[0].get("status") == "delivered"
              and sum(t.get("role") == "assistant" for t in turns) == 2, turns)

        # 4e. The run's own MCP server: the agent reads its task and comments on it.
        t5, run = start3("Read the task", "p3-mcp")
        end = finished(run["uuid"])
        check("4e: run succeeded", end.get("status") == "succeeded", end)
        comments = sql("SELECT content FROM kanban_task_comments c JOIN kanban_tasks t ON t.id = c.task_id "
                       f"WHERE t.uuid = '{t5['uuid']}'")
        check("4e: the agent commented through run-mcp", any("[AI run] Started on it" in c for c in comments),
              comments)
        log_text = " ".join(e.get("text") or "" for e in end.get("events") or [])
        check("4e: the run token never reaches the log", "oprt_" not in log_text)

        # 4f. A profile that can't ask for permission needs a manager's approval to start.
        _, run = start3("Use the other agent", "p3-noask")
        check("4f: created as pending_approval", run.get("status") == "pending_approval", run)
        time.sleep(3)
        check("4f: no runner takes it before approval", detail(run["uuid"]).get("status") == "pending_approval")
        check("4f: approved", call("POST", P + f"/runs/{run['uuid']}/approve", NS, {})[0] == 200)
        end = finished(run["uuid"])
        check("4f: then it runs and succeeds", end.get("status") == "succeeded" and end.get("approved_by"), end)
    else:
        check("Phase 3 profiles reach OpsAPI (runner too old?)", False, profiles)

    # 3. The machine's sessions are visible to managers
    res = call("GET", P + f"/runners/{runner['uuid']}/sessions", NS)
    check("sessions endpoint answers for the runner", res[0] == 200, res)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
    log.close()
    if failures:
        print("--- runner log (tail) ---")
        print(open(os.path.join(tmp, "runner.log")).read()[-3000:])
    shutil.rmtree(tmp, ignore_errors=True)

print("\nALL PASSED" if failures == 0 else f"\nFAILED: {failures}")
sys.exit(1 if failures else 0)
