-- AI agent runs and approvals (read side; the run/approve flow arrives in Phase 5).
--   GET /agent-runs, /agent-runs/:id          ?task_uuid=&deal_uuid=&agent_key=&status=&provider=
--   GET /approvals, /approvals/:id            ?status=pending&deal_uuid=&subject_type=&rule=
local sdk = require("helper.plugin-sdk")

return function(app)
    sdk.crud(app, "/agent-runs", {
        table = "property_deals_agent_runs",
        module = "property_deals_ai",
        only = { "list", "show" },
        fields = {
            task_uuid = { type = "uuid" }, deal_uuid = { type = "uuid" }, agent_key = { type = "string" },
            status = { enum = { "queued", "running", "succeeded", "failed", "cancelled" } },
            provider = { type = "string" }, model = { type = "string" },
        },
        filterable = { "task_uuid", "deal_uuid", "agent_key", "status", "provider" },
        sortable = { "created_at", "cost_usd", "latency_ms" },
    })

    sdk.crud(app, "/approvals", {
        table = "property_deals_approvals",
        module = "property_deals_approvals",
        only = { "list", "show" },
        fields = {
            status = { enum = { "pending", "approved", "rejected", "cancelled", "executed", "failed" } },
            deal_uuid = { type = "uuid" }, task_uuid = { type = "uuid" }, agent_run_uuid = { type = "uuid" },
            subject_type = { enum = { "agent_draft", "chase", "booking", "compliance_close", "offer", "deal_pack",
                                      "stage_gate", "other" } },
            rule = { enum = { "any_operator", "manager", "two_person" } },
            action = { type = "string" }, title = { type = "string" },
        },
        filterable = { "status", "deal_uuid", "task_uuid", "agent_run_uuid", "subject_type", "rule" },
        searchable = { "title" },
        sortable = { "created_at", "decided_at" },
    })
end
