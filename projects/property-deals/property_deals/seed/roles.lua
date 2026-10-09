-- Workspace roles for Property Deals (SPEC §3.11). Created on setup when a
-- workspace has no role of that name; never overwritten afterwards, so a
-- workspace's own edits stick. Owners and admins already get `manage` on every
-- property_deals module when the plugin is installed.
local R, CRU = { "read" }, { "create", "read", "update" }

return {
    {
        role_name = "pd_operator", display_name = "Property Deals — Operator", priority = 30,
        description = "Runs deals day to day: tasks, chases, bookings; approves plain operator-level drafts",
        landing_path = "/dashboard/property-deals/today",
        permissions = {
            property_deals_deals = CRU, property_deals_properties = CRU, property_deals_buyers = CRU,
            property_deals_tasks = CRU, property_deals_suppliers = CRU, property_deals_compliance = CRU,
            property_deals_approvals = { "read", "update" }, property_deals_ai = { "create", "read" },
            property_deals_settings = R, property_deals_reports = R,
        },
    },
    {
        role_name = "pd_manager", display_name = "Property Deals — Manager", priority = 50,
        description = "Everything an operator can do, plus manager-only approvals, templates and settings",
        landing_path = "/dashboard/property-deals/today",
        permissions = {
            property_deals_deals = { "manage" }, property_deals_properties = { "manage" },
            property_deals_buyers = { "manage" }, property_deals_tasks = { "manage" },
            property_deals_suppliers = { "manage" }, property_deals_compliance = { "manage" },
            property_deals_approvals = { "manage" }, property_deals_ai = { "manage" },
            property_deals_settings = { "manage" }, property_deals_reports = { "manage" },
        },
    },
    {
        role_name = "pd_compliance", display_name = "Property Deals — Compliance officer", priority = 40,
        description = "Signs off AML, ID and other compliance checks; reads deals",
        landing_path = "/dashboard/property-deals/compliance",
        permissions = {
            property_deals_compliance = { "manage" }, property_deals_approvals = { "read", "update" },
            property_deals_deals = R, property_deals_properties = R, property_deals_buyers = R,
            property_deals_tasks = { "read", "update" }, property_deals_suppliers = R, property_deals_reports = R,
        },
    },
    {
        -- Service account for AI agents. It drafts and works tasks; it can never
        -- decide an approval (no approvals.update) or change settings.
        role_name = "pd_agent", display_name = "Property Deals — AI agent (service account)", priority = 10,
        description = "Used by AI agents: read context, update tasks, write drafts. Cannot approve.",
        permissions = {
            property_deals_deals = R, property_deals_properties = { "read", "update" }, property_deals_buyers = R,
            property_deals_tasks = { "read", "update" }, property_deals_suppliers = R,
            property_deals_compliance = R, property_deals_approvals = { "create", "read" },
            property_deals_ai = { "create", "read", "update" },
        },
    },
    {
        role_name = "pd_read_only", display_name = "Property Deals — Read only", priority = 5,
        description = "Sees deals, tasks and reports; changes nothing (investor portal later)",
        permissions = {
            property_deals_deals = R, property_deals_properties = R, property_deals_buyers = R,
            property_deals_tasks = R, property_deals_suppliers = R, property_deals_compliance = R,
            property_deals_approvals = R, property_deals_reports = R,
        },
    },
}
