"""Renovations on kanban boards, the "due" list, and the back-office roles.

  * POST /renovations makes a kanban project whose columns are the build stages and whose cards are dated jobs,
    stretched to the finish date; builders are added as project members
  * GET /due lists deal tasks and renovation jobs due soon: managers see the team, others only theirs
  * seeded roles carry the back-office modules (orders, invoices, CRM, projects) and the builder role exists
  * another workspace can't see or link to any of it
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, sql, workspace  # noqa: E402


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


S = workspace("owner_s", "Reno Homes Ltd", "reno-homes")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_s", S), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_s", S), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
by_name = {r["role_name"]: r for r in roles}
check("builder role is seeded", "pd_builder" in by_name, sorted(by_name))


def perms(role):
    p = by_name.get(role, {}).get("permissions") or {}
    return json.loads(p) if isinstance(p, str) else p


mgr_perms = perms("pd_manager")
for mod in ("orders", "invoices", "crm_accounts", "projects", "customers"):
    check(f"pd_manager can manage {mod}", "manage" in (mgr_perms.get(mod) or []), mgr_perms.get(mod))
op_perms = perms("pd_operator")
check("pd_operator can create invoices", "create" in (op_perms.get("invoices") or []), op_perms.get("invoices"))
for user, role in (("manager_s", "pd_manager"), ("operator_s", "pd_operator")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
           {"email": USERS[user][1], "role_ids": [by_name[role]["id"]]}), 201)

prop = data(call("POST", P + "/properties", "operator_s", S, {"address_line1": "3 Brick Row", "town": "Leeds",
            "postcode": "LS1 1AA", "condition": "needs_work"}), 201, "property")
deal = data(call("POST", P + "/deals", "operator_s", S, {"property_uuid": prop["uuid"], "deal_type": "buy",
            "name": "3 Brick Row"}), 201, "deal")

# --- Start a renovation ---------------------------------------------------------------------------------------------
res = call("POST", P + "/renovations", "operator_s", S, {"deal_uuid": deal["uuid"], "target_end_date": "2026-01-01",
           "start_date": "2026-02-01"})
check("finish before start is refused (422)", res[0] == 422, res)
reno = data(call("POST", P + "/renovations", "operator_s", S, {
    "deal_uuid": deal["uuid"], "budget": 45000, "start_date": "2030-03-02", "target_end_date": "2030-05-01",
    "builder_user_uuids": [USERS["manager_s"][0]]}), 201, "start a renovation")
check("named after the property", reno.get("name") == "Renovation — 3 Brick Row", reno.get("name"))
check("linked to the deal and its property", reno.get("deal_uuid") == deal["uuid"] and reno.get("property_uuid") == prop["uuid"], reno)
check("standard jobs created", reno.get("jobs_total") == 19 and reno.get("jobs_done") == 0, reno)
check("budget and dates on the project", float(reno.get("budget") or 0) == 45000 and reno.get("due_date", "").startswith("2030-05-01"), reno)
check("builder added to the board", reno.get("builders_added") == [USERS["manager_s"][0]], reno.get("builders_added"))
P_UUID = reno["project_uuid"]
cols = sql(f"""SELECT c.name || '|' || c.is_done_column FROM kanban_columns c JOIN kanban_boards b ON b.id = c.board_id
              JOIN kanban_projects p ON p.id = b.project_id WHERE p.uuid = '{P_UUID}' ORDER BY c.position""")
check("columns are the build stages, ending in a done column",
      cols[0] == "Survey & quotes|false" and cols[-1] == "Done|true" and len(cols) == 9, cols)
last = sql(f"""SELECT MAX(t.due_date)::text, MIN(t.start_date)::text FROM kanban_tasks t JOIN kanban_boards b ON b.id = t.board_id
              JOIN kanban_projects p ON p.id = b.project_id WHERE p.uuid = '{P_UUID}'""")
check("jobs spread from the start to the finish date", last == ["2030-05-01|2030-03-02"], last)
lst = data(call("GET", P + "/renovations", "operator_s", S), 200, "list renovations")
check("listed with progress", len(lst) == 1 and lst[0]["uuid"] == reno["uuid"] and lst[0]["board_uuid"], lst)
check("filter by deal", len(data(call("GET", P + f"/renovations?deal_uuid={deal['uuid']}", "operator_s", S), 200, "by deal")) == 1)

# --- Due list -------------------------------------------------------------------------------------------------------
# Make two jobs due: one overdue, one tomorrow. The manager is assigned the overdue one.
sql(f"""UPDATE kanban_tasks t SET due_date = CURRENT_DATE - 2 FROM kanban_boards b, kanban_projects p
        WHERE t.board_id = b.id AND b.project_id = p.id AND p.uuid = '{P_UUID}' AND t.title = 'Survey and schedule of works'""")
sql(f"""UPDATE kanban_tasks t SET due_date = CURRENT_DATE + 1 FROM kanban_boards b, kanban_projects p
        WHERE t.board_id = b.id AND b.project_id = p.id AND p.uuid = '{P_UUID}' AND t.title = 'Get three builder quotes'""")
sql(f"""INSERT INTO kanban_task_assignees (uuid, task_id, user_uuid, assigned_by, assigned_at, created_at)
        SELECT gen_random_uuid()::text, t.id, '{USERS["manager_s"][0]}', '{USERS["owner_s"][0]}', NOW(), NOW() FROM kanban_tasks t
        JOIN kanban_boards b ON b.id = t.board_id JOIN kanban_projects p ON p.id = b.project_id
        WHERE p.uuid = '{P_UUID}' AND t.title = 'Survey and schedule of works'""")
team = data(call("GET", P + "/due?days=7", "manager_s", S), 200, "manager: due")
jobs = [i for i in team["items"] if i["kind"] == "renovation_job"]
check("manager sees the whole team", team["everyone"] is True)
check("both renovation jobs due this week", {j["title"] for j in jobs} == {"Survey and schedule of works", "Get three builder quotes"}, jobs)
over = next((j for j in jobs if j["title"] == "Survey and schedule of works"), {})
check("overdue job flagged, with stage, project and assignee", over.get("overdue") is True and over.get("column_name") == "Survey & quotes"
      and over.get("project_uuid") == P_UUID and over.get("deal_uuid") == deal["uuid"] and over.get("assignee"), over)
check("overdue first", team["items"][0]["overdue"] is True, team["items"][:1])
mine = data(call("GET", P + "/due?days=7&mine=true", "manager_s", S), 200, "manager: only mine")
check("'only mine' keeps just the assigned job", [i["title"] for i in mine["items"] if i["kind"] == "renovation_job"]
      == ["Survey and schedule of works"], mine["items"])
op = data(call("GET", P + "/due?days=7", "operator_s", S), 200, "operator: due")
check("an operator sees only their own", op["everyone"] is False and not [i for i in op["items"] if i["kind"] == "renovation_job"], op)
done_col = sql(f"""SELECT c.id FROM kanban_columns c JOIN kanban_boards b ON b.id = c.board_id JOIN kanban_projects p ON p.id = b.project_id
                  WHERE p.uuid = '{P_UUID}' AND c.is_done_column""")[0]
sql(f"""UPDATE kanban_tasks t SET column_id = {done_col} FROM kanban_boards b, kanban_projects p
        WHERE t.board_id = b.id AND b.project_id = p.id AND p.uuid = '{P_UUID}' AND t.title = 'Get three builder quotes'""")
after = data(call("GET", P + "/due?days=7", "manager_s", S), 200, "due after moving a card to Done")
check("a card in Done is no longer due", "Get three builder quotes" not in [i["title"] for i in after["items"]], after["items"])
check("progress counts the done card", data(call("GET", P + "/renovations", "manager_s", S), 200, "progress")[0]["jobs_done"] == 1)

# --- Isolation ------------------------------------------------------------------------------------------------------
B = workspace("owner_b", "Other Reno Co", "other-reno")
expect("enable the plugin (B)", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_b", B, {"enabled": True}), 200)
expect("setup (B)", call("POST", P + "/setup", "owner_b", B), 200)
check("other workspace lists none", not data(call("GET", P + "/renovations", "owner_b", B), 200, "B list"))
res = call("POST", P + "/renovations", "owner_b", B, {"deal_uuid": deal["uuid"]})
check("other workspace can't start one on our deal (422)", res[0] == 422, res)
check("other workspace's due list is empty", data(call("GET", P + "/due", "owner_b", B), 200, "B due")["items"] == [])

sys.exit(finish())
