#!/usr/bin/env python3
"""Phase 5: AI tools stay draft-only; knowledge scope file present; reply tool never sends."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, USERS, call, check, enable, expect, finish, new_uuid, sql, workspace,
)

# Knowledge file shipped with core
know = os.path.join(os.path.dirname(__file__), "../../../lapis/lib/agent/knowledge/opsapi-marketing.md")
check("knowledge file exists", os.path.isfile(know), know)
with open(know) as f:
    text = f.read()
check("knowledge has tools front-matter", "mkt_draft_campaign" in text and "mkt_classify_reply" in text, text[:400])
check("knowledge forbids auto-send", "Never" in text or "never" in text.lower(), text[:800])

A = workspace("owner_a", "Mkt AI", "mkt-ai-" + new_uuid()[:8])
enable("owner_a", A)

# Draft via API mimics what the tool creates (tool itself needs live agent loop;
# we assert the draft contract + ai_actions table + classify never sends).
camp = expect("create draft like tool", call("POST", P + "/campaigns", "owner_a", A, {
    "name": "AI draft",
    "channel": "email",
    "message_type": "marketing",
    "status": "draft",
    "subject": "Hello",
    "body_html": "<p>Hi</p><a href=\"{{unsubscribe_url}}\">u</a>",
    "body_text": "Hi {{unsubscribe_url}}",
}), 201)
cid = (camp.get("data") or camp).get("uuid")
check("stays draft", (camp.get("data") or camp).get("status") == "draft", camp)

# Cannot schedule without validate/approve path when we force awaiting — ensure draft blocked
blocked = call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", A, {"send_now": True})
check("draft schedule blocked or needs validate", blocked[0] in (400, 422), blocked)

# Classify via API (same path agent tool uses)
prev = expect("agent-style classify", call("POST", P + "/replies/classify-preview", "owner_a", A, {
    "body_text": "Can we book a meeting next week on your calendar?",
}), 200)
pd = prev.get("data") or prev
check("meeting class", pd.get("classification") == "meeting", prev)
check("auto_send false", pd.get("auto_send") is False, prev)

# Record an AI action row (simulates tool audit)
sql(f"""
INSERT INTO mkt_ai_actions (namespace_id, user_uuid, agent, action, status, input_summary, requires_approval, campaign_uuid)
SELECT id, '{USERS["owner_a"][0]}', 'campaign-planner', 'draft_campaign', 'executed', 'AI draft', false, '{cid}'
FROM namespaces WHERE uuid = '{A}' LIMIT 1;
""")
rows = sql(f"""
SELECT a.action || '|' || a.status FROM mkt_ai_actions a
JOIN namespaces n ON n.id = a.namespace_id
WHERE n.uuid = '{A}' AND a.campaign_uuid = '{cid}'::uuid
""")
check("ai action audited", any("draft_campaign" in r for r in rows), rows)

# Tools registered in tools.lua
tools_lua = os.path.join(os.path.dirname(__file__), "../../../lapis/lib/agent/tools.lua")
with open(tools_lua) as f:
    tl = f.read()
for name in ("mkt_campaign_overview", "mkt_audience_preview", "mkt_draft_campaign",
             "mkt_classify_reply", "mkt_check_eligibility"):
    check(f"tool registered {name}", f'name = "{name}"' in tl, name)

sys.exit(finish())
