# OpsAPI Marketing — AI agents

Agents plan campaigns, draft copy, segment audiences, analyse replies and
summarise deal impact. They use only tools registered in `lib/agent/tools.lua`
with explicit RBAC. They **cannot** override `can_send`, grant consent, or
cross tenants.

| Agent | File | Role |
|-------|------|------|
| Campaign planner | `campaign-planner.md` | Propose audience, channel, schedule |
| Email copywriter | `email-copywriter.md` | Draft subject + body with merge fields |
| Audience segmentation | `audience-segmentation.md` | Suggest list/segment rules |
| Reply analyst | `reply-analyst.md` | Classify inbound, suggest next step |
| Deal intelligence | `deal-intelligence.md` | Link engagement to CRM deals |
| Compliance | `policies/communication-compliance.md` | Loaded into every agent |

Destructive or high-risk tool calls require human-in-the-loop confirmation
(`Agent.run` confirm). Structured LLM JSON must be schema-validated before use.
