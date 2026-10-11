-- Property PA — the AI PA for property professionals (OpsAPI plugin).
-- Product: docs/property-pa/PRD.md · Design: docs/property-pa/00-gap-map.md
--
-- "The CRM is the system of record; the PA is the system of work." This plugin is the system-of-record
-- side: people, properties, opportunities, interactions, offers, events, versioned knowledge, proposed
-- updates (fact vs inference), handoffs and the AI change history. The agents themselves (Seller PA,
-- Manager PA) run in JobShout and act on these records only through this API.
--
-- Builds on CRM (contacts = people, accounts = organisations, activities = interactions), kanban (tasks)
-- and the property_deals plugin (properties, deals, tasks with urgency), whose migrations run first.
local ProjectConfig = require("helper.project-config")

local function module(machine_name, name, description)
    return { machine_name = machine_name, name = name, category = "Property PA", description = description }
end

return {
    code = "property_pa",          -- stable id: keys migrations + RBAC; never rename
    name = "Property PA",
    version = "0.1.0",
    description = "AI PA for property professionals: talk to your PA, the CRM updates underneath.",
    sdk_version = 1,
    depends = { "core", "crm", "kanban" },
    enabled = ProjectConfig.isCrmEnabled() and ProjectConfig.isKanbanEnabled(),
    default_enabled = false,       -- opt-in per workspace (Workspace -> Plugins), with property_deals

    modules = {
        module("property_pa_records", "PA records", "People, properties, opportunities, interactions, offers and events"),
        module("property_pa_updates", "PA proposed updates", "Confirm, correct or reject what the PA extracted"),
        module("property_pa_knowledge", "PA knowledge", "Company and personal rules the PA follows (approve = manage)"),
        module("property_pa_handoffs", "PA handoffs", "Questions passed between agents and managers"),
        -- opsapi:modules (make:resource adds entries above this line)
    },

    publishes = {
        opportunity = { table = "pa_opportunities" },
        proposed_update = { table = "pa_proposed_updates",
            verbs = { confirmed = { status = "confirmed" }, corrected = { status = "corrected" },
                      rejected = { status = "rejected" } } },
        handoff = { table = "pa_handoffs", verbs = { replied = { status = "replied" } } },
        knowledge = { table = "pa_knowledge", verbs = { approved = { status = "approved" } } },
        -- opsapi:publishes (make:resource adds entries above this line)
    },

    pages = {
        -- opsapi:pages (make:page adds entries above this line)
    },

    menu = {
        -- Native pages in opsapi-dashboard/app/dashboard/property-pa.
        { label = "PA today", route = "/dashboard/property-pa/today", module = "property_pa_records", icon = "Sunrise" },
        { label = "PA capture", route = "/dashboard/property-pa/capture", module = "property_pa_records", icon = "NotebookPen" },
        { label = "My opportunities", route = "/dashboard/property-pa/opportunities", module = "property_pa_records",
          icon = "Users" },
        { label = "PA knowledge", route = "/dashboard/property-pa/knowledge", module = "property_pa_knowledge",
          icon = "BookOpen" },
        -- opsapi:menu (make:resource adds entries above this line)
    },

    -- The agents run in JobShout (gap map §5): the workspace's JobShout link (Workspace -> AI providers, a jsk_
    -- API key), the agents installed by JobShout's POST /property-pa/install, and the webhook secret of the
    -- JobShout endpoint pointed at /api/v2/property-pa/public/jobshout/events.
    settings = {
        jobshout_provider_uuid = { type = "string", label = "JobShout link (AI provider id)", default = "" },
        jobshout_project_id = { type = "string", label = "JobShout project id", default = "" },
        jobshout_seller_agent_id = { type = "string", label = "JobShout Seller PA agent id", default = "" },
        jobshout_manager_agent_id = { type = "string", label = "JobShout Manager PA agent id", default = "" },
        jobshout_webhook_secret = { type = "string", label = "JobShout webhook secret", secret = true,
            description = "Verifies run.completed / run.failed deliveries (X-JobShout-Signature)." },
        material_fields = { type = "string", label = "Fields that always need a person to confirm",
            default = "expectation_price,offer_amount,decision_makers,next_action_at",
            description = "Comma separated. Proposed updates to these are never applied without confirmation." },
    },
}
