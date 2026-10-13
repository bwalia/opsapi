"""Demo data for AI Runs on a LOCAL stack (docs/AI_RUNNER.md), made through the real API.

Creates a workspace "AI Runs demo" owned by you, two teammates, two projects with tasks, three runners (online,
paused, offline) with the machine's sessions, and runs in every state: finished ones (succeeded, failed, cancelled,
lost) with readable logs, conversations, permission decisions and usage spread over the last week; live ones
(running, waiting for permission, needs input); and a Cursor run waiting for a manager's approval.

Then it plays the demo machine ("mac-studio") so the live runs stay live and react to the dashboard: Allow / Deny a
request, answer the agent, message it, cancel a run, approve the Cursor run (it then runs and succeeds).

  python3 projects/ai-runner/spec/seed_demo.py --email you@example.com          # seed, then play the machine (Ctrl+C)
  python3 projects/ai-runner/spec/seed_demo.py --email you@example.com --once   # seed only (live runs go "lost")
  python3 projects/ai-runner/spec/seed_demo.py --keepalive                      # play the last seeded machine again

Local development only: it signs sessions with the API's JWT secret, read from the `opsapi` container (or
OPSAPI_JWT_SECRET), and edits timestamps in the database so the history spans a week.
"""
import argparse, base64, hashlib, hmac, json, os, random, secrets, subprocess, sys, time, urllib.error, urllib.request

STATE = os.path.expanduser("~/.cache/ai-runs-demo.json")
TEAM = [("Priya", "Patel", "priya.patel@example.com"), ("Tom", "Baker", "tom.baker@example.com")]
ROOT = "/Users/studio/projects"
REPOS = ["website", "api", "mobile-app", "docs", "design-system", "infra"]
MODEL = "claude-sonnet-5"


# --- plumbing -------------------------------------------------------------------------------------------------
def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()


def secret():
    return os.environ.get("OPSAPI_JWT_SECRET") or sh("docker", "exec", "opsapi", "printenv", "JWT_SECRET_KEY")


def sql(statement):
    """Run SQL in the local opsapi database (through the opsapi container's own connection settings)."""
    return sh("docker", "exec", "-i", "opsapi", "sh", "-c",
              'PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" '
              '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAq -v ON_ERROR_STOP=1 -c "$0"', statement)


def lit(s):
    return "'" + str(s).replace("'", "''") + "'"


def jwt(user, key):
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
    now = int(time.time())
    info = {"uuid": user["uuid"], "email": user["email"], "first_name": user["first_name"],
            "last_name": user["last_name"], "name": user["first_name"] + " " + user["last_name"]}
    h, p = b({"typ": "JWT", "alg": "HS256"}), b({"userinfo": info, "iat": now, "exp": now + 12 * 3600, "iss": "opsapi"})
    return (h + b"." + p + b"." + base64.urlsafe_b64encode(hmac.new(key.encode(), h + b"." + p,
                                                                     hashlib.sha256).digest()).rstrip(b"=")).decode()


class Api:
    def __init__(self, base):
        self.base = base.rstrip("/")

    def call(self, method, path, body=None, token=None, ns=None, ok=(200, 201, 204)):
        h = {"Content-Type": "application/json"}
        if token:
            h["Authorization"] = "Bearer " + token
        if ns:
            h["X-Namespace-Id"] = ns
        req = urllib.request.Request(self.base + path, method=method, headers=h,
                                     data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw, status = r.read(), r.status
        except urllib.error.HTTPError as e:
            raw, status = e.read(), e.code
        data = json.loads(raw) if raw else {}
        if status not in ok:
            raise SystemExit(f"{method} {path} -> {status}: {str(data)[:300]}")
        return data.get("data", data) if isinstance(data, dict) else data


# --- the demo machine (runner API) ------------------------------------------------------------------------------
CAPS = {"max_concurrency": 6, "profiles": [
    {"key": "claude", "label": "Claude Code", "approval": "bridge", "models": [MODEL], "available": True,
     "rate_limit": {"status": "allowed_warning", "type": "seven_day", "utilization": 0.53,
                    "resets_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 2 * 86400))}},
    {"key": "cursor", "label": "Cursor agent", "approval": "unsupported", "models": [], "available": True},
]}


class Machine:
    def __init__(self, api, token):
        self.api, self.token, self.seq = api, token, {}

    def post(self, path, body):
        return self.api.call("POST", "/api/v2/ai-runner/public/runner" + path, body, token=self.token, ok=(200, 201, 204))

    def heartbeat(self, live=()):
        inv = [{"key": "manual-1", "tool": "claude", "status": "busy", "cwd": f"{ROOT}/ops-scripts", "branch": "nginx-upgrade",
                "session_id": "manual-claude", "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "prompt_preview": "Upgrade the nginx config to 1.27 and test the reloads"},
               {"key": "manual-2", "tool": "cursor", "status": "idle", "cwd": f"{ROOT}/docs", "branch": "main",
                "session_id": "manual-cursor"}]
        for run_uuid, repo in live:
            inv.append({"key": "run-" + run_uuid, "tool": "claude", "status": "busy", "cwd": f"{ROOT}/{repo}",
                        "session_id": run_uuid, "labels": {"opsapi_run": run_uuid}})
        return self.post("/heartbeat", {"version": "0.4.0", "host": "mac-studio.local", "os": "darwin",
                                        "capabilities": CAPS, "load": {"running": len(live)}, "inventory": inv,
                                        "repos": [{"path": f"{ROOT}/{r}", "branch": "main", "dirty": False,
                                                   "remote": f"git@github.com:example/{r}.git"} for r in REPOS]})

    def claim(self):
        return (self.post("/claim", {"wait_s": 0}) or {}).get("run")

    def status(self, run, status, **kw):
        self.seq[run] = self.seq.get(run, 0) + 1
        return self.post(f"/runs/{run}/status", dict(seq=self.seq[run], status=status, **kw))

    def log(self, run, *lines):
        base = self.seq.setdefault("ev:" + run, 0)
        self.post(f"/runs/{run}/events", {"events": [{"seq": base + i + 1, "type": "log", "text": t}
                                                     for i, t in enumerate(lines)]})
        self.seq["ev:" + run] = base + len(lines)

    def turn(self, run, n, text, tokens_in, tokens_out, cost, secs, needs_input=False):
        self.post(f"/runs/{run}/turns", {"turn": n, "text": text, "model": MODEL, "cost_estimate": cost,
                                         "num_turns": 3 + n, "duration_ms": secs * 1000, "needs_input": needs_input,
                                         "usage": {"input_tokens": tokens_in, "output_tokens": tokens_out,
                                                   "cache_read_tokens": tokens_in * 6, "cache_write_tokens": 900}})

    def ask(self, run, request_id, command, description):
        return self.post(f"/runs/{run}/permissions", {"request_id": request_id, "tool": "Bash",
                                                      "input": {"command": command, "description": description},
                                                      "description": description})["request"]


def sha():
    return secrets.token_hex(20)


# --- seeding ----------------------------------------------------------------------------------------------------
def seed(api, email):
    key = secret()
    row = sql("SELECT uuid || '|' || coalesce(first_name,'') || '|' || coalesce(last_name,'') FROM users "
              f"WHERE lower(email) = lower({lit(email)}) LIMIT 1")
    if not row:
        raise SystemExit(f"No local user with email {email}")
    uuid, first, last = row.split("|")
    me = {"uuid": uuid, "email": email, "first_name": first or "You", "last_name": last}
    T = {"me": jwt(me, key)}

    slug = "ai-runs-demo-" + time.strftime("%m%d%H%M%S")
    ns = api.call("POST", "/api/v2/user/namespaces", {"name": "AI Runs demo", "slug": slug}, T["me"])
    ns = str((ns.get("namespace") or ns)["uuid"])
    print("workspace: AI Runs demo (" + slug + ")")
    api.call("PUT", "/api/v2/namespace/plugins/ai_runner", {"enabled": True}, T["me"], ns)

    people = {"me": me}
    for first_name, last_name, mail in TEAM:
        found = sql(f"SELECT uuid FROM users WHERE lower(email) = lower({lit(mail)}) LIMIT 1")
        if not found:  # a teammate account nobody logs in to (random password, never shown)
            u = api.call("POST", "/api/v2/users", {"email": mail, "password": "Demo-" + secrets.token_urlsafe(18),
                                                   "first_name": first_name, "last_name": last_name,
                                                   "namespace_role": "admin"}, T["me"], ns)
            found = (u.get("user") or u)["uuid"]
        else:
            api.call("POST", f"/api/v2/admin/users/{found}/namespaces", {"namespace_id": ns, "role_name": "admin"},
                     T["me"])
        people[first_name.lower()] = {"uuid": found, "email": mail, "first_name": first_name, "last_name": last_name}
        T[first_name.lower()] = jwt(people[first_name.lower()], key)

    s = api.call("GET", "/api/v2/ai-runner/settings", token=T["me"], ns=ns)
    s.update(output_mode="pull_request", task_automation={"in_progress_on_start": True, "review_on_success": True})
    s["approval_policy"] = dict(s.get("approval_policy") or {}, deciders="requester_or_managers",
                                permission_timeout_minutes=1440, input_timeout_minutes=1440)
    api.call("PUT", "/api/v2/ai-runner/settings", {k: v for k, v in s.items() if k not in ("updated_at", "updated_by")},
             T["me"], ns)

    # Projects and tasks.
    tasks = {}
    plan = {
        "Website revamp": [("dark", "Add dark mode to the settings page", "high", "me"),
                           ("flaky", "Fix the flaky login test", "medium", "priya"),
                           ("orders", "Add pagination to the orders table", "high", "me"),
                           ("images", "Optimise image loading on the home page", "medium", "priya"),
                           ("health", "Add a health endpoint for the load balancer", "low", "me"),
                           ("billing", "Refactor the billing service", "medium", "priya")],
        "Mobile app": [("rn", "Upgrade React Native to 0.76", "high", "tom"),
                       ("i18n", "Translate the onboarding screens to Spanish", "medium", "tom"),
                       ("docs", "Write API docs for /invoices", "low", "me"),
                       ("ci", "Migrate CI to GitHub Actions", "medium", "tom"),
                       ("cursor", "Try Cursor on the docs site", "low", "tom")],
    }
    for pname, items in plan.items():
        proj = api.call("POST", "/api/v2/kanban/projects", {"name": pname}, T["me"], ns)
        boards = api.call("GET", f"/api/v2/kanban/projects/{proj['uuid']}/boards", token=T["me"], ns=ns)
        board = (boards if isinstance(boards, list) else (boards.get("boards") or boards.get("data")))[0]
        for key_, title, prio, who in items:
            t = api.call("POST", f"/api/v2/kanban/boards/{board['uuid']}/tasks",
                         {"title": title, "priority": prio, "description": "Demo task for AI Runs."}, T["me"], ns)
            api.call("POST", f"/api/v2/kanban/tasks/{t['uuid']}/assignees", {"user_uuid": people[who]["uuid"]},
                     T["me"], ns)
            tasks[key_] = (t["uuid"], who)

    # Runners: the online demo machine, a paused build server, an old laptop that went offline.
    reg = api.call("POST", "/api/v2/ai-runner/runners", {"name": "mac-studio"}, T["me"], ns)
    studio = reg["runner"]["uuid"]
    api.call("PUT", f"/api/v2/ai-runner/runners/{studio}/access", {"mode": "everyone"}, T["me"], ns)
    m = Machine(api, reg["token"])
    for name, after in (("build-server", "pause"), ("old-macbook", None)):
        r = api.call("POST", "/api/v2/ai-runner/runners", {"name": name}, T["me"], ns)
        Machine(api, r["token"]).post("/heartbeat", {"version": "0.3.0", "host": name + ".local", "os": "darwin",
                                                     "capabilities": {"max_concurrency": 1, "profiles": [
                                                         CAPS["profiles"][0]]}, "repos": [], "inventory": []})
        if after:
            api.call("POST", f"/api/v2/ai-runner/runners/{r['runner']['uuid']}/{after}", {}, T["me"], ns)
    sql("UPDATE ar_runners SET last_heartbeat_at = NOW() - interval '3 days' WHERE name = 'old-macbook' "
        f"AND namespace_id = (SELECT id FROM namespaces WHERE uuid = {lit(ns)})")
    m.heartbeat()

    def start(key_, repo, profile="claude"):
        m.heartbeat()  # a runner counts as online for 45 s after its last heartbeat
        task_uuid, who = tasks[key_]
        return api.call("POST", f"/api/v2/ai-runner/tasks/{task_uuid}/runs",
                        {"runner_uuid": studio, "profile": profile, "repo_path": f"{ROOT}/{repo}",
                         "confirm_similar": True}, T[who], ns)["uuid"]

    def begin(run, *lines):
        assert m.claim()["uuid"] == run
        m.status(run, "starting", previous_branch="main")
        m.status(run, "running", pid=random.randint(20000, 60000), agent_session_id=run)
        m.log(run, f"Session started · model {MODEL}", *lines)

    def decide(run, req, who, decision, reason=None, remember=False):
        body = {"decision": decision, **({"reason": reason} if reason else {}), **({"remember": True} if remember else {})}
        api.call("POST", f"/api/v2/ai-runner/runs/{run}/requests/{req['uuid']}/decide", body, T[who], ns)

    finished = []

    # 1. Dark mode: two permissions (one allowed for the run, one denied), a follow-up, a PR.
    run = start("dark", "website")
    begin(run, "→ Read: src/settings/SettingsPage.tsx", "← (342 lines)", "→ Grep: useTheme", "← 6 matches",
          "→ Edit: src/settings/SettingsPage.tsx", "→ Write: src/theme/dark.css")
    req = m.ask(run, "r1", "npm test -- settings", "Run the settings tests")
    m.status(run, "waiting_permission")
    decide(run, req, "priya", "allow", remember=True)
    m.log(run, "⚑ Asked: Bash `npm test -- settings`", "✓ Allowed by Priya Patel", "→ Bash: npm test -- settings",
          "← 24 passing (3.1s)")
    m.status(run, "running")
    req = m.ask(run, "r2", "rm -rf node_modules && npm install", "Reinstall dependencies")
    m.status(run, "waiting_permission")
    decide(run, req, "me", "deny", reason="Not needed, the lockfile is fine")
    m.log(run, "⚑ Asked: Bash `rm -rf node_modules && npm install`",
          "✗ Denied by you: Not needed, the lockfile is fine")
    m.status(run, "running")
    m.turn(run, 1, "Added a dark theme (CSS variables), a toggle on the settings page that remembers the choice, "
                   "and tests for the toggle. All 24 settings tests pass.", 38200, 4100, 0.31, 412)
    api.call("POST", f"/api/v2/ai-runner/runs/{run}/turns", {"text": "Please also respect the system preference "
                                                                     "(prefers-color-scheme) by default."}, T["me"], ns)
    m.post(f"/runs/{run}/turns/next", {"wait_s": 0})
    m.log(run, "→ Edit: src/theme/useTheme.ts", "Turn 1 finished · 38.2K/4.1K tokens · 6m52s",
          "Turn 2 finished · 9.6K/1.2K tokens · 1m40s")
    m.turn(run, 2, "Done: the theme now follows prefers-color-scheme until the user picks one.", 9600, 1200, 0.08, 100)
    m.status(run, "succeeded", summary="Dark mode for the settings page, following the system preference by default.",
             commit_sha=sha(), pr_url="https://github.com/example/website/pull/128", previous_branch="main")
    finished.append((run, 3, 14))

    # 2. Flaky test (Priya): pushed branch.
    run = start("flaky", "website")
    begin(run, "→ Read: e2e/login.spec.ts", "→ Edit: e2e/login.spec.ts")
    m.turn(run, 1, "The test raced the redirect; it now waits for the dashboard heading. Ran it 20 times: green.",
           21400, 2300, 0.17, 380)
    m.status(run, "succeeded", summary="Login test waits for the redirect instead of a fixed sleep.", commit_sha=sha(),
             pr_url="https://github.com/example/website/pull/131", previous_branch="main")
    finished.append((run, 1, 9))

    # 3. React Native upgrade (Tom): hit the plan's usage limit.
    run = start("rn", "mobile-app")
    begin(run, "→ Read: package.json", "→ Edit: package.json", "→ Bash: npx react-native upgrade 0.76.0")
    m.turn(run, 1, "Claude AI usage limit reached.", 52000, 800, 0.44, 600)
    m.status(run, "failed", error_category="rate_limited",
             error="Claude's usage limit was reached; it resets in about 3 hours. Retry after that.")
    finished.append((run, 2, 11))

    # 4. API docs: the folder had uncommitted changes.
    run = start("docs", "docs")
    begin(run)
    m.status(run, "failed", error_category="dirty_folder",
             error="The folder has uncommitted changes (2 files). Commit or stash them, then retry.")
    finished.append((run, 5, 1))

    # 5. Billing refactor (Priya): cancelled by you.
    run = start("billing", "api")
    begin(run, "→ Read: src/billing/service.ts", "→ Grep: chargeCustomer")
    api.call("POST", f"/api/v2/ai-runner/runs/{run}/cancel", {}, T["me"], ns)
    m.log(run, "Stopping the agent (cancelled from OpsAPI)")
    m.status(run, "cancelled", error="Cancelled from OpsAPI")
    finished.append((run, 4, 6))

    # 6. CI migration (Tom): the machine stopped reporting.
    run = start("ci", "infra")
    begin(run, "→ Read: .gitlab-ci.yml", "→ Write: .github/workflows/ci.yml")
    finished.append((run, 6, 20))

    # 7. Health endpoint: local commit only, this morning.
    run = start("health", "api")
    begin(run, "→ Read: src/server.ts", "→ Edit: src/server.ts", "→ Write: src/routes/health.ts")
    m.turn(run, 1, "Added GET /health returning {status, version}; covered by a unit test.", 12800, 1500, 0.09, 260)
    m.status(run, "succeeded", summary="GET /health for the load balancer.", commit_sha=sha(), previous_branch="main")
    finished.append((run, 0, 5))

    # Spread the history over the last week and make durations real.
    for run, days, minutes in finished:
        when = f"NOW() - interval '{days} days' - interval '{random.randint(1, 9)} hours'"
        sql(f"""
          UPDATE ar_runs SET created_at = {when}, claimed_at = {when} + interval '4 seconds',
            started_at = {when} + interval '9 seconds',
            finished_at = {when} + interval '9 seconds' + interval '{minutes} minutes',
            updated_at = {when} + interval '9 seconds' + interval '{minutes} minutes', heartbeat_at = NULL,
            lease_until = NULL WHERE uuid = {lit(run)};
          UPDATE ar_run_events e SET at = r.started_at + (r.finished_at - r.started_at)
              * (e.seq::float / GREATEST((SELECT max(seq) FROM ar_run_events WHERE run_uuid = r.uuid), 1))
            FROM ar_runs r WHERE r.uuid = e.run_uuid AND e.run_uuid = {lit(run)};
          UPDATE ar_run_turns t SET at = r.started_at + (r.finished_at - r.started_at)
              * (t.seq::float / GREATEST((SELECT max(seq) FROM ar_run_turns WHERE run_uuid = r.uuid), 1))
            FROM ar_runs r WHERE r.uuid = t.run_uuid AND t.run_uuid = {lit(run)};
          UPDATE ar_run_requests q SET created_at = r.started_at + (r.finished_at - r.started_at) * 0.3,
            decided_at = r.started_at + (r.finished_at - r.started_at) * 0.35
            FROM ar_runs r WHERE r.uuid = q.run_uuid AND q.run_uuid = {lit(run)};
          UPDATE ai_usage SET created_at = (SELECT finished_at FROM ar_runs WHERE uuid = {lit(run)})
            WHERE run_uuid = {lit(run)};""")
    sql(f"""UPDATE ar_runs SET status = 'lost', error_category = 'lease_expired',
              error = 'The runner stopped sending heartbeats' WHERE uuid = {lit(finished[5][0])}""")
    sql("DELETE FROM ar_locks WHERE run_uuid IN (" + ", ".join(lit(r) for r, _, _ in finished) + ")")

    # Live runs, kept alive by the machine loop.
    orders = start("orders", "website")
    begin(orders, "→ Read: src/orders/OrdersTable.tsx", "← (218 lines)", "→ Grep: useOrders", "← 3 matches",
          "→ Edit: src/orders/OrdersTable.tsx")
    m.turn(orders, 1, "Added server-side pagination (page, per_page) to the orders query and a pager under the table. "
                      "Working on the empty and loading states next.", 26400, 2900, 0.21, 300)

    images = start("images", "mobile-app")
    begin(images, "→ Read: src/home/Hero.tsx", "→ Edit: src/home/Hero.tsx")
    req = m.ask(images, "r1", "npm run build -- --analyze", "Build with the bundle analyser to measure image sizes")
    m.status(images, "waiting_permission")
    m.log(images, "⚑ Asked: Bash `npm run build -- --analyze`")

    i18n = start("i18n", "design-system")
    begin(i18n, "→ Read: src/onboarding/strings.en.json", "→ Write: src/onboarding/strings.es.json")
    question = "Should the Spanish copy use the formal (usted) or the informal (tú) form of address?"
    m.turn(i18n, 1, "I translated 14 of the 16 onboarding strings.\nNEEDS_INPUT: " + question, 18900, 2600, 0.15, 240,
           needs_input=True)
    m.status(i18n, "needs_input", question=question)

    pending = start("cursor", "docs", profile="cursor")  # Tom's: approval: unsupported -> a manager approves
    for run, minutes in ((orders, 12), (images, 4), (i18n, 25), (pending, 30)):
        sql(f"""UPDATE ar_runs SET created_at = NOW() - interval '{minutes} minutes',
                  started_at = CASE WHEN started_at IS NULL THEN NULL ELSE NOW() - interval '{minutes - 1} minutes' END,
                  claimed_at = CASE WHEN claimed_at IS NULL THEN NULL ELSE NOW() - interval '{minutes - 1} minutes' END
                WHERE uuid = {lit(run)}""")

    state = {"api": api.base, "ns": ns, "token": reg["token"], "studio": studio, "seq": m.seq,
             "live": {orders: "website", images: "mobile-app", i18n: "design-system"},
             "waiting": {images: req["uuid"]}, "asking": [i18n]}
    with open(STATE, "w") as f:
        os.chmod(STATE, 0o600)
        json.dump(state, f)
    print("seeded: 7 finished runs, 3 live runs, 1 waiting for approval; 3 runners; 11 tasks; 2 teammates")
    return state


# --- playing the machine ----------------------------------------------------------------------------------------
def play(state):
    api = Api(state["api"])
    m = Machine(api, state["token"])
    m.seq = state.get("seq", {})
    live, waiting, asking = state["live"], state["waiting"], set(state["asking"])
    print("playing mac-studio: live runs stay live; Ctrl+C to stop")
    next_beat = 0
    while True:
        if time.time() >= next_beat:
            beat = m.heartbeat(list(live.items()))
            next_beat = time.time() + 15
            for run in beat.get("cancel") or []:
                if run in live:
                    m.log(run, "Stopping the agent (cancelled from OpsAPI)")
                    m.status(run, "cancelled", error="Cancelled from OpsAPI")
                    live.pop(run)
                    waiting.pop(run, None)
                    asking.discard(run)
        for run, req in list(waiting.items()):
            d = m.post(f"/runs/{run}/permissions/{req}/wait", {"wait_s": 0})
            if d.get("status") in ("allowed", "denied", "expired"):
                waiting.pop(run)
                ok = d["status"] == "allowed"
                m.log(run, ("✓ Allowed by " if ok else "✗ Denied by ") + (d.get("decided_by_name") or "OpsAPI")
                      + (f": {d['reason']}" if d.get("reason") and not ok else ""))
                m.status(run, "running")
                if ok:
                    m.log(run, "→ Bash: npm run build -- --analyze", "← hero.jpg 1.8 MB → 210 KB (WebP)")
                m.turn(run, 1, "Converted the hero images to WebP with srcset; the home page is 1.6 MB lighter."
                       if ok else "Skipped the bundle analysis; converted the hero images to WebP anyway.",
                       15800, 1900, 0.12, 180)
                m.status(run, "succeeded", summary="Hero images served as WebP with srcset.", commit_sha=sha(),
                         pr_url="https://github.com/example/mobile-app/pull/57", previous_branch="main")
                live.pop(run, None)
        for run in list(live):
            got = m.post(f"/runs/{run}/turns/next", {"wait_s": 0}).get("turns") or []
            if not got:
                continue
            text = " ".join(t.get("text") or "" for t in got)
            if run in asking:
                asking.discard(run)
                m.status(run, "running")
                m.log(run, "← Answer: " + text[:120], "→ Edit: src/onboarding/strings.es.json")
                m.turn(run, 2, f"Used your answer ({text[:60]}) for all 16 strings.", 7400, 1100, 0.06, 90)
                m.status(run, "succeeded", summary="Spanish onboarding strings.", commit_sha=sha(), previous_branch="main")
                live.pop(run)
            else:
                m.log(run, "← Message: " + text[:120])
                m.turn(run, int(time.time()) % 1000 + 2, "Got it — I'll do that as part of this change.", 3100, 400,
                       0.03, 20)
        claimed = m.claim()  # e.g. the Cursor run once a manager approved it
        if claimed:
            run = claimed["uuid"]
            m.status(run, "starting", previous_branch="main")
            m.status(run, "running", pid=random.randint(20000, 60000))
            m.log(run, "Session started · Cursor agent", "→ Read: docs/index.md", "→ Edit: docs/getting-started.md")
            m.turn(run, 1, "Tidied the getting-started page and fixed 3 broken links.", 9200, 1400, 0, 120)
            m.status(run, "succeeded", summary="Docs site: getting-started tidied, links fixed.", commit_sha=sha(),
                     pr_url="https://github.com/example/docs/pull/12", previous_branch="main")
        state.update(live=live, waiting=waiting, asking=list(asking), seq=m.seq)
        with open(STATE, "w") as f:
            json.dump(state, f)
        time.sleep(3)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--email", help="your local OpsAPI account (owner of the demo workspace)")
    ap.add_argument("--api", default="http://127.0.0.1:4020")
    ap.add_argument("--once", action="store_true", help="seed only; don't play the machine")
    ap.add_argument("--keepalive", action="store_true", help="play the last seeded machine again")
    a = ap.parse_args()
    if a.keepalive:
        state = json.load(open(STATE))
    else:
        if not a.email:
            ap.error("--email is required to seed")
        state = seed(Api(a.api), a.email)
    if not a.once:
        try:
            play(state)
        except KeyboardInterrupt:
            print("\nstopped; live runs become 'lost' after about a minute (run --keepalive to bring them back)")


if __name__ == "__main__":
    sys.exit(main())
