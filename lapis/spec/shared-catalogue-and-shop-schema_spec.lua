--[[
    Spec: two follow-ups from the 16 Nov review.
    1. Tax categories: the shared catalogue is every row whose key doesn't carry its own
       namespace ("ns<id>_"), whatever namespace_id it sits in (diy's migration 994 moved
       it into the tax-copilot namespace), so every workspace still sees it and only a
       workspace's own categories can be edited or deleted.
    2. Shop payments need the membership schema (shop_orders.credit_minor, shop_credits)
       with SHOP alone; it used to need BILLING too, so the `ecommerce` preset couldn't take
       a payment.
    Run from the repo root: /usr/local/openresty/luajit/bin/luajit lapis/spec/shared-catalogue-and-shop-schema_spec.lua
]]

local failures = 0
local function check(name, ok, detail)
    local why = (not ok and detail ~= nil) and ("  (" .. tostring(detail) .. ")") or ""
    print((ok and "  ok   - " or "  FAIL - ") .. name .. why)
    if not ok then failures = failures + 1 end
end
local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end

print("== tax categories")
local cats = read("lapis/routes/tax-categories.lua")
local list_at = cats:find('app:get("/api/v2/tax/categories",', 1, true)
local create_at = cats:find('app:post("/api/v2/tax/categories",', 1, true)
local clause_at = cats:find("OR NOT starts_with(key, 'ns' || namespace_id || '_')", 1, true)
check("list shows the shared catalogue wherever it lives",
    list_at and clause_at and create_at and list_at < clause_at and clause_at < create_at)
local _, edits = cats:gsub("AND starts_with%(key, 'ns' || namespace_id || '_'%) LIMIT 1", "")
check("edit and delete only touch this workspace's own categories", edits == 2, edits)
local own_key = assert(load(cats:match("(local function own_key%(r%).-\nend)") .. "\nreturn own_key"))()
check("ns7_x in namespace 7 is that workspace's own", own_key({ key = "ns7_x", namespace_id = 7 }))
check("office_costs in the tax-copilot namespace is shared", not own_key({ key = "office_costs", namespace_id = 7 }))
check("another workspace's prefix doesn't count", not own_key({ key = "ns9_x", namespace_id = 7 }))
check("NULL namespace is shared", not own_key({ key = "ns7_x" }))

print("== shop payments schema")
local mig = read("lapis/migrations.lua")
check("membership schema loads with SHOP alone",
    mig:find('local shop_membership_migrations = load_if_enabled(ProjectConfig.FEATURES.SHOP, "migrations.shop-membership")', 1, true))
check("...and no longer needs BILLING", not mig:find("ProjectConfig.FEATURES.BILLING))\n    and require(\"migrations.shop-membership\")", 1, true))

if failures > 0 then print(failures .. " FAILED") os.exit(1) end
print("all passed")
