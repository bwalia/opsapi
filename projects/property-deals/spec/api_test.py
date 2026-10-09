"""Property Deals API checks (Phase 2): setup, CRUD, tenant isolation and RBAC.

Run by run.sh against a sandbox OpsAPI (PD_API, PD_JWT_SECRET). Standard library only.
Two workspaces: "Acme Property Ltd" (A) and "Other Co" (B). Users: owner A, owner B, and three
A members with the pd_read_only, pd_agent and pd_operator roles.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, workspace, finish  # noqa: E402

# --- Workspaces --------------------------------------------------------------
A = workspace("owner_a", "Acme Property Ltd", "acme-property")
B = workspace("owner_b", "Other Co", "other-co")

res = call("GET", P + "/deals", "owner_a", A)
check("plugin is opt-in: off until enabled (404 PLUGIN_DISABLED)",
      res[0] == 404 and "PLUGIN_DISABLED" in json.dumps(res[1]), res)
for owner, ns in (("owner_a", A), ("owner_b", B)):
    expect(f"{owner} enables the plugin",
           call("PUT", API + "/api/v2/namespace/plugins/property_deals", owner, ns, {"enabled": True}), 200)

# --- Setup -------------------------------------------------------------------
setup = expect("setup workspace A", call("POST", P + "/setup", "owner_a", A), 200)["data"]
check("setup seeds 2 templates, 5 roles, UK holidays",
      len(setup["created"]["templates"]) == 2 and len(setup["created"]["roles"]) == 5
      and setup["created"]["holidays"] >= 30, setup["created"])
again = expect("setup again", call("POST", P + "/setup", "owner_a", A), 200)["data"]
check("setup is idempotent", not again["created"]["templates"] and not again["created"]["roles"]
      and again["created"]["holidays"] == 0, again["created"])
check("kanban project + board recorded", again["state"]["kanban_project_uuid"] and again["state"]["kanban_board_uuid"])
expect("setup workspace B", call("POST", P + "/setup", "owner_b", B), 200)

# --- Templates ---------------------------------------------------------------
tpls = expect("list templates", call("GET", P + "/workflow-templates", "owner_a", A), 200)["data"]
check("two seed templates at v1", sorted(t["key"] for t in tpls) == ["sell_via_estate_agent", "uk_guaranteed_sale"]
      and all(t["active_version"] == 1 for t in tpls), tpls)
uk = next(t for t in tpls if t["key"] == "uk_guaranteed_sale")
definition = expect("export UK template", call("GET", P + f"/workflow-templates/{uk['uuid']}/export", "owner_a", A), 200)["data"]
check("UK template has the stages from SPEC 3.2", [s["key"] for s in definition["stages"]][:3] == ["new_lead", "qualified", "offer_sent"]
      and any(s["key"] == "exchange" and s.get("entry_gate") for s in definition["stages"]))
definition["stages"][0]["tasks"][0]["sla_minutes"] = 45
v2 = expect("import edited template -> new version",
            call("POST", P + "/workflow-templates/import", "owner_a", A, {"definition": definition, "notes": "faster call back"}), 201)["data"]
check("import of an existing key publishes version 2", v2.get("version") == 2, v2)
bad = dict(definition, stages=[{"key": "x", "name": "X", "tasks": [{"key": "t", "title": "T", "due": {"from": "nowhere"}}]}])
res = call("POST", P + "/workflow-templates/import", "owner_a", A, {"definition": bad})
check("invalid template rejected with reasons (422)", res[0] == 422 and res[1].get("details"), res)
versions = expect("list versions", call("GET", P + f"/workflow-templates/{uk['uuid']}/versions", "owner_a", A), 200)["data"]
check("versions 2 (active) and 1", [v["version"] for v in versions] == [2, 1] and versions[0]["is_active"], versions)

# --- Lead -> property -> deal --------------------------------------------------
lead = expect("create CRM lead", call("POST", API + "/api/v2/crm/leads", "owner_a", A,
              {"first_name": "Sam", "last_name": "Seller", "email": "sam@seller.invalid", "phone": "07000000000",
               "source": "website_form"}), 201)
lead = lead.get("data") or lead
details = expect("add property-deal lead details", call("PUT", P + f"/leads/{lead['uuid']}/details", "owner_a", A,
                 {"lead_kind": "seller", "situation": "probate", "deadline_date": "2026-12-01",
                  "vulnerability_flag": True, "vulnerability_note": "Recently bereaved",
                  "consent_basis": "legitimate_interests"}), 200)["data"]
check("lead details stored", details["details"]["situation"] == "probate" and details["details"]["vulnerability_flag"], details)
leads = expect("filter leads by situation", call("GET", P + "/leads?situation=probate&vulnerable=true", "owner_a", A), 200)
check("lead found by new filters", leads["meta"]["total"] == 1, leads)

prop = expect("create property", call("POST", P + "/properties", "owner_a", A,
              {"address_line1": "12 Acacia Avenue", "town": "Leeds", "postcode": "LS1 1AA", "lat": 53.8, "lng": -1.55,
               "tenure": "freehold", "bedrooms": 3, "known_issues": ["subsidence"], "est_market_value": 180000}), 201)["data"]
check("property known_issues stored as JSON list", prop["known_issues"] == ["subsidence"], prop)

deal = expect("create deal from lead", call("POST", P + "/deals", "owner_a", A,
              {"lead_uuid": lead["uuid"], "property_uuid": prop["uuid"], "deal_type": "buy",
               "offer_amount": 150000, "target_completion_date": "2026-11-20",
               "late_penalty_per_day": 500, "late_penalty_cap_days": 20}), 201)["data"]
check("deal starts at the template's first stage, pinned to v2",
      deal["stage_key"] == "new_lead" and deal["template_version"] == 2 and deal["template_key"] == "uk_guaranteed_sale", deal)
check("deal has a kanban epic and a CRM deal", deal["kanban_epic_uuid"] and deal["crm_deal_uuid"], deal)
check("deal named after the property", deal["name"] == "12 Acacia Avenue", deal)
lead_after = expect("lead after deal", call("GET", API + f"/api/v2/crm/leads/{lead['uuid']}", "owner_a", A), 200)
lead_after = lead_after.get("data") or lead_after
check("lead converted", lead_after["status"] == "converted", lead_after)
parties = expect("deal parties", call("GET", P + f"/deal-parties?deal_uuid={deal['uuid']}", "owner_a", A), 200)["data"]
check("seller party added from the lead", len(parties) == 1 and parties[0]["role"] == "seller", parties)
upd = expect("update deal", call("PUT", P + f"/deals/{deal['uuid']}", "owner_a", A, {"agreed_price": 155000}), 200)["data"]
check("agreed price stored", float(upd["agreed_price"]) == 155000, upd)
res = call("PUT", P + f"/deals/{deal['uuid']}", "owner_a", A, {"stage_key": "exchange"})
check("stage can't be set directly (ignored: engine owns it)", res[0] == 200 and res[1]["data"]["stage_key"] == "new_lead", res)

# --- Tasks ---------------------------------------------------------------------
task = expect("create task", call("POST", P + "/tasks", "owner_a", A,
              {"deal_uuid": deal["uuid"], "title": "Book EPC assessor", "sla_minutes": 60,
               "due_at": "2026-10-10T10:00:00Z", "blocking": True, "priority": "high",
               "owner_user_uuid": USERS["owner_a"][0]}), 201)["data"]
check("task is a kanban task in the deal's stage", task["task_uuid"] and task["stage_key"] == "new_lead"
      and task["kanban_status"] == "open" and task["pd_status"] == "todo", task)
task2 = expect("create second task", call("POST", P + "/tasks", "owner_a", A,
               {"deal_uuid": deal["uuid"], "title": "Chase searches", "compliance": True}), 201)["data"]
expect("add dependency", call("POST", P + f"/tasks/{task2['task_uuid']}/dependencies", "owner_a", A,
       {"depends_on_task_uuid": task["task_uuid"]}), 201)
res = call("POST", P + f"/tasks/{task['task_uuid']}/dependencies", "owner_a", A, {"depends_on_task_uuid": task2["task_uuid"]})
check("dependency cycle refused (422)", res[0] == 422, res)
moved = expect("task -> awaiting approval", call("PUT", P + f"/tasks/{task['task_uuid']}", "owner_a", A,
               {"pd_status": "awaiting_approval"}), 200)["data"]
check("kanban status follows (review)", moved["kanban_status"] == "review", moved)
res = call("PUT", P + f"/tasks/{task2['task_uuid']}", "owner_a", A, {"pd_status": "done"})
check("compliance task can't close without evidence (422)", res[0] == 422, res)
done = expect("close compliance task with evidence", call("PUT", P + f"/tasks/{task2['task_uuid']}", "owner_a", A,
              {"pd_status": "done", "evidence": {"note": "Searches back, clear"}}), 200)["data"]
check("completed_by recorded", done["completed_by_user_uuid"] == USERS["owner_a"][0] and done["kanban_status"] == "completed", done)
res = call("PUT", P + f"/tasks/{task['task_uuid']}", "owner_a", A, {"snoozed_until": "2026-10-11T09:00:00Z"})
check("snooze needs a reason (422)", res[0] == 422, res)
mine = expect("my open tasks", call("GET", P + f"/tasks?owner_user_uuid={USERS['owner_a'][0]}&open=true", "owner_a", A), 200)
check("my tasks lists the owned open task (plus the engine's stage tasks)",
      any(t["task_uuid"] == task["task_uuid"] for t in mine["data"]) and mine["meta"]["total"] >= 2, mine["meta"])

# --- Enquiries, chases, suppliers, bookings, compliance ----------------------------
enq = expect("raise enquiry", call("POST", P + "/enquiries", "owner_a", A,
             {"deal_uuid": deal["uuid"], "title": "Missing FENSA certificate", "owner_party": "seller_solicitor"}), 201)["data"]
expect("log a chase", call("POST", P + "/chases", "owner_a", A,
       {"deal_uuid": deal["uuid"], "enquiry_uuid": enq["uuid"], "channel": "email", "subject": "FENSA?",
        "sent_at": "2026-10-08T09:00:00Z"}), 201)
sup = expect("create supplier (new company)", call("POST", P + "/suppliers", "owner_a", A,
             {"name": "Quick EPC Ltd", "email": "book@quickepc.invalid", "kinds": ["epc_assessor"],
              "base_lat": 53.8, "base_lng": -1.5, "radius_miles": 30}), 201)["data"]
check("supplier is backed by a CRM company", sup["account_uuid"] and sup["name"] == "Quick EPC Ltd", sup)
found = expect("filter suppliers by kind", call("GET", P + "/suppliers?kind=epc_assessor", "owner_a", A), 200)
check("supplier found by kind", found["meta"]["total"] == 1, found)
expect("book supplier", call("POST", P + "/bookings", "owner_a", A,
       {"supplier_uuid": sup["uuid"], "deal_uuid": deal["uuid"], "service": "epc", "status": "tentative",
        "slot_start": "2026-10-12T09:00:00Z", "slot_end": "2026-10-12T10:00:00Z", "cost": 85}), 201)
chk = expect("create AML check", call("POST", P + "/compliance-checks", "owner_a", A,
             {"check_type": "aml_cdd_seller", "subject_type": "deal", "deal_uuid": deal["uuid"],
              "party_role": "seller", "status": "in_progress"}), 201)["data"]
passed = expect("pass AML check", call("PUT", P + f"/compliance-checks/{chk['uuid']}", "owner_a", A,
                {"status": "passed", "checked_by_user_uuid": USERS["owner_b"][0]}), 200)["data"]
check("sign-off records the signed-in person, not a client value",
      passed["checked_by_user_uuid"] == USERS["owner_a"][0] and passed["checked_at"], passed)
expect("buyer profile on a contact", call("POST", P + "/buyer-profiles", "owner_a", A,
       {"contact_uuid": parties[0]["contact_uuid"], "entity_type": "ltd_spv", "strategies": ["btl", "brr"],
        "price_max": 250000, "areas": [{"type": "radius", "lat": 53.8, "lng": -1.55, "miles": 25}]}), 201)
expect("holidays seeded", call("GET", P + "/holidays?jurisdiction=england-and-wales&per_page=100", "owner_a", A), 200)

# --- Tenant isolation ------------------------------------------------------------------
for path in (f"/deals/{deal['uuid']}", f"/tasks/{task['task_uuid']}", f"/leads/{lead['uuid']}",
             f"/properties/{prop['uuid']}", f"/suppliers/{sup['uuid']}", f"/enquiries/{enq['uuid']}",
             f"/compliance-checks/{chk['uuid']}", f"/workflow-templates/{uk['uuid']}"):
    res = call("GET", P + path, "owner_b", B)
    check(f"isolation: B can't read A's {path.split('/')[1]} (404)", res[0] == 404, res)
for path in ("/deals", "/tasks", "/leads", "/properties", "/suppliers", "/enquiries", "/compliance-checks",
             "/chases", "/bookings", "/buyer-profiles"):
    res = call("GET", P + path, "owner_b", B)
    check(f"isolation: B's {path[1:]} list is empty", res[0] == 200 and res[1]["meta"]["total"] == 0 if "meta" in res[1]
          else res[0] == 200 and not res[1]["data"], res)
res = call("GET", P + "/deals", "owner_b", A)
check("isolation: B can't use A's workspace header (403)", res[0] == 403, res)
res = call("POST", P + "/deal-parties", "owner_b", B, {"deal_uuid": deal["uuid"], "role": "buyer",
                                                       "contact_uuid": parties[0]["contact_uuid"]})
check("isolation: B can't attach to A's deal (422 same-workspace guard)", res[0] == 422, res)
res = call("POST", P + "/deals", "owner_b", B, {"property_uuid": prop["uuid"]})
check("isolation: B can't build a deal on A's property (422)", res[0] == 422, res)
res = call("POST", P + "/deals", "owner_b", B, {"lead_uuid": lead["uuid"]})
check("isolation: B can't convert A's lead (422)", res[0] == 422, res)
res = call("PUT", P + f"/tasks/{task['task_uuid']}", "owner_b", B, {"pd_status": "done"})
check("isolation: B can't change A's task (404)", res[0] == 404, res)
res = call("POST", P + "/tasks", "owner_b", B, {"title": "x", "owner_user_uuid": USERS["owner_a"][0]})
check("isolation: B can't assign a task to A's user (422)", res[0] == 422, res)

# --- RBAC ---------------------------------------------------------------------------
roles = expect("list A's roles", call("GET", API + "/api/v2/namespace/roles", "owner_a", A), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
role_id = {r["role_name"]: r["id"] for r in roles}
for user, role in (("reader", "pd_read_only"), ("agent", "pd_agent"), ("operator", "pd_operator")):
    expect(f"add {user} to A as {role}", call("POST", API + "/api/v2/namespace/members", "owner_a", A,
           {"email": USERS[user][1], "role_ids": [role_id[role]]}), 201)

expect("read-only can list deals", call("GET", P + "/deals", "reader", A), 200)
expect("read-only can't create a deal", call("POST", P + "/deals", "reader", A, {"name": "x"}), 403)
expect("read-only can't run setup", call("POST", P + "/setup", "reader", A), 403)
expect("read-only can't edit templates", call("POST", P + "/workflow-templates/import", "reader", A, {"definition": definition}), 403)
expect("operator can create a property", call("POST", P + "/properties", "operator", A, {"address_line1": "1 Op St"}), 201)
expect("operator can't delete a property", call("DELETE", P + f"/properties/{prop['uuid']}", "operator", A), 403)
expect("operator can't change templates", call("PUT", P + f"/workflow-templates/{uk['uuid']}", "operator", A, {"name": "x"}), 403)
expect("agent can't create compliance checks (read only)", call("POST", P + "/compliance-checks", "agent", A,
       {"check_type": "aml_cdd_buyer", "subject_type": "deal", "deal_uuid": deal["uuid"]}), 403)
res = call("PUT", P + f"/compliance-checks/{chk['uuid']}", "agent", A, {"status": "passed"})
check("agent can't sign off compliance (403)", res[0] == 403, res)
expect("agent can update a task", call("PUT", P + f"/tasks/{task['task_uuid']}", "agent", A, {"pd_status": "agent_running"}), 200)
expect("agent can read approvals", call("GET", P + "/approvals", "agent", A), 200)

sys.exit(finish())
