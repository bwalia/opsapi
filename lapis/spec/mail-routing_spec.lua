--[[
    Spec: workspace email accounts and routing (helper/namespace-mail.lua).

    Run from the repo root: luajit lapis/spec/mail-routing_spec.lua
    Static/unit checks only; the SMTP sends, fallbacks and the migration were
    verified live against Mailpit (see the PR).
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
package.loaded["lapis.db"] = setmetatable({}, { __index = function() return function() return {} end end })

local function read(path)
    local f = assert(io.open(path) or io.open("lapis/" .. path), path)
    local s = f:read("*a")
    f:close()
    return s
end

local NamespaceMail = require("helper.namespace-mail")

print("purposes")
local keys = {}
for _, p in ipairs(NamespaceMail.PURPOSES) do keys[p.key] = p end
check("default comes first", NamespaceMail.PURPOSES[1].key == "default")
for _, k in ipairs({ "leads", "lead_followup", "team", "shop_orders", "shop_members", "invoices", "field_service",
    "forms", "billing" }) do
    check("purpose " .. k .. " exists", keys[k] ~= nil)
end
for _, p in ipairs(NamespaceMail.PURPOSES) do
    check(p.key .. " fits the routes CHECK constraint", p.key:match("^[a-z0-9_]+$") ~= nil and #p.key <= 40)
    check(p.key .. " has a name and description", (p.name or "") ~= "" and (p.description or "") ~= "")
end

print("templates are sent under the right purpose")
check("billing.* -> billing", NamespaceMail.templatePurpose("billing.access_link") == "billing")
check("forms.* -> forms", NamespaceMail.templatePurpose("forms.auto_reply") == "forms")
check("crm.* -> lead_followup", NamespaceMail.templatePurpose("crm.meeting_invite") == "lead_followup")
check("invitation -> team", NamespaceMail.templatePurpose("namespace.invitation") == "team")
check("shop order update -> shop_orders", NamespaceMail.templatePurpose("shop.order_update") == "shop_orders")
check("unknown -> default", NamespaceMail.templatePurpose("something.else") == "default")
for key in pairs(NamespaceMail.TEMPLATES) do
    check("template " .. key .. " maps to a known purpose", keys[NamespaceMail.templatePurpose(key)] ~= nil)
end

print("senders pick their purpose")
local function has(path, needle) return read(path):find(needle, 1, true) ~= nil end
check("lead capture uses the leads account", has("queries/CrmLeadNotificationQueries.lua", '"leads")'))
check("staff lead alerts use team", has("lib/crm/lead-notify.lua", 'smtp(ns, "team")'))
check("lead emails use lead_followup", has("lib/crm/lead-email.lua", '"lead_followup"'))
check("invoices", has("routes/invoices.lua", '"invoices")'))
check("purchase orders", has("routes/purchase-orders.lua", '"invoices")'))
check("field service quotes", has("routes/field-service-jobs.lua", '"field_service"'))
check("shop quotes", has("queries/ShopQuoteQueries.lua", '"shop_orders")'))
check("shop delivery changes", has("queries/ShopDeliveryChangeQueries.lua", '"shop_orders")'))
check("shop members", has("queries/ShopMembershipQueries.lua", '"shop_members")'))
check("forms", has("lib/forms/jobs.lua", '"forms")'))

print("async sends keep the workspace server")
check("Mail.send's async payload carries smtp", read("helper/mail.lua"):match("payload = cjson%.encode%b()"):find("smtp", 1, true) ~= nil)

print("migration")
local mig = read("migrations/namespace-mail.lua")
check("one default per workspace", mig:find("WHERE is_default", 1, true) ~= nil)
check("routes cascade when an account is deleted", mig:find("namespace_smtp_accounts(id) ON DELETE CASCADE", 1, true) ~= nil)
check("the single server is copied as the default", mig:find("FROM namespace_mail_settings s", 1, true) ~= nil)
check("registered in migrations.lua", read("migrations.lua"):find("namespace_mail_migrations, 3", 1, true) ~= nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
