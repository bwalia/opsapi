"""The PA: workspace playbook + one-call briefing, and the opt-in platform model.

  * the playbook is seeded once (UK property default) and is the workspace's own after that; managers edit it
  * the briefing has the person's tasks, hot leads, approvals, deals at risk, fresh news and the playbook
  * the platform model can only be added when the deployment's model is self-hosted
"""
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, jwt, workspace  # noqa: E402


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


S = workspace("owner_s", "PA Homes", "pa-homes")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_s", S), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_s", S), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
role_id = {r["role_name"]: r["id"] for r in roles}
expect("add operator", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
       {"email": USERS["operator_s"][1], "role_ids": [role_id["pd_operator"]]}), 201)

# --- Playbook -------------------------------------------------------------------------------------------------------
pb = data(call("GET", P + "/playbooks", "operator_s", S), 200, "playbook")
keys = [s["key"] for s in pb]
check("default playbook seeded in order", keys[:3] == ["who_we_are", "roles", "daily_rhythm"] and "escalation" in keys, keys)
check("sections have content", all(len(s["body"]) > 50 for s in pb), [s["key"] for s in pb if len(s["body"]) <= 50])
res = call("PUT", P + "/playbooks/seller_call", "operator_s", S, {"body": "x"})
check("operators can't edit the playbook (403)", res[0] == 403, res)
ed = data(call("PUT", P + "/playbooks/seller_call", "owner_s", S, {"body": "Always ask about the deadline first."}),
          200, "edit a section")
check("edited", ed["body"] == "Always ask about the deadline first." and ed["title"] == "Seller call script", ed)
res = call("PUT", P + "/playbooks/landlord_call", "owner_s", S, {"body": "no title"})
check("a new section needs a title (422)", res[0] == 422, res)
new = data(call("PUT", P + "/playbooks/landlord_call", "owner_s", S, {"title": "Landlord call", "body": "Ask about tenants."}),
           200, "add a section")
check("new section added", new["key"] == "landlord_call", new)
res = call("PUT", P + "/playbooks/Bad-Key", "owner_s", S, {"title": "x"})
check("bad key refused (422)", res[0] == 422, res)
again = data(call("POST", P + "/setup", "owner_s", S), 200, "setup again")
pb2 = data(call("GET", P + "/playbooks", "operator_s", S), 200, "playbook after setup")
check("setup never overwrites the workspace's playbook",
      next(s for s in pb2 if s["key"] == "seller_call")["body"] == "Always ask about the deadline first."
      and len(pb2) == len(pb) + 1, len(pb2))
check("delete a section", expect("delete", call("DELETE", P + "/playbooks/landlord_call", "owner_s", S), 200))

# --- Briefing -------------------------------------------------------------------------------------------------------
lead = expect("lead", call("POST", API + "/api/v2/crm/leads", "operator_s", S, {"first_name": "Bea", "last_name": "Brief",
              "owner_user_uuid": USERS["operator_s"][0]}), 201)
lead = (lead.get("data") or lead)["uuid"]
data(call("POST", P + "/tasks", "operator_s", S, {"title": "Call Bea back", "lead_uuid": lead,
     "owner_user_uuid": USERS["operator_s"][0], "due_at": "2020-01-01T10:00:00Z", "blocking": True}), 201, "an overdue task")
data(call("POST", P + f"/leads/{lead}/signals", "operator_s", S, {"kind": "social_post", "text": "Bought our 5th HMO!"}),
     201, "fresh news")
b = data(call("GET", P + "/pa/briefing", "operator_s", S), 200, "briefing")
check("knows who I am", b["me"]["name"] and b["me"]["is_manager"] is False, b["me"])
check("my overdue task is in it", any(t["title"] == "Call Bea back" and t["overdue"] for t in b["my_tasks"])
      and b["counts"]["overdue"] >= 1, b["my_tasks"])
check("fresh news about my lead", any(n["title"].startswith("Bought our 5th HMO") for n in b["fresh_news"]), b["fresh_news"])
check("the playbook (as edited) is in it", "Always ask about the deadline first." in b["playbook"]
      and "## Who we are" in b["playbook"], b["playbook"][:200])
for k in ("hot_leads", "approvals_waiting", "deals_at_risk"):
    check(f"briefing has {k}", isinstance(b.get(k), list), b.get(k))
res = call("GET", P + "/pa/briefing", "owner_b", S)
check("non-members get no briefing", res[0] in (401, 403, 404), res)

# --- Platform model (opt-in, self-hosted only) ------------------------------------------------------------------------
res = call("POST", API + "/api/v2/namespace/ai-providers", "owner_s", S, {"name": "Platform", "provider_type": "platform"})
check("platform model refused when the deployment has none self-hosted (422 with why)",
      res[0] == 422 and "platform model" in str(res[1]).lower(), res)

# --- Voice for the assistant (our own voice server; mock in the sandbox) -------------------------------------------
def raw(method, path, body, ctype, user="operator_s"):
    req = urllib.request.Request(API + path, data=body, method=method,
                                 headers={"Authorization": "Bearer " + jwt(user), "Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


st = data(call("GET", API + "/api/v2/voice/status", "operator_s", S), 200, "voice status")
check("voice is on when VOICE_URL is set", st == {"stt": True, "tts": True, "voice": "bf_emma"}, st)
code, body, _ = raw("POST", "/api/v2/voice/transcribe", b"FAKE-AUDIO-BYTES", "audio/webm;codecs=opus")
check("speech → text (multipart to our voice server, trimmed)", code == 200
      and '"What needs my attention today?"' in body.decode(), (code, body[:200]))
code, body, _ = raw("POST", "/api/v2/voice/transcribe", b"x", "text/plain")
check("non-audio refused (415)", code == 415, code)
code, body, _ = raw("POST", "/api/v2/voice/transcribe", b"", "audio/webm")
check("empty audio refused (400)", code == 400, code)
code, body, hdrs = raw("POST", "/api/v2/voice/speak", b'{"text": "Hello Sarah", "voice": "bm_george"}', "application/json")
check("text → mp3 in the chosen voice", code == 200 and body == b"ID3-FAKE-MP3:bm_george"
      and hdrs.get("Content-Type", "").startswith("audio/mpeg"), (code, body[:60], hdrs.get("Content-Type")))
code, body, _ = raw("POST", "/api/v2/voice/speak", b'{"text": "   "}', "application/json")
check("nothing to say refused (400)", code == 400, code)
req = urllib.request.Request(API + "/api/v2/voice/speak", data=b'{"text":"hi"}', method="POST",
                             headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=30)
    anon = 200
except urllib.error.HTTPError as e:
    anon = e.code
check("voice needs a signed-in user (401)", anon == 401, anon)

sys.exit(finish())
