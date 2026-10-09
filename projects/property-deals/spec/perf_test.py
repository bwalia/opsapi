"""SPEC §4 performance targets, measured in the sandbox:
  * Today view < 300 ms with 5,000 open tasks in the workspace
  * map radius query < 500 ms over 100,000 properties
Rows are bulk-inserted in SQL (triggers off for the load only, like a restore), then each endpoint is called
several times and the median is checked. The sandbox is a laptop Docker VM; production hardware is faster.
"""
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, sql, workspace  # noqa: E402

S = workspace("owner_s", "Perf Ltd", "perf-ltd")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_s", S), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_s", S), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
role_id = {r["role_name"]: r["id"] for r in roles}
expect("add the operator", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
       {"email": USERS["operator_s"][1], "role_ids": [role_id["pd_operator"]]}), 201)
ns = sql(f"SELECT id FROM namespaces WHERE uuid = '{S}'")[0]
op, owner = USERS["operator_s"][0], USERS["owner_s"][0]

t0 = time.time()
sql(f"""SET session_replication_role = replica;
WITH b AS (SELECT kb.id AS board_id, (SELECT c.id FROM kanban_columns c WHERE c.board_id = kb.id ORDER BY c.position LIMIT 1) AS col
           FROM property_deals_workspaces w JOIN kanban_boards kb ON kb.uuid = w.kanban_board_uuid WHERE w.namespace_id = {ns})
INSERT INTO kanban_tasks (uuid, board_id, column_id, task_number, title, status, priority, reporter_user_uuid, created_at, updated_at)
SELECT gen_random_uuid()::text, b.board_id, b.col, 100000 + g, 'Perf task ' || g, 'open', 'medium', '{owner}', NOW(), NOW()
FROM b, generate_series(1, 5000) g;
INSERT INTO property_deals_task_details (namespace_id, task_uuid, pd_status, owner_user_uuid, due_at, sla_minutes, sla_started_at,
    urgency_score, blocking)
SELECT {ns}, t.uuid, 'todo', CASE WHEN random() < 0.5 THEN '{op}' ELSE '{owner}' END,
       NOW() + (random() * 10 - 3) * interval '1 day', 60, NOW(), round((random() * 100)::numeric, 2), random() < 0.3
FROM kanban_tasks t JOIN kanban_boards kb ON kb.id = t.board_id
JOIN property_deals_workspaces w ON w.kanban_board_uuid = kb.uuid AND w.namespace_id = {ns}
WHERE t.title LIKE 'Perf task %';
INSERT INTO property_deals_properties (namespace_id, address_line1, postcode, lat, lng, tenure, est_market_value)
SELECT {ns}, 'Perf house ' || g, 'YO1 7AA', 53.0 + random() * 2, -2.5 + random() * 2.5, 'freehold', 100000 + (random() * 300000)::int
FROM generate_series(1, 100000) g;
SET session_replication_role = DEFAULT;
ANALYZE property_deals_task_details; ANALYZE kanban_tasks; ANALYZE property_deals_properties;""")
counts = sql(f"SELECT (SELECT COUNT(*) FROM property_deals_task_details WHERE namespace_id = {ns} AND pd_status = 'todo') || '|' || "
             f"(SELECT COUNT(*) FROM property_deals_properties WHERE namespace_id = {ns})")
check("loaded 5,000 open tasks and 100,000 properties", counts == ["5000|100000"], (counts, round(time.time() - t0, 1)))


def timed(user, url, n=7):
    ms = []
    for _ in range(n + 1):
        t = time.perf_counter()
        st, b = call("GET", url, user, S)
        ms.append((time.perf_counter() - t) * 1000)
        if st != 200:
            return None, (st, str(b)[:300])
    return statistics.median(ms[1:]), b  # first call warms caches


today_ms, today = timed("operator_s", P + "/today")
check(f"Today with 5,000 open tasks: median {today_ms and round(today_ms)} ms < 300 ms", today_ms is not None and today_ms < 300,
      today if today_ms is None else None)
check("Today returns my most urgent tasks", today_ms is not None and today["data"]["tasks"]
      and all(t.get("owner_user_uuid") in (op, None) for t in today["data"]["tasks"]), None)
mgr_ms, _ = timed("owner_s", P + "/today")
check(f"Today (workspace owner, sees everything): median {mgr_ms and round(mgr_ms)} ms < 300 ms", mgr_ms is not None and mgr_ms < 300)

map_ms, mp = timed("operator_s", P + "/map?lat=54.0&lng=-1.25&radius_miles=25&layers=properties")
check(f"map radius 25 miles over 100,000 properties: median {map_ms and round(map_ms)} ms < 500 ms",
      map_ms is not None and map_ms < 500, mp if map_ms is None else None)
check("map caps the answer at 2,000 features and says so", map_ms is not None and len(mp["data"]["features"]) == 2000
      and mp["data"]["truncated"] is True, None)
poly_ms, _ = timed("operator_s", P + "/map?polygon=53.8,-1.5;54.2,-1.5;54.2,-1.0;53.8,-1.0&layers=properties")
check(f"map polygon over 100,000 properties: median {poly_ms and round(poly_ms)} ms < 500 ms", poly_ms is not None and poly_ms < 500)
tasks_ms, _ = timed("operator_s", P + "/tasks?open=true&per_page=50")
check(f"task list (open, by urgency): median {tasks_ms and round(tasks_ms)} ms < 300 ms", tasks_ms is not None and tasks_ms < 300)

print(f"perf: today={today_ms and round(today_ms)}ms today_owner={mgr_ms and round(mgr_ms)}ms map={map_ms and round(map_ms)}ms "
      f"polygon={poly_ms and round(poly_ms)}ms tasks={tasks_ms and round(tasks_ms)}ms")
sys.exit(finish())
