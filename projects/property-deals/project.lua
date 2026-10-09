-- Property Deals — back office for buying and selling homes (OpsAPI plugin).
-- Spec: docs/property-deals/SPEC.md · Design: docs/property-deals/00-gap-map.md
--
-- Builds on CRM (leads, contacts, companies, deals) and kanban (tasks, epics):
-- a property deal IS a crm_deals row, a deal task IS a kanban task. The tables
-- here only hold what those don't (see the gap map), so the plugin needs both
-- features. Without them it switches itself off instead of failing migrations.
local ProjectConfig = require("helper.project-config")

local function module(machine_name, name, description)
    return { machine_name = machine_name, name = name, category = "Property deals", description = description }
end

return {
    code = "property_deals",      -- stable id: keys migrations + RBAC; never rename
    name = "Property Deals",
    version = "0.1.0",
    description = "Deals from first lead to completion: workflow, deadlines, compliance, suppliers and AI agents.",
    sdk_version = 1,
    depends = { "core", "crm", "kanban" },
    enabled = ProjectConfig.isCrmEnabled() and ProjectConfig.isKanbanEnabled(),
    default_enabled = false,      -- opt-in per workspace (Workspace -> Plugins)

    modules = {
        module("property_deals_deals", "Deals", "Deals, parties, seller leads and the deal timeline"),
        module("property_deals_properties", "Properties", "Property records, valuations and documents"),
        module("property_deals_buyers", "Buyers", "Buyer profiles and matches"),
        module("property_deals_tasks", "Tasks", "Deal tasks, enquiries and the chase log"),
        module("property_deals_suppliers", "Suppliers", "Supplier directory and bookings"),
        module("property_deals_compliance", "Compliance", "Compliance checks and evidence"),
        module("property_deals_approvals", "Approvals", "Approve or reject drafts and gated actions"),
        module("property_deals_ai", "AI agents", "Run agents and read their runs"),
        module("property_deals_settings", "Settings", "Workflow templates, connectors, AI providers and weights"),
        module("property_deals_reports", "Reports", "Pipeline, speed and AI usage reports"),
        -- opsapi:modules (make:resource adds entries above this line)
    },

    -- Change events (property_deals.<entity>.created/updated/deleted) plus
    -- business verbs. Engine events (stage_changed, health_changed,
    -- task.overdue, task.escalated, compliance.expiring) are emitted by code.
    publishes = {
        deal = { table = "property_deals_deals",
                 verbs = { completed = { status = "completed" }, fell_through = { status = "fell_through" } } },
        property = { table = "property_deals_properties" },
        buyer_profile = { table = "property_deals_buyer_profiles" },
        task = { table = "property_deals_task_details",
                 verbs = { done = { pd_status = "done" }, awaiting_approval = { pd_status = "awaiting_approval" } } },
        enquiry = { table = "property_deals_enquiries" },
        chase = { table = "property_deals_chases" },
        supplier = { table = "property_deals_suppliers" },
        booking = { table = "property_deals_bookings",
                    verbs = { confirmed = { status = "confirmed" }, cancelled = { status = "cancelled" } } },
        compliance_check = { table = "property_deals_compliance_checks",
                             verbs = { passed = { status = "passed" }, failed = { status = "failed" } } },
        approval = { table = "property_deals_approvals",
                     verbs = { requested = { status = "pending" }, approved = { status = "approved" },
                               rejected = { status = "rejected" } } },
        match = { table = "property_deals_matches" },
        -- opsapi:publishes (make:resource adds entries above this line)
    },

    pages = {
        -- opsapi:pages (make:page adds entries above this line)
    },

    -- Simple lists use the generated plugin pages; the main screens (Today,
    -- deals, map, approvals...) are native dashboard pages (gap map D7).
    menu = {
        { label = "Bank holidays", resource = "holidays", module = "property_deals_settings", icon = "CalendarDays" },
        -- opsapi:menu (make:resource adds entries above this line)
    },

    -- Scalar settings per workspace. Lists and nested config (templates, AI
    -- providers, connectors) live in their own tables.
    settings = {
        timezone = { type = "string", label = "Workspace time zone", default = "Europe/London",
                     description = "IANA zone used for working days, digests and due times." },
        jurisdiction = { type = "string", label = "Holiday calendar", default = "england-and-wales",
                         enum = { "england-and-wales", "scotland", "northern-ireland" },
                         description = "Bank holidays used for working-day maths." },
        currency = { type = "string", label = "Currency", default = "GBP", min = 3, max = 3 },
        digest_time = { type = "string", label = "Daily digest time (local)", default = "07:30",
                        description = "HH:MM in the workspace time zone." },
        sla_warn_pct = { type = "integer", label = "SLA warning at (%)", default = 75, min = 1, max = 99 },
        sla_breach_pct = { type = "integer", label = "SLA breach at (%)", default = 100, min = 50, max = 300 },
        sla_reassign_pct = { type = "integer", label = "Reassign at (%)", default = 125, min = 100, max = 500 },
        red_min_working_days = { type = "integer", label = "Red when fewer working days remain than", default = 10,
                                 min = 0, max = 60,
                                 description = "...and the deal still has open blockers." },
    },
}
