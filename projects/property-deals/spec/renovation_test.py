"""Renovations on kanban boards, the "due" list, and the back-office roles.

  * POST /renovations makes a kanban project whose columns are the build stages and whose cards are dated jobs,
    stretched to the finish date; builders are added as project members
  * GET /due lists deal tasks and renovation jobs due soon: managers see the team, others only theirs
  * seeded roles carry the back-office modules (orders, invoices, CRM, projects) and the builder role exists
  * builders read deals, properties and tasks for their boards but not leads (situation, vulnerability notes),
    lead replies, hot leads or the inbox; operators and managers still do, also in workspaces set up before the
    Leads permission existed (the migration grants it)
  * another workspace can't see or link to any of it
"""
import json
import os
import re
import subprocess
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

# --- Builders don't see leads, lead replies, hot leads or the inbox ---------------------------------------------------
expect("add a builder", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
       {"email": USERS["reader"][1], "role_ids": [by_name["pd_builder"]["id"]]}), 201)
lead = expect("a seller lead", call("POST", API + "/api/v2/crm/leads", "operator_s", S, {"first_name": "Dee",
              "last_name": "Vorce", "owner_user_uuid": USERS["operator_s"][0]}), 201)
L = (lead.get("data") or lead)["uuid"]
data(call("PUT", P + f"/leads/{L}/details", "operator_s", S, {"situation": "divorce", "vulnerability_flag": True,
     "vulnerability_note": "Recently separated, finds calls stressful"}), 200, "sensitive lead details")
for path in ("/leads", f"/leads/{L}", f"/leads/{L}/replies", f"/leads/{L}/signals", "/hot-leads", "/inbound-messages"):
    res = call("GET", P + path, "reader", S)
    check(f"builder: {path} is 403", res[0] == 403, res)
    for user in ("operator_s", "manager_s"):
        res = call("GET", P + path, user, S)
        check(f"{user}: {path} is 200", res[0] == 200, res)
for path in ("/renovations", "/deals", "/tasks", f"/deals/{deal['uuid']}", "/due"):
    expect(f"builder still reads {path}", call("GET", P + path, "reader", S), 200)
me = data(call("GET", P + "/me", "reader", S), 200, "builder's /me")
check("/me: the builder has no leads permission", me["permissions"].get("leads") == [], me["permissions"])
pb = data(call("GET", P + "/pa/briefing", "reader", S), 200, "builder's briefing")
check("briefing: no hot leads or lead news for a builder", pb["hot_leads"] == [] and pb["fresh_news"] == [], pb)
mp = data(call("GET", P + "/map?lat=53.8&lng=-1.55&radius_miles=50&layers=properties,leads", "reader", S), 200, "builder map")
check("map: the leads layer is left out for a builder", "leads" not in mp["counts"], mp["counts"])

# Workspaces set up before the Leads permission existed: the migration grants it to every role that could read
# deals or tasks, except the builder. Simulate that state and run the migration again.
NSID = sql(f"SELECT id FROM namespaces WHERE uuid = '{S}'")[0]
sql(f"UPDATE namespace_roles SET permissions = (permissions::jsonb - 'property_deals_leads')::text WHERE namespace_id = {NSID}")
check("old state: the operator can't read leads", call("GET", P + "/leads", "operator_s", S)[0] == 403)
pg = re.search(r"pd-pg-(\d+)", os.environ.get("PD_PSQL", ""))
if pg:
    sql("DELETE FROM project_migrations WHERE project_code = 'property_deals' AND migration_name LIKE '20261021200000%'")
    out = subprocess.run(["docker", "exec", "-w", "/app", "pd-api-" + pg.group(1), "lapis", "migrate"],
                         capture_output=True, text=True)
    check("the migration runs on an existing database", out.returncode == 0, (out.stdout + out.stderr)[-600:])

    def perms_of(role):
        return json.loads(sql(f"SELECT permissions FROM namespace_roles WHERE namespace_id = {NSID} AND role_name = '{role}'")[0])
    check("upgrade: operator, manager, compliance and read-only roles have leads again; the builder doesn't",
          perms_of("pd_operator").get("property_deals_leads") == ["create", "read", "update"]
          and perms_of("pd_manager").get("property_deals_leads") == ["manage"]
          and perms_of("pd_compliance").get("property_deals_leads") == ["read"]
          and perms_of("pd_read_only").get("property_deals_leads") == ["read"]
          and "property_deals_leads" not in perms_of("pd_builder"), {r: perms_of(r).get("property_deals_leads")
          for r in ("pd_operator", "pd_manager", "pd_builder")})
    expect("upgrade: the operator reads leads again", call("GET", P + "/leads", "operator_s", S), 200)
    expect("upgrade: the builder still can't", call("GET", P + "/leads", "reader", S), 403)
else:
    print("skip  migration upgrade check (PD_PSQL isn't the run.sh sandbox)")

# --- Isolation ------------------------------------------------------------------------------------------------------
B = workspace("owner_b", "Other Reno Co", "other-reno")
expect("enable the plugin (B)", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_b", B, {"enabled": True}), 200)
expect("setup (B)", call("POST", P + "/setup", "owner_b", B), 200)
check("other workspace lists none", not data(call("GET", P + "/renovations", "owner_b", B), 200, "B list"))
res = call("POST", P + "/renovations", "owner_b", B, {"deal_uuid": deal["uuid"]})
check("other workspace can't start one on our deal (422)", res[0] == 422, res)
check("other workspace's due list is empty", data(call("GET", P + "/due", "owner_b", B), 200, "B due")["items"] == [])

sys.exit(finish())
