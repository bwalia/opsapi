"""The real PromptPilot runner against this sandbox (docs/AI_RUNNER.md §22).

Run by run.sh when PROMPTPILOT_BIN points at a built `promptpilot` binary (bwalia/promptpilot, branch with runner
mode) and PROMPTPILOT_DIR at its source folder (for scripts/fake-agent.sh). Sets up a workspace, a task and a
runner through the API, makes a real git repo with a bare `origin`, starts `promptpilot runner`, then:
  1. a run with the fake agent goes queued → succeeded: new branch, commit pushed to origin, folder back on main;
  2. a slow run is cancelled from OpsAPI and the runner stops it;
  3. the runner's sessions and repos show up for the dashboard's folder picker.
"""
import base64, hashlib, hmac, json, os, shutil, subprocess, sys, tempfile, time, urllib.error, urllib.request

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
