"""Review fixes (October 2026): the rules people relied on hold through every door.

  * a deal is marked completed only from its last stage with no blocking task open (409 lists what's missing)
  * a task's approval rule covers closing it: "two_person" goes through request-completion and two other people,
    "manager" needs a manager; only a manager changes the rule or the compliance flag; the AI account closes
    neither a compliance task nor one with a rule; nothing changes a task's status while its approval waits
  * builders don't see identity, AML or proof-of-funds documents
  * a task whose deadline had passed when its clock started is overdue at once; on-hold deals' tasks wait; a dead
    deal's tasks and pending drafts are cancelled; a target date set later starts the waiting tasks' clocks
  * a JobShout draft can't be edited here (JobShout would send its own); a silent JobShout run times out
  * email bodies don't reach the audit trail
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, sql, workspace  # noqa: E402


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


W = workspace("owner_a", "Fixes Homes Ltd", "fixes-homes")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_a", W, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_a", W), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_a", W), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
by_name = {r["role_name"]: r for r in roles}
for user, role in (("manager_s", "pd_manager"), ("operator_s", "pd_operator"), ("reader", "pd_builder"),
                   ("agent", "pd_agent")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_a", W,
           {"email": USERS[user][1], "role_ids": [by_name[role]["id"]]}), 201)

prop = data(call("POST", P + "/properties", "operator_s", W, {"address_line1": "9 Rule Street", "town": "York",
            "postcode": "YO1 7AA"}), 201, "property")
deal = data(call("POST", P + "/deals", "operator_s", W, {"property_uuid": prop["uuid"], "deal_type": "buy",
            "name": "9 Rule Street"}), 201, "deal")
D = deal["uuid"]

# --- Completing a deal ----------------------------------------------------------------------------------------------
res = call("PUT", P + f"/deals/{D}", "manager_s", W, {"status": "completed"})
missing = ((res[1] or {}).get("details") or {}).get("missing") or [] if isinstance(res[1], dict) else []
check("completed from the first stage is refused (409)", res[0] == 409, res)
check("...saying the deal hasn't reached its last stage", any(m.get("type") == "stage" for m in missing), missing)
check("the deal is still active", data(call("GET", P + f"/deals/{D}", "operator_s", W), 200, "deal").get("status")
      == "active")


# --- Task approval rules --------------------------------------------------------------------------------------------
def task(rule, **extra):
    body = {"deal_uuid": D, "title": f"Pay out ({rule})", "approval_rule": rule}
    body.update(extra)
    return data(call("POST", P + "/tasks", "operator_s", W, body), 201, f"task with rule {rule}")["task_uuid"]


T2 = task("two_person")
res = call("PUT", P + f"/tasks/{T2}", "manager_s", W, {"pd_status": "done"})
check("two_person: even a manager can't close it directly (409)", res[0] == 409, res)
res = call("PUT", P + f"/tasks/{T2}", "operator_s", W, {"approval_rule": "none"})
check("an operator can't lower the rule (403)", res[0] == 403, res)
res = call("PUT", P + f"/tasks/{T2}", "operator_s", W, {"compliance": True, "title": "renamed"})
check("an operator can't change the compliance flag (403)", res[0] == 403, res)
a = data(call("POST", P + f"/tasks/{T2}/request-completion", "operator_s", W, {"note": "Funds sent, ref 123"}), 201,
         "operator asks for sign-off")
check("the approval carries the task's own rule", a.get("rule") == "two_person" and a.get("action") == "complete_task", a)
t = data(call("GET", P + f"/tasks/{T2}", "operator_s", W), 200, "task")
check("the task waits for approval", t.get("pd_status") == "awaiting_approval", t.get("pd_status"))
res = call("PUT", P + f"/tasks/{T2}", "operator_s", W, {"pd_status": "todo"})
check("its status can't move while the approval waits (409)", res[0] == 409, res)
res = call("POST", P + f"/tasks/{T2}/request-completion", "operator_s", W, {})
check("asking twice is refused (409)", res[0] == 409, res)
res = call("POST", P + f"/approvals/{a['uuid']}/decide", "operator_s", W, {"decision": "approve"})
check("the asker can't approve their own request (403)", res[0] == 403, res)
d1 = data(call("POST", P + f"/approvals/{a['uuid']}/decide", "manager_s", W, {"decision": "approve"}), 200, "first approval")
check("one approval isn't enough", d1.get("status") == "pending", d1.get("status"))
data(call("POST", P + f"/approvals/{a['uuid']}/decide", "owner_a", W, {"decision": "approve"}), 200, "second approval")
t = data(call("GET", P + f"/tasks/{T2}", "operator_s", W), 200, "task")
check("two approvals close the task", t.get("pd_status") == "done", t.get("pd_status"))
check("...with the note as evidence", "Funds sent" in str(t.get("evidence")), t.get("evidence"))

TM = task("manager")
res = call("PUT", P + f"/tasks/{TM}", "operator_s", W, {"pd_status": "done"})
check("manager rule: an operator can't close it (409)", res[0] == 409, res)
res = call("PUT", P + f"/tasks/{TM}", "agent", W, {"pd_status": "done"})
check("the AI account can't close a task with a rule (403)", res[0] == 403, res)
data(call("PUT", P + f"/tasks/{TM}", "manager_s", W, {"pd_status": "done"}), 200, "a manager closes it")
TN = task("none")
data(call("PUT", P + f"/tasks/{TN}", "operator_s", W, {"pd_status": "done"}), 200, "no rule: an operator closes it")

# --- Documents ------------------------------------------------------------------------------------------------------
ns_id = sql(f"SELECT id FROM namespaces WHERE uuid = '{W}'")[0]
docs = {}
for cat in ("id", "survey"):
    docs[cat] = sql(f"""INSERT INTO property_deals_documents (namespace_id, deal_uuid, category, filename, object_key,
        source) VALUES ({ns_id}, '{D}', '{cat}', '{cat}.pdf', 'k/{cat}', 'upload') RETURNING uuid""")[0]
seen = [x["category"] for x in data(call("GET", P + f"/documents?deal_uuid={D}", "reader", W), 200, "builder lists")]
check("a builder sees the survey but not the ID", seen == ["survey"], seen)
check("...and can't open the ID by id (404)", call("GET", P + f"/documents/{docs['id']}", "reader", W)[0] == 404)
seen = sorted(x["category"] for x in data(call("GET", P + f"/documents?deal_uuid={D}", "operator_s", W), 200, "op lists"))
check("an operator sees both", seen == ["id", "survey"], seen)

# --- SLA ------------------------------------------------------------------------------------------------------------
late = task("none", due_at="2020-01-01T09:00:00Z", sla_minutes=60)
data(call("POST", P + "/engine/run", "manager_s", W, {"checks": ["sla"]}), 200, "SLA tick")
row = sql(f"SELECT (sla_breached_at IS NOT NULL)::text FROM property_deals_task_details WHERE task_uuid = '{late}'")
check("a task born past its deadline is overdue at once", row == ["true"], row)

hold_prop = data(call("POST", P + "/properties", "operator_s", W, {"address_line1": "1 Pause Lane", "postcode": "YO1 7AA"}),
                 201, "property 2")
hold = data(call("POST", P + "/deals", "operator_s", W, {"property_uuid": hold_prop["uuid"], "deal_type": "buy"}), 201,
            "deal 2")["uuid"]
data(call("PUT", P + f"/deals/{hold}", "manager_s", W, {"status": "on_hold"}), 200, "deal on hold")
held = data(call("POST", P + "/tasks", "operator_s", W, {"deal_uuid": hold, "title": "Waits", "due_at": "2020-01-01T09:00:00Z",
            "sla_minutes": 60}), 201, "task on the held deal")["task_uuid"]
data(call("POST", P + "/engine/run", "manager_s", W, {"checks": ["sla"]}), 200, "SLA tick")
row = sql(f"SELECT (sla_breached_at IS NULL)::text FROM property_deals_task_details WHERE task_uuid = '{held}'")
check("an on-hold deal's tasks wait", row == ["true"], row)

pending = data(call("POST", P + "/approvals", "operator_s", W, {"subject_type": "chase", "action": "send_email",
               "title": "Chase", "payload": {"to": "x@example.invalid"}, "deal_uuid": hold}), 201, "a draft waits")
data(call("PUT", P + f"/deals/{hold}", "manager_s", W, {"status": "fell_through"}), 200, "deal falls through")
row = sql(f"SELECT pd_status FROM property_deals_task_details WHERE task_uuid = '{held}'")
check("a dead deal's tasks are cancelled", row == ["cancelled"], row)
row = sql(f"SELECT status FROM property_deals_approvals WHERE uuid = '{pending['uuid']}'")
check("...and its waiting drafts can't be sent", row == ["cancelled"], row)

# Tasks counted back from the target exchange date (the buyer's funds and AML, a parallel stage that starts with
# Enquiries) have no clock while the deal has no target date.
data(call("POST", P + f"/deals/{D}/stage", "manager_s", W, {"to": "enquiries"}), 200, "move to Enquiries")
rows = sql(f"""SELECT (sla_started_at IS NULL)::text FROM property_deals_task_details
               WHERE deal_uuid = '{D}' AND template_key IN ('buyer_funds', 'buyer_aml')""")
check("without a target date they have no clock", len(rows) == 2 and all(r == "true" for r in rows), rows)
data(call("PUT", P + f"/deals/{D}", "manager_s", W, {"target_completion_date": "2031-06-30",
     "target_exchange_date": "2031-06-16"}), 200, "set the target dates")
rows = sql(f"""SELECT (sla_started_at IS NOT NULL AND due_at IS NOT NULL)::text FROM property_deals_task_details
               WHERE deal_uuid = '{D}' AND template_key IN ('buyer_funds', 'buyer_aml')""")
check("setting the target starts the clocks of tasks counted back from it", rows and all(r == "true" for r in rows), rows)

# --- JobShout -------------------------------------------------------------------------------------------------------
ja = sql(f"""INSERT INTO property_deals_approvals (namespace_id, subject_type, action, title, payload, payload_sha256,
    rule, jobshout_approval_id) VALUES ({ns_id}, 'agent_draft', 'jobshout:send_email', 'JobShout draft',
    '{{"body": "hi"}}', 'x', 'any_operator', 'js-1') RETURNING uuid""")[0]
res = call("POST", P + f"/approvals/{ja}/decide", "manager_s", W, {"decision": "approve", "payload": {"body": "edited"}})
check("a JobShout draft can't be edited (409)", res[0] == 409, res)
jt = task("none")
sql(f"""INSERT INTO property_deals_agent_runs (namespace_id, task_uuid, agent_key, provider, status, created_at,
        started_at) VALUES ({ns_id}, '{jt}', 'legal_chaser', 'jobshout', 'running', NOW() - interval '3 hours',
        NOW() - interval '3 hours')""")
data(call("POST", P + "/engine/run", "manager_s", W, {"checks": ["agents"]}), 200, "agents tick")
row = sql(f"SELECT status FROM property_deals_agent_runs WHERE task_uuid = '{jt}'")
check("a JobShout run silent for hours times out", row == ["failed"], row)

# --- Audit trail ----------------------------------------------------------------------------------------------------
sql(f"""INSERT INTO property_deals_inbound_messages (namespace_id, external_id, from_address, subject, body_text)
        VALUES ({ns_id}, 'm-1', 'sol@example.invalid', 'Re: enquiries', 'very private words')""")
sql(f"UPDATE property_deals_inbound_messages SET body_text = NULL WHERE namespace_id = {ns_id} AND external_id = 'm-1'")
row = sql(f"""SELECT COUNT(*) FROM audit_events WHERE namespace_id = {ns_id}
              AND (COALESCE(old_values::text, '') || COALESCE(new_values::text, '')) LIKE '%very private words%'""")
check("email bodies stay out of the audit trail", row == ["0"], row)
row = sql(f"""SELECT COUNT(*) FROM audit_events WHERE namespace_id = {ns_id}
              AND entity_type LIKE '%inbound_message%'""")
check("...while the message itself is still audited", int(row[0]) >= 1, row)

sys.exit(finish())
