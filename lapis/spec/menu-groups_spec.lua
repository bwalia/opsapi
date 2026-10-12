--[[
    Spec: sidebar groups (queries/MenuQueries.lua groupOf / groupsFor, routes/menu.lua).
    Every menu item a deployment seeds lands in its collapsible group (only Dashboard,
    AI Navigator and Settings stay outside), plugins get a group of their own unless an
    entry files itself under a built-in one, and /api/v2/user/menu returns the groups in
    sidebar order.

    Run from the repo root (what CI does):
        luajit lapis/spec/menu-groups_spec.lua
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

package.loaded["lapis.db"] = { NULL = {} }
local plugins = {
    { code = "property_deals", name = "Property Deals", icon = "Home" },
    { code = "helpdesk", name = "Helpdesk" },
}
package.loaded["helper.project-loader"] = { getRegistered = function() return plugins end }

local M = require("queries.MenuQueries")

-- Every menu key seeded today (int runs PROJECT_CODE=all), with the group it must land in.
local expected = {
    dashboard = false, chat = false, settings = false, my_tasks = false,
    crm = "sales", crm_leads = "sales", customers = "sales", forms = "sales",
    invoices = "finance", purchase_orders = "finance", accounting = "finance", document_templates = "finance",
    billing = "finance", billing_subscriptions = "finance", billing_licenses = "finance",
    shop = "commerce", orders = "commerce", products = "commerce", stores = "commerce", delivery = "commerce",
    projects = "work", timesheets = "work", employees = "work",
    field_service_requests = "field_service", field_service_jobs = "field_service",
    field_service_visits = "field_service", field_service_assets = "field_service",
    field_service_parts = "field_service", field_service_contracts = "field_service",
    field_service_reports = "field_service", field_service_simpro = "field_service",
    hospitals = "healthcare", patients = "healthcare", care_home = "healthcare",
    tax = "tax", tax_bank_accounts = "tax", tax_statements = "tax", tax_transactions = "tax", tax_reports = "tax",
    tax_categories = "tax", tax_file = "tax", tax_hmrc = "tax",
    cms = "content", academy = "content",
    namespace = "admin", users = "admin", roles = "admin", activity = "admin", reports = "admin",
    plugins = "admin", namespaces = "admin",
    ["api-keys"] = "developer", webhooks = "developer", vault = "developer", domains = "developer",
    services = "developer",
    ["plugin:property_deals:today"] = "plugin:property_deals", ["plugin:property_pa:capture"] = "plugin:property_pa",
}
local wrong = {}
for key, group in pairs(expected) do
    local got = M.groupOf({ key = key, settings = "{}" })
    if got ~= (group or nil) then wrong[#wrong + 1] = key .. "=" .. tostring(got) end
end
table.sort(wrong)
check("every seeded menu item lands in its group", #wrong == 0, table.concat(wrong, ", "))

local known = {}
for _, g in ipairs(M.GROUPS) do known[g.key] = true end
local unknown = {}
for key, group in pairs(M.GROUP_OF) do
    if not known[group] then unknown[#unknown + 1] = key .. "->" .. group end
end
check("GROUP_OF only names defined groups", #unknown == 0, table.concat(unknown, ", "))

check("a new field service page joins Field Service by its key prefix",
    M.groupOf({ key = "field_service_quotes" }) == "field_service")
check("an unknown module stays at the top level", M.groupOf({ key = "something_new" }) == nil)

-- settings.group (a JSON string from the DB, or already decoded)
check("settings.group moves an item", M.groupOf({ key = "crm", settings = '{"group":"finance"}' }) == "finance")
check("settings.group as a table", M.groupOf({ key = "x", settings = { group = "tax" } }) == "tax")
check("a plugin page filed under a built-in group",
    M.groupOf({ key = "plugin:helpdesk:tickets", settings = '{"group":"sales"}' }) == "sales")
check("an unknown settings.group is ignored",
    M.groupOf({ key = "crm", settings = '{"group":"<script>"}' }) == "sales")
check("broken settings JSON is ignored", M.groupOf({ key = "crm", settings = "{not json" }) == "sales")

-- groupsFor: only the groups in use, in sidebar order, plugins just before Administration.
local items = {
    { key = "users", group = "admin" }, { key = "crm", group = "sales" }, { key = "dashboard" },
    { key = "plugin:helpdesk:tickets", group = "plugin:helpdesk" }, { key = "api-keys", group = "developer" },
    { key = "plugin:property_deals:today", group = "plugin:property_deals" }, { key = "invoices", group = "finance" },
}
local order = {}
for _, g in ipairs(M.groupsFor(items)) do order[#order + 1] = g.key end
check("groups in sidebar order, unused ones left out",
    table.concat(order, ",") == "sales,finance,plugin:property_deals,plugin:helpdesk,admin,developer",
    table.concat(order, ","))
local by = {}
for _, g in ipairs(M.groupsFor(items)) do by[g.key] = g end
check("a plugin group is named after the plugin, with its icon",
    by["plugin:property_deals"].name == "Property Deals" and by["plugin:property_deals"].icon == "Home")
check("a plugin without an icon gets the generic one", by["plugin:helpdesk"].icon == "Puzzle")
check("no groups when nothing is grouped", #M.groupsFor({ { key = "dashboard" } }) == 0)

-- The route returns them, and every filtered item carries its group.
local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
check("/api/v2/user/menu returns the groups",
    read("lapis/routes/menu.lua"):find("groups = MenuQueries.groupsFor(main_menu)", 1, true) ~= nil)
check("menu items carry their group",
    read("lapis/queries/MenuQueries.lua"):find("group = MenuQueries.groupOf(item)", 1, true) ~= nil)
check("plugin menu sync stores an entry's group",
    read("lapis/helper/project-migrator.lua"):find("encode({ group = e.group })", 1, true) ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) failed."))
os.exit(failures == 0 and 0 or 1)
