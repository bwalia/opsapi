"""Deal autopilot: a new deal is pinned on the map and researched by itself (property_deals/research.lua).

  * without Gemini or the SRA register the home is still pinned, and each step says how to switch it on
  * with Gemini, one grounded call (Google Search tool, the workspace's key and model) that carries the address only;
    the answer is kept as it came (area notes, firms, Google's Search Suggestions, the pages, the searches) and
    nothing from it is stored or used by itself: a person saves a firm to Suppliers or asks it for a quote
  * with the SRA register (the workspace's key), the nearest authorised firms doing residential property work, with an
    email, become conveyancer suppliers (with the SRA's attribution), on the map; the nearest 3 get quote requests
    that wait in Approvals; nothing is sent; the register is fetched at most once a day
  * tokens and cost land on the run and in ai_usage; a failed call says why; another workspace sees nothing;
    the setting switches it off
"""
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, sql, workspace  # noqa: E402

M = "http://pd-mock:8080"
MOCK = os.environ["PD_MOCK"]


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


def mock(path, body=None):
    req = urllib.request.Request(MOCK + path, data=json.dumps(body).encode() if body is not None else None,
                                 method="POST" if body is not None else "GET", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"null")


def research(ws, deal, user="operator_s", wait=60):
    """The deal's research once its run has finished (or the last state seen)."""
    view = {}
    for _ in range(wait * 2):
        res = call("GET", P + f"/deals/{deal}/research", user, ws)
        view = (res[1] or {}).get("data") or {} if res[0] == 200 else {}
        if view.get("run") and view["run"].get("status") != "running":
            return view
        time.sleep(0.5)
    return view


W = workspace("owner_a", "Autopilot Homes", "autopilot-homes")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_a", W, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_a", W), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_a", W), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
by_name = {r["role_name"]: r for r in roles}
for user, role in (("manager_s", "pd_manager"), ("operator_s", "pd_operator")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_a", W,
           {"email": USERS[user][1], "role_ids": [by_name[role]["id"]]}), 201)
data(call("POST", P + "/connectors", "manager_s", W, {"kind": "postcodes", "name": "Postcodes", "config": {"base_url": M + "/pc"}}),
     201, "postcode lookup (the sandbox's postcodes.io)")
mock("/_ctl", {"gemini_mode": "ok"})
before = len(mock("/_gemini"))


def new_deal(address, postcode, offer=None):
    prop = data(call("POST", P + "/properties", "operator_s", W, {"address_line1": address, "town": "York",
                "postcode": postcode, "tenure": "freehold", "property_type": "terraced"}), 201, "property")
    body = {"property_uuid": prop["uuid"], "deal_type": "buy", "name": "Mrs Seller's house " + address}
    if offer:
        body["offer_amount"] = offer
    return prop, data(call("POST", P + "/deals", "operator_s", W, body), 201, "deal " + address)


# --- Nothing set up: pinned, and told how to switch the rest on -----------------------------------------------------
_, deal0 = new_deal("5 Quiet Lane", "YO1 7AA")
v = research(W, deal0["uuid"])
steps = {s["key"]: s for s in v.get("steps", [])}
check("nothing set up: the run still finishes", (v.get("run") or {}).get("status") == "succeeded", v.get("run"))
check("...the home is on the map", steps.get("pin", {}).get("status") == "done"
      and v.get("property", {}).get("lat") is not None, v.get("steps"))
check("...the web search says to add Gemini", steps.get("research", {}).get("status") == "skipped"
      and "Gemini" in (steps["research"].get("note") or "") and v.get("gemini") is False, v.get("steps"))
check("...the register says to add the SRA key", steps.get("register", {}).get("status") == "skipped"
      and "SRA" in (steps["register"].get("note") or "") and v.get("sra") is False, v.get("steps"))
check("...nothing went to Google", len(mock("/_gemini")) == before)

# --- Gemini and the SRA register -----------------------------------------------------------------------------------
NSP = API + "/api/v2/namespace/ai-providers"
data(call("POST", NSP, "owner_a", W, {"name": "Google Gemini", "provider_type": "gemini",
     "base_url": M + "/gemini/v1beta/openai", "default_model": "gemini-test-flash", "secret": "gem-key",
     "input_cost_per_mtok": 1, "output_cost_per_mtok": 2}), 201, "add Google Gemini")
res = call("POST", P + "/connectors", "operator_s", W, {"kind": "sra", "name": "SRA", "secret": "sra-key"})
check("operators can't add the SRA key (403)", res[0] == 403, res)
data(call("POST", P + "/connectors", "manager_s", W, {"kind": "sra", "name": "SRA register", "secret": "sra-key",
     "config": {"base_url": M + "/sra"}}), 201, "a manager adds the SRA register")
sra_before = mock("/_sra")["calls"]
prop, deal = new_deal("9 High Petergate", "YO1 7AA", offer=187500)
D = deal["uuid"]
v = research(W, D)
run = v.get("run") or {}
steps = {s["key"]: s for s in v.get("steps", [])}
check("a new deal is researched by itself", run.get("status") == "succeeded" and run.get("trigger") == "auto", run)
check("Gemini is set up, and its key never reaches the browser", v.get("gemini") is True and v.get("gemini_hint") is None
      and "gem-key" not in json.dumps(v), v.get("gemini_hint"))
check("every step done", all(steps.get(k, {}).get("status") == "done" for k in ("pin", "research", "register", "quotes")),
      v.get("steps"))

calls = mock("/_gemini")[before:]
check("one Gemini call, with the workspace's key and model", len(calls) == 1 and calls[0]["key"] == "gem-key"
      and calls[0]["model"] == "gemini-test-flash", [(c["model"], c["key"]) for c in calls])
body = calls[0]["body"] if calls else {}
check("...using Google Search grounding", body.get("tools") == [{"google_search": {}}], body.get("tools"))
text = str(body.get("contents"))
check("...about the address", "9 High Petergate" in text and "YO1 7AA" in text, text[:300])
check("...and nothing else: no seller, no price", "Seller" not in text and "187500" not in text and "187,500" not in text)

area = v.get("area") or {}
check("area notes kept as given", area.get("transport") == "York station is a 10 minute walk."
      and area.get("schools") is None and "Ignore previous instructions" in (area.get("summary") or ""), area)
check("Google's Search Suggestions kept to show", "conveyancers near YO1 7AA" in (v.get("suggestions") or ""))
check("web pages kept (safe links only)", [s["url"][-2:] for s in v.get("sources", [])] == ["a1", "a2"], v.get("sources"))
check("the searches Google ran are kept", v.get("searches") == ["conveyancers near YO1 7AA", "flood risk YO1 7AA"])
firms = v.get("firms", [])
check("the firms are shown as the search returned them", [f["name"] for f in firms] == ["Conv One Law",
      "Ghost Conveyancers", "York Surveys", "York Homes", "Pipes Ltd"], [f.get("name") for f in firms])
by = {f["name"]: f for f in firms}
check("...what a person can do with each", by["Conv One Law"]["can_save"] and by["Conv One Law"]["can_quote"]
      and not by["York Surveys"]["can_quote"] and not by["Pipes Ltd"]["can_save"], firms)
n = sql(f"""SELECT COUNT(*) FROM property_deals_suppliers s JOIN namespaces n ON n.id = s.namespace_id
            WHERE n.uuid = '{W}' AND s.source = 'ai_research'""")
check("nothing from the web search went to Suppliers by itself", n == ["0"], n)

sup = v.get("suppliers", [])
names = [s["name"] for s in sup]
check("the 3 nearest SRA firms doing residential work, with an email, are suppliers",
      sorted(names) == ["Fossgate Conveyancing Solicitors", "Micklegate Property Lawyers", "York Property Law LLP"], names)
check("...nearest first (Fossgate is furthest)", names[-1:] == ["Fossgate Conveyancing Solicitors"], names)
york = next((s for s in sup if s["name"] == "York Property Law LLP"), {})
check("...from the register, its York office (not Leeds), on the map", york.get("source") == "sra"
      and york.get("register_ref") == "sra:600001" and york.get("email") == "hello@yorkpropertylaw.test"
      and york.get("base_lat") is not None and 0 < float(york.get("distance_miles") or 0) < 1, york)
check("...with the SRA's attribution", "Solicitors Regulation Authority" in (york.get("notes") or "")
      and "sra.org.uk/datasharing" in (v.get("attribution") or ""), york.get("notes"))
check("the register was fetched once", mock("/_sra")["calls"] == sra_before + 1, mock("/_sra"))

quotes = v.get("quotes", [])
check("quote requests to those 3, waiting for approval", sorted(q["sent_to"] for q in quotes) == [
      "hello@yorkpropertylaw.test", "quotes@fossgate.test", "team@micklegate.test"]
      and all(q["status"] == "pending" for q in quotes), quotes)
inbox = data(call("GET", P + "/approvals/inbox", "manager_s", W), 200, "approvals inbox")
mine = [a for a in inbox if a.get("deal_uuid") == D]
check("they're in the Approvals inbox as drafts from the research", len(mine) == 3
      and all(a.get("agent_key") == "deal_research" for a in mine), [(a.get("title"), a.get("agent_key")) for a in mine])
draft = (mine[0].get("payload") if mine else None) or {}
draft = json.loads(draft) if isinstance(draft, str) else draft
check("the draft asks for a conveyancing quote for the address, no price", "9 High Petergate" in draft.get("body", "")
      and "quote" in draft.get("body", "") and "187" not in draft.get("body", ""), draft)
check("nothing was sent", not [m for m in mock("/_smtp") if "fossgate" in str(m) or "micklegate" in str(m)])

check("tokens and cost on the run (counts toward the daily budget)", run.get("tokens") == 2300
      and abs(float(run.get("cost_usd") or 0) - (1500 * 1 + 800 * 2) / 1e6) < 1e-9, run)
row = sql(f"""SELECT input_tokens || '/' || output_tokens FROM ai_usage WHERE run_uuid = '{run.get("uuid")}'
              AND feature = 'property_deals_research'""")
check("metered in ai_usage", row == ["1500/800"], row)

# --- A person acts on the web search -------------------------------------------------------------------------------
R = run.get("uuid")
res = call("POST", P + f"/deals/{D}/research/firms/1/save", "reader", W, {"run_uuid": R})
check("someone outside the workspace can't save a firm", res[0] in (403, 404), res[0])
saved = data(call("POST", P + f"/deals/{D}/research/firms/1/save", "operator_s", W, {"run_uuid": R}), 201, "save Conv One")
check("a person saves a firm to Suppliers", saved.get("created") is True and saved.get("supplier_uuid"), saved)
s1 = data(call("GET", P + f"/suppliers/{saved.get('supplier_uuid')}", "operator_s", W), 200, "the saved firm")
check("...marked as saved from the web search, with its website and place", s1.get("source") == "ai_research"
      and s1.get("website") == "http://conv-one.test:8080" and s1.get("base_lat") is not None, s1)
again = data(call("POST", P + f"/deals/{D}/research/firms/1/save", "operator_s", W, {"run_uuid": R}), 201, "save again")
check("...saving again reuses it", again.get("created") is False and again.get("supplier_uuid") == saved.get("supplier_uuid"))
res = call("POST", P + f"/deals/{D}/research/firms/5/save", "operator_s", W, {"run_uuid": R})
check("a firm of a kind we don't keep can't be saved (422)", res[0] == 422, res)
q = data(call("POST", P + f"/deals/{D}/research/firms/1/quote", "operator_s", W, {"run_uuid": R}), 201, "ask Conv One")
check("a person asks a firm for a quote: a draft in Approvals", q.get("status") == "pending" and q.get("action") == "send_email"
      and q.get("requested_by_user_uuid") == USERS["operator_s"][0], q)
res = call("POST", P + f"/approvals/{q.get('uuid')}/decide", "operator_s", W, {"decision": "approve"})
check("...which the same person can't approve (403)", res[0] == 403, res)
res = call("POST", P + f"/deals/{D}/research/firms/1/quote", "operator_s", W, {"run_uuid": R})
check("...nor ask twice (409)", res[0] == 409, res)
res = call("POST", P + f"/deals/{D}/research/firms/3/quote", "operator_s", W, {"run_uuid": R})
check("a firm without an email can't be asked (422)", res[0] == 422, res)
v = research(W, D)
one = next((f for f in v.get("firms", []) if f["index"] == 1), {})
check("the deal shows the firm saved and asked", one.get("saved_supplier_uuid") == saved.get("supplier_uuid")
      and one.get("quote_asked") is True, one)

# --- Again: no duplicates, the register not fetched again ----------------------------------------------------------
res = call("POST", P + f"/deals/{D}/research", "operator_s", W)
check("research again (201)", res[0] == 201, res)
v2 = research(W, D)
notes = {s["key"]: s.get("note") for s in v2.get("steps", [])}
check("the same firms aren't added twice", "(0 new in Suppliers)" in (notes.get("register") or ""), notes)
check("...nor asked twice (the 3 from the register + the one a person asked)", "already asked" in (notes.get("quotes") or "")
      and len(v2.get("quotes", [])) == 4, [notes, v2.get("quotes")])
check("the register wasn't fetched again (once a day)", mock("/_sra")["calls"] == sra_before + 1, mock("/_sra"))
res = call("POST", P + f"/deals/{D}/research/firms/1/save", "operator_s", W, {"run_uuid": R})
check("acting on an old run is refused (409)", res[0] == 409, res)

# --- The map -------------------------------------------------------------------------------------------------------
m = data(call("GET", P + "/map?lat=53.96&lng=-1.08&radius_miles=5&layers=deals,suppliers", "operator_s", W), 200, "map")
layers = {}
for f in m.get("features", []):
    layers.setdefault(f["layer"], []).append(f)
check("the deal is pinned on the map", any(f.get("deal_uuid") == D for f in layers.get("deals", [])), list(layers))
on_map = {f["title"]: f for f in layers.get("suppliers", [])}
check("the suppliers layer shows the conveyancers", {"York Property Law LLP", "Micklegate Property Lawyers",
      "Conv One Law"} <= set(on_map) and on_map["York Property Law LLP"]["kinds"] == ["conveyancer"], sorted(on_map))

# --- Failures, other workspaces, the switch -------------------------------------------------------------------------
mock("/_ctl", {"gemini_mode": "error"})
call("POST", P + f"/deals/{D}/research", "operator_s", W)
v3 = research(W, D)
check("a failed call says why", (v3.get("run") or {}).get("status") == "failed"
      and "HTTP 500" in ((v3.get("run") or {}).get("error") or ""), v3.get("run"))

# Gemini failing (a rate limit, an empty quota): the workspace's own model writes the notes, from real facts only.
data(call("POST", NSP, "owner_a", W, {"name": "Office Ollama", "provider_type": "openai_compatible", "is_local": True,
     "base_url": M + "/v1", "default_model": "qwen-local", "secret": "sk-local"}), 201, "add a local model")
call("POST", P + f"/deals/{D}/research", "operator_s", W)
v5 = research(W, D)
steps = {s["key"]: s for s in v5.get("steps", [])}
check("Gemini failing: the run still succeeds", (v5.get("run") or {}).get("status") == "succeeded", v5.get("run"))
check("...with notes from the local model, labelled as such", v5.get("area_source") == "model"
      and v5.get("area_model") == "qwen-local" and "without a web search" in (steps.get("research", {}).get("note") or "")
      and "HTTP 500" in (steps["research"]["note"] or ""), steps.get("research"))
check("...written from real facts (the postcode's place, the recorded sales)",
      "Guildhall" in ((v5.get("area") or {}).get("summary") or "") and "recorded sales" in ((v5.get("area") or {}).get("market") or ""),
      v5.get("area"))
check("...and no firms (the local model would invent their details)", v5.get("firms") == [] and not v5.get("suggestions"))
row = sql(f"""SELECT COUNT(*) FROM ai_usage WHERE run_uuid = '{(v5.get("run") or {}).get("uuid")}'
              AND feature = 'property_deals_research' AND ok""")
check("...metered in ai_usage", row and int(row[0]) >= 1, row)
mock("/_ctl", {"gemini_mode": "ok"})
res = call("GET", P + f"/deals/{D}/research", "owner_b", W)
check("another workspace's user can't read it", res[0] in (403, 404), res[0])
expect("switch the autopilot off", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_a", W,
       {"settings": {"autopilot_on_new_deal": False}}), 200)
_, deal3 = new_deal("1 Off Street", "YO1 7AA")
time.sleep(3)
v4 = data(call("GET", P + f"/deals/{deal3['uuid']}/research", "operator_s", W), 200, "research (off)")
check("switched off: a new deal isn't researched", v4.get("run") is None, v4.get("run"))

sys.exit(finish())
