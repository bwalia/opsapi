--[[
    Spec: workspace email accounts and which account sends each kind of email
    (helper/namespace-mail.lua).

    The list of kinds is open-ended: features (and plugins, via email_kinds in
    project.lua) declare theirs with NamespaceMail.kind(); a kind used without
    being declared is recorded on first use and still listed on Workspace → Email.

    Run from the repo root: luajit lapis/spec/mail-routing_spec.lua
    Static/unit checks only; the SMTP sends and fallbacks are verified live on INT.
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

ngx = setmetatable({ log = function() end, ERR = 3, WARN = 4, time = os.time, now = os.time, ctx = {}, var = {} }, -- luacheck: ignore 111
    { __index = function() return function() end end })

-- A database that remembers recorded kinds (namespace_mail_kinds) and nothing else.
local recorded_rows, inserts = {}, 0
package.loaded["lapis.db"] = setmetatable({
    NULL = setmetatable({}, { __tostring = function() return "NULL" end }),
    query = function(sql, a)
        if sql:find("INSERT INTO namespace_mail_kinds", 1, true) then
            inserts = inserts + 1
            recorded_rows[a] = true
            return {}
        end
        if sql:find("SELECT key FROM namespace_mail_kinds", 1, true) then
            local out = {}
            for k in pairs(recorded_rows) do out[#out + 1] = { key = k } end
            table.sort(out, function(x, y) return x.key < y.key end)
            return out
        end
        if sql:find("SELECT 1 FROM namespace_mail_kinds", 1, true) then
            return recorded_rows[a] and { { ["?column?"] = 1 } } or {}
        end
        return {}
    end,
}, { __index = function() return function() return {} end end })

local disabled = { shop = true } -- a deployment without the shop
package.loaded["helper.project-config"] = { isFeatureEnabled = function(f) return not disabled[f] end }

local function read(path)
    local f = assert(io.open(path) or io.open("lapis/" .. path), path)
    local s = f:read("*a")
    f:close()
    return s
end

local NamespaceMail = require("helper.namespace-mail")

local function listed()
    local by, order = {}, {}
    for _, k in ipairs(NamespaceMail.kinds()) do by[k.key] = k; order[#order + 1] = k.key end
    return by, order
end

print("built-in kinds")
local by, order = listed()
check("default comes first", order[1] == "default", order[1])
for _, k in ipairs({ "leads", "lead_followup", "crm_meetings", "crm_partner_referrals", "field_service", "invoices",
    "purchase_orders", "team", "invitations", "employee_welcome", "forms", "forms_auto_reply", "billing", "tax_filing" }) do
    check("kind " .. k .. " is listed", by[k] ~= nil)
end
for key, k in pairs(by) do
    check(key .. " fits the routes CHECK constraint", key:match("^[a-z][a-z0-9_]*$") ~= nil and #key <= 40)
    check(key .. " has a name, group and description", (k.name or "") ~= "" and (k.group or "") ~= ""
        and (k.description or "") ~= "")
end
check("a deployment without the shop doesn't list shop kinds", by.shop_quotes == nil and by.shop_orders == nil)
disabled.shop = nil
by = listed()
check("with the shop, quotations, order updates, member emails and alerts are listed",
    by.shop_quotes and by.shop_orders and by.shop_members and by.shop_alerts)

print("rows come grouped, in page order")
local _, ord = listed()
local seen_group, last_group, regrouped = {}, nil, false
for _, key in ipairs(ord) do
    local g = by[key].group
    if g ~= last_group then
        if seen_group[g] then regrouped = true end
        seen_group[g] = true
        last_group = g
    end
end
check("each group's rows are together", not regrouped)

print("a feature declares its own kind (dynamic)")
NamespaceMail.kind("quotes_demo", { name = "Demo quotations", group = "Sales", description = "A test kind." })
by = listed()
check("a newly declared kind is listed with its name and group", by.quotes_demo and by.quotes_demo.name == "Demo quotations"
    and by.quotes_demo.group == "Sales")
check("a bad key is refused", not pcall(NamespaceMail.kind, "Bad Key", { name = "x" }))

print("a kind used without being declared still appears")
check("no records yet", inserts == 0)
NamespaceMail.smtp(7, "visit_reminders")
NamespaceMail.smtp(7, "visit_reminders")
check("first use records it once per process", inserts == 1, inserts)
NamespaceMail.smtp(7, "leads")
NamespaceMail.smtp(7, "default")
NamespaceMail.smtp(7)
check("declared kinds and the default aren't recorded", inserts == 1, inserts)
NamespaceMail.smtp(7, "Not A Key")
check("a malformed key isn't recorded", inserts == 1, inserts)
by = listed()
check("it is listed under Other, named from its key",
    by.visit_reminders and by.visit_reminders.group == "Other" and by.visit_reminders.name == "Visit reminders",
    by.visit_reminders and by.visit_reminders.name)

print("saving the routing")
local ok, err = NamespaceMail.saveRouting(7, "me", { made_up_kind = require("cjson").null })
check("an unknown kind is refused", not ok and tostring(err):find("unknown kind", 1, true), err)
ok = NamespaceMail.saveRouting(7, "me", { visit_reminders = require("cjson").null })
check("a recorded kind can be routed", ok ~= nil)
ok = NamespaceMail.saveRouting(7, "me", { quotes_demo = require("cjson").null, leads = require("cjson").null })
check("declared kinds can be routed", ok ~= nil)

print("templates are sent as their kind")
for key, t in pairs(NamespaceMail.TEMPLATES) do
    check("template " .. key .. " names a listed kind", t.kind and by[t.kind] ~= nil, t.kind)
end
check("meetings", NamespaceMail.templatePurpose("crm.meeting_reminder") == "crm_meetings")
check("partner referrals", NamespaceMail.templatePurpose("crm.partner_referral") == "crm_partner_referrals")
check("invitations", NamespaceMail.templatePurpose("namespace.invitation") == "invitations")
check("form auto-replies", NamespaceMail.templatePurpose("forms.auto_reply") == "forms_auto_reply")
check("unknown template -> default", NamespaceMail.templatePurpose("something.else") == "default")

print("plugins declare their kinds in project.lua")
local loader = read("helper/project-loader.lua")
check("email_kinds is validated", loader:find("email_kinds[\" .. i .. \"] looks like", 1, true) ~= nil)
check("and registered under the plugin's name", loader:find('pcall(require("helper.namespace-mail").kind, k.key', 1, true) ~= nil
    and loader:find("group = k.group or manifest.name", 1, true) ~= nil)
local function plugin(path) local f = io.open(path) or io.open("../" .. path); local s = f:read("*a"); f:close(); return s end
check("Marketing declares marketing", plugin("projects/opsapi-marketing/project.lua"):find('key = "marketing"', 1, true) ~= nil)
check("and sends with it", plugin("projects/opsapi-marketing/opsapi_marketing/send.lua"):find('smtp(d.namespace_id, "marketing")', 1, true) ~= nil
    and plugin("projects/opsapi-marketing/opsapi_marketing/channels/email.lua"):find('smtp(ns, "marketing")', 1, true) ~= nil)
check("Property Deals declares property_deals", plugin("projects/property-deals/project.lua"):find('key = "property_deals"', 1, true) ~= nil)
check("and sends with it", plugin("projects/property-deals/property_deals/ai/executor.lua"):find('smtp(ns, "property_deals")', 1, true) ~= nil)

print("senders use their kind")
local function has(path, needle) return read(path):find(needle, 1, true) ~= nil end
check("new enquiries", has("queries/CrmLeadNotificationQueries.lua", '"leads")'))
check("staff lead alerts", has("lib/crm/lead-notify.lua", 'smtp(ns, "team")'))
check("emails to leads", has("lib/crm/lead-email.lua", '"lead_followup"'))
check("invoices", has("routes/invoices.lua", '"invoices")'))
check("purchase orders", has("routes/purchase-orders.lua", '"purchase_orders")'))
check("field service quotations", has("routes/field-service-jobs.lua", '"field_service"'))
check("shop quotations", has("queries/ShopQuoteQueries.lua", '"shop_quotes")'))
check("shop order updates", has("queries/ShopDeliveryChangeQueries.lua", 'smtp(o.namespace_id, "shop_orders")'))
check("shop member emails", has("queries/ShopMembershipQueries.lua", 'smtp(ns_id, "shop_members")'))
for _, f in ipairs({ "queries/ShopOrderQueries.lua", "queries/ShopCostQueries.lua", "queries/ShopDeliveryChangeQueries.lua",
    "queries/ShopMembershipQueries.lua" }) do
    check("shop alerts to the team: " .. f, has(f, 'purpose = "shop_alerts"'))
end
check("forms", has("lib/forms/jobs.lua", '"forms")'))
check("new team member accounts", has("routes/employees.lua", '"employee_welcome"'))
check("tax return requests", has("routes/tax-filing.lua", '"tax_filing"'))

print("async sends keep the workspace server")
check("Mail.send's async payload carries smtp", read("helper/mail.lua"):match("payload = cjson%.encode%b()"):find("smtp", 1, true) ~= nil)

print("migration")
local mig = read("migrations/namespace-mail.lua")
check("one default per workspace", mig:find("WHERE is_default", 1, true) ~= nil)
check("routes cascade when an account is deleted", mig:find("namespace_smtp_accounts(id) ON DELETE CASCADE", 1, true) ~= nil)
check("the single server is copied as the default", mig:find("FROM namespace_mail_settings s", 1, true) ~= nil)
check("recorded kinds have a table", mig:find("CREATE TABLE IF NOT EXISTS namespace_mail_kinds", 1, true) ~= nil)
for _, pair in ipairs({ { "purchase_orders", "invoices" }, { "shop_quotes", "shop_orders" }, { "shop_alerts", "shop_orders" },
    { "crm_meetings", "lead_followup" }, { "crm_partner_referrals", "lead_followup" }, { "invitations", "team" },
    { "forms_auto_reply", "forms" } }) do
    check(pair[1] .. " starts on " .. pair[2] .. "'s account", mig:find('"' .. pair[1] .. '", "' .. pair[2] .. '"', 1, true) ~= nil)
end
local registry = read("migrations.lua")
check("registered in migrations.lua", registry:find("namespace_mail_migrations, 3", 1, true) ~= nil
    and registry:find("'zznm6_namespace_mail_kinds'] = conditional_array(ProjectConfig.FEATURES.CORE, namespace_mail_migrations, 4)", 1, true) ~= nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
