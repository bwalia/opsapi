"""The page assistant creates a deal when asked, and the deal autopilot takes it from there.

  * on a Property Deals page, "Create a deal for 7 Shambles, York YO1 9AB ..." makes the home and the deal through
    the API as the signed-in user (the assistant's model: the workspace's provider marked for the assistant)
  * each write carries an Idempotency-Key for that run, so a model repeating itself can't make a second deal
  * the deal is pinned and researched by itself (official area data on the deal)
  * someone whose role can't create deals (a builder) is refused by the API, and nothing is made
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, sql, workspace  # noqa: E402

M = "http://pd-mock:8080"
PAGE = "/dashboard/property-deals/deals"


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


W = workspace("owner_b", "Assistant Homes", "assistant-homes")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_b", W, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_b", W), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_b", W), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
by_name = {r["role_name"]: r for r in roles}
for user, role in (("operator_s", "pd_operator"), ("reader", "pd_builder")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_b", W,
           {"email": USERS[user][1], "role_ids": [by_name[role]["id"]]}), 201)
data(call("POST", P + "/connectors", "owner_b", W, {"kind": "postcodes", "name": "Postcodes", "config": {"base_url": M + "/pc"}}),
     201, "postcode lookup (the sandbox's postcodes.io)")
data(call("POST", API + "/api/v2/namespace/ai-providers", "owner_b", W, {"name": "Office model", "provider_type":
     "openai_compatible", "base_url": M + "/v1", "default_model": "qwen-local", "secret": "sk-local", "is_local": True,
     "options": {"assistant": True}}), 201, "the workspace's model, marked for the assistant")


def ask(user, text):
    run = expect(f"{user} asks", call("POST", API + "/api/chat/agent", user, W, {"message": text, "path": PAGE}), 202)
    run = run.get("run_uuid")
    for _ in range(120):
        c = call("GET", API + f"/api/chat/agent/conversation?path={PAGE}", user, W)[1] or {}
        if c.get("status") not in ("running", None):
            return run, c
        time.sleep(0.5)
    return run, {}


def actions(run):
    import json
    row = sql(f"SELECT actions::text FROM chat_agent_runs WHERE uuid = '{run}'")
    return json.loads(row[0]) if row else []


ns_id = sql(f"SELECT id FROM namespaces WHERE uuid = '{W}'")[0]
run, conv = ask("operator_s", "Create a deal for 7 Shambles, York YO1 9AB, we're buying, offer £250k")
check("the assistant finished", conv.get("status") == "done", conv)
reply = (conv.get("turns") or [{}])[-1].get("content", "")
check("...and says it created the deal, with a link", "Created [7 Shambles](/dashboard/property-deals/deals/" in reply, reply)
acts = actions(run)
check("two writes, both fine: the home, then the deal", [(a.get("args") or {}).get("path") for a in acts] ==
      ["/api/v2/property-deals/properties", "/api/v2/property-deals/deals"] and not any(a.get("error") for a in acts), acts)
deal = sql(f"""SELECT d.uuid || '|' || d.deal_type || '|' || d.offer_amount::int || '|' || p.address_line1 || '|'
               || (p.lat IS NOT NULL)::text FROM property_deals_deals d JOIN property_deals_properties p ON p.uuid = d.property_uuid
               WHERE d.namespace_id = {ns_id}""")
check("the deal is real: buying 7 Shambles at £250,000", len(deal) == 1 and deal[0].split("|")[1:4] == ["buy", "250000",
      "7 Shambles"], deal)
D = deal[0].split("|")[0] if deal else ""
keys = sql(f"SELECT COUNT(*) FROM idempotency_keys WHERE idem_key LIKE 'agent-%' AND namespace_id = {ns_id}")
check("each write carried the run's Idempotency-Key", keys == ["2"], keys)

v = {}
for _ in range(60):
    v = (call("GET", P + f"/deals/{D}/research", "operator_s", W)[1] or {}).get("data") or {}
    if v.get("run") and v["run"].get("status") != "running":
        break
    time.sleep(0.5)
steps = {s["key"]: s["status"] for s in v.get("steps", [])}
check("the autopilot picked the new deal up: pinned, with the official area data", steps.get("pin") == "done"
      and steps.get("facts") == "done" and (v.get("facts") or {}).get("crime"), v.get("steps"))

before = sql(f"SELECT COUNT(*) FROM property_deals_properties WHERE namespace_id = {ns_id}")
run2, conv2 = ask("reader", "Create a deal for 3 Low Petergate, York YO1 7AA, we're buying, offer £300k")
acts2 = actions(run2)
check("a builder asking is refused by the API (403)", acts2 and "403" in str(acts2[0].get("error")), acts2)
check("...and nothing was made", sql(f"SELECT COUNT(*) FROM property_deals_properties WHERE namespace_id = {ns_id}") == before)

# A model that can't call tools (here a speech model, refused the way Gemini refuses one) can't become the
# assistant: the save says why and the model already running it stays.
def assistant_flags():
    return sql(f"""SELECT name || '=' || COALESCE(options->>'assistant', 'false') FROM namespace_ai_providers
                   WHERE namespace_id = {ns_id} ORDER BY name""")


speech = data(call("POST", API + "/api/v2/namespace/ai-providers", "owner_b", W, {"name": "Speech model", "provider_type":
              "openai_compatible", "base_url": M + "/v1", "default_model": "tts-only", "secret": "sk-local",
              "is_local": True}), 201, "a speech model is added")
res = call("PUT", API + f"/api/v2/namespace/ai-providers/{speech.get('uuid')}", "owner_b", W, {"options": {"assistant": True}})
check("...but can't be made the assistant (422, says it needs a model that can call tools)",
      res[0] == 422 and "can't run the AI assistant" in str(res[1]) and "call tools" in str(res[1]), res)
check("...and the office model still runs the assistant", assistant_flags() == ["Office model=true", "Speech model=false"],
      assistant_flags())

# A workspace already stuck with such a model (set before this check existed) is told which one refused and where to
# change it, instead of "the assistant is unavailable, try again".
sql(f"UPDATE namespace_ai_providers SET options = jsonb_build_object('assistant', name = 'Speech model') WHERE namespace_id = {ns_id}")
_, conv3 = ask("operator_s", "How many deals do we have?")
reply3 = (conv3.get("turns") or [{}])[-1].get("content", "")
check("a stuck workspace hears which model refused and where to change it",
      "(Speech model) refused the request" in reply3 and "Workspace → AI providers" in reply3, reply3)

sys.exit(finish())
