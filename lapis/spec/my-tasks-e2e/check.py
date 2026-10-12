"""My tasks e2e checks (run by run.sh; stdlib only).

Two workspaces, A and B. Alice is a member of both, Bob of A only; their tasks
are spread over priorities, statuses, projects and due dates around a fixed
"today" D. Every expected list is computed from the seed table below and
compared with the API's, order included. Every check prints ok/FAIL; exit 1 on
any FAIL.
"""
import base64, datetime, hashlib, hmac, json, math, os, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request, uuid

API = os.environ["API"]
PG = os.environ["PG_CONTAINER"]
API_CONTAINER = os.environ["API_CONTAINER"]
SECRET = open(os.environ["JWT_SECRET_FILE"]).read().strip()
failures = 0
D = datetime.date(2030, 6, 15)
DS = D.isoformat()


def check(name, ok, detail=None):
    global failures
    if ok:
        print("  ok   " + name)
    else:
        failures += 1
        print("  FAIL " + name + ("  (" + str(detail)[:600] + ")" if detail is not None else ""))
    return ok


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "mt", "-At", "-F", "|",
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


def call(method, path, u, ns, body=None):
    h = {"Content-Type": "application/json"}
    if u:
        h["Authorization"] = "Bearer " + jwt(u)
    if ns:
        h["X-Namespace-Id"] = ns
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload, status = r.read(), r.status
    except urllib.error.HTTPError as e:
        payload, status = e.read(), e.code
    try:
        return status, json.loads(payload or b"{}")
    except ValueError:
        return status, {"_raw": payload[:300]}


def my_tasks(u, ns, **q):
    s, j = call("GET", "/api/v2/kanban/my-tasks?" + urllib.parse.urlencode(q), u, ns)
    return s, j


def user(name):
    u = {"uuid": str(uuid.uuid4()), "email": name + "@mt.test"}
    sql("INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) "
        "VALUES ('%s', '%s', 'Test', '%s', '%s', 'x', true, now(), now())" % (u["uuid"], name, u["email"], name))
    return u


def member(u, ns_id, perms):
    role = "r_" + u["email"].split("@")[0]
    sql("""INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, created_at, updated_at)
           VALUES (gen_random_uuid()::text, %s, '%s', '%s', '%s', now(), now())""" % (ns_id, role, role, perms))
    sql("""INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
           SELECT gen_random_uuid()::text, %s, id, 'active', false, now(), now(), now() FROM users
           WHERE uuid = '%s'""" % (ns_id, u["uuid"]))
    sql("""INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
           SELECT gen_random_uuid()::text, m.id, r.id, now(), now() FROM namespace_members m, namespace_roles r
           WHERE m.namespace_id = %s AND r.namespace_id = %s AND r.role_name = '%s'
             AND m.user_id = (SELECT id FROM users WHERE uuid = '%s')""" % (ns_id, ns_id, role, u["uuid"]))


# ---------------------------------------------------------------------------
print("== seed")
owner_a, owner_b, alice, bob, dave, carol = (user(n) for n in ("ownera", "ownerb", "alice", "bob", "dave", "carol"))
for u, name, slug in ((owner_a, "MT A", "mt-a"), (owner_b, "MT B", "mt-b")):
    s, j = call("POST", "/api/v2/user/namespaces", u, "", {"name": name, "slug": slug})
    check("workspace %s created" % slug, s in (200, 201), j)
NS_A, ID_A = sql("SELECT uuid, id FROM namespaces WHERE slug = 'mt-a'")[0]
NS_B, ID_B = sql("SELECT uuid, id FROM namespaces WHERE slug = 'mt-b'")[0]
READ = '{"projects":["read"]}'
member(alice, ID_A, READ)
member(alice, ID_B, READ)
member(bob, ID_A, READ)
member(dave, ID_A, '{"customers":["read"]}')  # a member without projects.read

projects = {}
for owner, ns, pname in ((owner_a, NS_A, "Alpha Web"), (owner_a, NS_A, "Beta Docs"), (owner_b, NS_B, "Gamma Ops")):
    s, j = call("POST", "/api/v2/kanban/projects", owner, ns, {"name": pname})
    check("project %s created" % pname, s == 201, j)
    puuid = (j.get("data") or {}).get("uuid")
    projects[pname] = {"uuid": puuid, "ns": ns,
                       "board": one("SELECT b.uuid FROM kanban_boards b JOIN kanban_projects p ON p.id = b.project_id "
                                    "WHERE p.uuid = '%s' ORDER BY b.id LIMIT 1" % puuid)}

PRIO = {"critical": 1, "high": 2, "medium": 3, "low": 4, "none": 5}
# title, project, priority, due offset from D (None = no due date), status, assignees, then: "archive"
SEED = [
    ("A crit overdue", "Alpha Web", "critical", -3, "open", ["alice"]),
    ("A high today", "Alpha Web", "high", 0, "in_progress", ["alice"]),
    ("A high none", "Alpha Web", "high", None, "open", ["alice"]),
    ("A medium tomorrow", "Beta Docs", "medium", 1, "blocked", ["alice"]),
    ("A medium week end", "Beta Docs", "medium", 6, "review", ["alice"]),
    ("A low next week", "Beta Docs", "low", 7, "open", ["alice"]),
    ("A none yesterday", "Alpha Web", "none", -1, "open", ["alice"]),
    ("A low today", "Alpha Web", "low", 0, "open", ["alice"]),
    ("A high today 2", "Beta Docs", "high", 0, "open", ["alice"]),
    ("Shared with bob", "Alpha Web", "medium", 0, "open", ["alice", "bob"]),
    ("A done today", "Alpha Web", "high", 0, "completed", ["alice"]),
    ("A cancelled", "Alpha Web", "critical", -1, "cancelled", ["alice"]),
    ("A archived", "Alpha Web", "critical", 0, "open", ["alice"], "archive"),
    ("Bob only", "Alpha Web", "critical", 0, "open", ["bob"]),
    ("Unassigned", "Alpha Web", "critical", 0, "open", []),
    ("B alice today", "Gamma Ops", "critical", 0, "open", ["alice"]),
    ("B owner only", "Gamma Ops", "high", 0, "open", []),
]
PEOPLE = {"alice": alice, "bob": bob}
tasks = []
for i, row in enumerate(SEED):
    title, pname, prio, off, status, who = row[:6]
    p = projects[pname]
    owner = owner_a if p["ns"] == NS_A else owner_b
    body = {"title": title, "priority": prio, "status": status,
            "assignee_uuids": [PEOPLE[w]["uuid"] for w in who]}
    if off is not None:
        body["due_date"] = (D + datetime.timedelta(days=off)).isoformat()
    s, j = call("POST", "/api/v2/kanban/boards/%s/tasks" % p["board"], owner, p["ns"], body)
    t = j.get("data") or {}
    ok = check("task '%s' created" % title, s == 201 and t.get("uuid"), j)
    if len(row) > 6 and row[6] == "archive":
        s2, j2 = call("DELETE", "/api/v2/kanban/tasks/%s" % t.get("uuid"), owner, p["ns"])
        check("task '%s' archived" % title, s2 == 200, j2)
    tasks.append({"title": title, "project": pname, "project_uuid": p["uuid"], "ns": p["ns"], "priority": prio,
                  "due": (D + datetime.timedelta(days=off)) if off is not None else None, "status": status,
                  "who": who, "archived": len(row) > 6, "uuid": t.get("uuid"), "seq": i})
    time.sleep(0.01)  # distinct created_at
db_rows = {r[0]: r for r in sql("SELECT t.uuid, t.task_number, b.uuid FROM kanban_tasks t "
                                  "JOIN kanban_boards b ON b.id = t.board_id")}


def expected(who, ns, pred=lambda t: True):
    rows = [t for t in tasks if who in t["who"] and t["ns"] == ns and not t["archived"]
            and t["status"] not in ("completed", "cancelled") and pred(t)]
    rows.sort(key=lambda t: (PRIO[t["priority"]], t["due"] is None, t["due"] or D, t["seq"]))
    return [t["title"] for t in rows]


def titles(j):
    return [x["title"] for x in (j.get("data") or [])]


# ---------------------------------------------------------------------------
print("== due filters against date=%s" % DS)
DUE = {
    None: lambda t: True,
    "today": lambda t: t["due"] == D,
    "overdue": lambda t: t["due"] is not None and t["due"] < D,
    "today_and_overdue": lambda t: t["due"] is not None and t["due"] <= D,
    "week": lambda t: t["due"] is not None and D <= t["due"] <= D + datetime.timedelta(days=6),
    "upcoming": lambda t: t["due"] is not None and t["due"] >= D,
    "none": lambda t: t["due"] is None,
}
for due, pred in DUE.items():
    q = {"date": DS, "per_page": 100}
    if due:
        q["due"] = due
    s, j = my_tasks(alice, NS_A, **q)
    want = expected("alice", NS_A, pred)
    check("due=%s: exactly the expected tasks, in priority/due/created order" % due,
          s == 200 and titles(j) == want and j["meta"]["total"] == len(want), (s, titles(j), want))
s, j = my_tasks(alice, NS_A, due="today", date=DS)
check("today has the closed/archived/other people's tasks filtered out",
      not {"A done today", "A archived", "Bob only", "Unassigned", "B alice today"} & set(titles(j)), titles(j))
s, j = my_tasks(alice, NS_A, due="today_and_overdue", date=(D + datetime.timedelta(days=1)).isoformat())
check("'today' moves with the caller's date", "A medium tomorrow" in titles(j), titles(j))

print("== item fields")
s, j = my_tasks(alice, NS_A, date=DS, per_page=100)
items = j.get("data") or []
by_title = {t["title"]: t for t in tasks}
bad = []
for it in items:
    t = by_title[it["title"]]
    dbr = db_rows[it["uuid"]]
    want_overdue = t["due"] is not None and t["due"] < D
    if not (it.get("project_uuid") == t["project_uuid"] and str(it.get("task_number")) == dbr[1]
            and it.get("board_uuid") == dbr[2] and it.get("overdue") is want_overdue
            and it.get("url") == "/dashboard/projects/%s/tasks/%s" % (t["project_uuid"], t["uuid"])
            and it.get("project_name") == t["project"] and it.get("status") == t["status"]
            and it.get("priority") == t["priority"] and it.get("column_name")):
        bad.append(it["title"])
check("every item: project_uuid, task_number, board_uuid, overdue, url (+ old fields)", items and not bad, bad)
meta = j.get("meta") or {}
check("meta: total, page, per_page, total_pages, date (+ perPage/totalPages)",
      meta.get("date") == DS and meta.get("page") == 1 and meta.get("per_page") == 100
      and meta.get("total_pages") == 1 and meta.get("perPage") == 100 and meta.get("totalPages") == 1, meta)
s, j = my_tasks(alice, NS_A)
utc_today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
check("no date -> the server's UTC date", s == 200 and j["meta"]["date"] == utc_today, j.get("meta"))
s, j = my_tasks(alice, NS_A, search="zzz-nothing")
check("an empty result is a JSON list", s == 200 and j.get("data") == [] and j["meta"]["total"] == 0, j)

print("== priority / status / project / search")
s, j = my_tasks(alice, NS_A, date=DS, priority="critical,HIGH")
check("priority=critical,HIGH", titles(j) == expected("alice", NS_A, lambda t: t["priority"] in ("critical", "high")),
      titles(j))
s, j = my_tasks(alice, NS_A, date=DS, priority="none")
check("priority=none", titles(j) == ["A none yesterday"], titles(j))
s, j = my_tasks(alice, NS_A, date=DS, status="blocked,review")
check("status=blocked,review", titles(j) == ["A medium tomorrow", "A medium week end"], titles(j))
s, j = my_tasks(alice, NS_A, date=DS, project_uuid=projects["Beta Docs"]["uuid"])
check("project_uuid", titles(j) == expected("alice", NS_A, lambda t: t["project"] == "Beta Docs"), titles(j))
s, j = my_tasks(alice, NS_A, date=DS, project_uuid=projects["Gamma Ops"]["uuid"])
check("another workspace's project_uuid -> nothing", s == 200 and titles(j) == [], titles(j))
s, j = my_tasks(alice, NS_A, date=DS, search="HIGH today")
check("search is a case-insensitive title match", titles(j) == ["A high today", "A high today 2"], titles(j))
for wild in ("%", "_", "\\"):
    s, j = my_tasks(alice, NS_A, search=wild)
    check("search %r matches literally (no wildcard)" % wild, s == 200 and titles(j) == [], titles(j))
s, j = my_tasks(alice, NS_A, date=DS, due="today", priority="low")
check("filters combine (due=today & priority=low)", titles(j) == ["A low today"], titles(j))

print("== bad input -> 400")
for q in ({"due": "tomorrow"}, {"date": "2030-02-30"}, {"date": "2030-6-1"}, {"date": "15/06/2030"},
          {"priority": "urgent"}, {"priority": "high,urgent"}, {"status": "completed"}, {"status": "open,bogus"}):
    s, j = my_tasks(alice, NS_A, **q)
    check("400 for %s" % q, s == 400 and j.get("success") is False and j.get("error"), (s, j))
s, j = call("GET", "/api/v2/kanban/my-tasks?due=today&due=week&priority=high&priority=low", alice, NS_A)
check("repeated keys never 500 (Lapis keeps one value)", s in (200, 400), (s, j))

print("== paging")
allw = expected("alice", NS_A)
s, j = my_tasks(alice, NS_A, date=DS, per_page=2)
check("per_page=2", titles(j) == allw[:2] and j["meta"]["total_pages"] == math.ceil(len(allw) / 2), j.get("meta"))
s, j = my_tasks(alice, NS_A, date=DS, per_page=2, page=2)
check("page 2", titles(j) == allw[2:4], titles(j))
s, j = my_tasks(alice, NS_A, date=DS, perPage=3)
check("camelCase perPage still works", len(titles(j)) == 3 and j["meta"]["per_page"] == 3, j.get("meta"))
s, j = my_tasks(alice, NS_A, per_page=1000)
check("per_page capped at 100", s == 200 and j["meta"]["per_page"] == 100, j.get("meta"))
for q in ({"page": "nan"}, {"per_page": "nan"}, {"page": "1e400"}, {"page": "-5"}, {"per_page": "0"}):
    s, j = my_tasks(alice, NS_A, **q)
    check("odd paging %s -> 200, not 500" % q, s == 200, (s, j))

print("== isolation")
s, j = my_tasks(alice, NS_B, date=DS)
check("Alice in B sees only her B task", titles(j) == ["B alice today"], titles(j))
s, j = my_tasks(bob, NS_A, date=DS)
check("Bob sees his own + the shared task, never Alice's", titles(j) == expected("bob", NS_A), titles(j))
s, j = my_tasks(owner_a, NS_A, date=DS)
check("the workspace owner sees only tasks assigned to them (none)", s == 200 and titles(j) == [], titles(j))
s, j = my_tasks(owner_b, NS_A)
check("a non-member is refused", s in (403, 404), (s, j))
s, j = my_tasks(carol, NS_A)
check("a user in no workspace is refused", s in (403, 404), (s, j))
s, j = my_tasks(dave, NS_A)
check("a member without projects.read gets 403", s == 403, (s, j))
s, j = my_tasks(None, NS_A)
check("no token -> 401", s == 401, (s, j))

print("== assistant tool list_my_tasks on the real DB")
ALICE_ID = alice["uuid"]
lua = ("local T = require('lib.agent.tools') local cjson = require('cjson') "
       "local ctx = { namespace_id = %s, user_uuid = '%s', has_permission = function() return true end } "
       "local r, e = T.execute(ctx, 'list_my_tasks', { due = 'today_and_overdue', date = '%s', limit = 3 }) "
       "print('@@' .. cjson.encode({ r = r, e = e }) .. '@@')") % (ID_A, ALICE_ID, DS)
out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "exec", lua],
                     capture_output=True, text=True)
raw = (out.stdout + out.stderr)
blob = raw.split("@@")[1] if raw.count("@@") >= 2 else None
if check("tool runs inside the app", blob is not None, raw[-800:]):
    res = json.loads(blob).get("r") or {}
    want = expected("alice", NS_A, DUE["today_and_overdue"])[:3]
    rows = res.get("tasks") or []
    keys = {"uuid", "task_number", "title", "priority", "status", "due_date", "overdue", "project", "project_uuid",
            "column", "url"}
    check("tool: top 3 of today_and_overdue, by priority", [r["title"] for r in rows] == want, (rows, want))
    check("tool rows carry exactly the documented fields", rows and all(set(r) == keys for r in rows),
          [sorted(r) for r in rows][:1])
    check("tool result: total and date", res.get("total") == len(expected("alice", NS_A, DUE["today_and_overdue"]))
          and res.get("date") == DS, {k: res.get(k) for k in ("total", "date")})

print("== My Tasks menu item (migration zzmt1)")
check("one my_tasks menu item: path, module, icon, priority 2",
      sql("SELECT path, module, required_action, icon, priority FROM menu_items WHERE key = 'my_tasks'")
      == [["/dashboard/my-tasks", "projects", "read", "ListTodo", "2"]])
s, j = call("GET", "/api/v2/user/menu", alice, NS_A)
check("Alice (projects.read) gets My Tasks in her menu", s == 200 and "/dashboard/my-tasks" in json.dumps(j), s)
s, j = call("GET", "/api/v2/user/menu", dave, NS_A)
check("Dave (no projects.read) does not", s == 200 and "/dashboard/my-tasks" not in json.dumps(j), s)
# Re-run on a database with namespaces: every namespace gets an enabled row, nothing duplicates.
sql("DELETE FROM namespace_menu_config WHERE menu_item_id = (SELECT id FROM menu_items WHERE key = 'my_tasks')")
sql("DELETE FROM lapis_migrations WHERE name = 'zzmt1_my_tasks_menu'")
for _ in range(2):
    out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "migrate"],
                         capture_output=True, text=True)
    check("lapis migrate re-run ok", out.returncode == 0, (out.stdout + out.stderr)[-500:])
check("still one menu item", one("SELECT COUNT(*) FROM menu_items WHERE key = 'my_tasks'") == "1")
check("enabled once for every namespace", one("""
    SELECT COUNT(*) FROM namespaces n WHERE (SELECT COUNT(*) FROM namespace_menu_config c
      WHERE c.namespace_id = n.id AND c.is_enabled
        AND c.menu_item_id = (SELECT id FROM menu_items WHERE key = 'my_tasks')) <> 1""") == "0"
      and int(one("SELECT COUNT(*) FROM namespaces")) >= 2)

print()
print("All checks passed." if failures == 0 else "%d check(s) FAILED." % failures)
sys.exit(0 if failures == 0 else 1)
