--[[
    Billing & Entitlements — discount coupons and upgrade paths
    ===========================================================
    docs/BILLING_ENTITLEMENTS.md §5 / §13. Both are data an admin manages:

    Coupons (per workspace, optionally per app and per plan): percent or a
    fixed amount off, once / for N months / forever (recurring), with dates and
    redemption limits. Redeeming is atomic, so max_redemptions holds under load.

    Upgrade paths (per app): from plan -> to plan, priced as the price
    `difference`, a `fixed` amount, or `free`.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Common = require("queries.FieldServiceCommon")
local Apps = require("queries.BillingAppQueries")
local Subs = require("queries.BillingSubscriptionQueries")

local Offers = {}

local function ts(v, name)
    v = Common.nilify(v)
    if v == nil then return db.NULL end
    if type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d") then
        return nil, name .. " must be an ISO-8601 date/time, or null"
    end
    return db.raw(db.escape_literal(v) .. "::timestamptz")
end

local function int_or_null(v, name, min)
    if v == nil then return nil end
    if v == cjson.null or v == "" then return db.NULL end
    local n = tonumber(v)
    if not n or n ~= math.floor(n) or n < min then return nil, name .. " must be a whole number from " .. min end
    return n
end

-- ---------------------------------------------------------------------------
-- Coupons
-- ---------------------------------------------------------------------------

local COUPON_SELECT = [[
    SELECT c.uuid, c.code, c.name, c.discount_type, c.percent_off::float AS percent_off, c.amount_off, c.currency,
           c.duration, c.duration_months, c.plan_ids, c.max_redemptions, c.per_customer_limit, c.redemptions_count,
           c.starts_at, c.expires_at, c.active, c.created_at, c.updated_at, a.uuid AS app_uuid, a.name AS app_name
    FROM billing_coupons c LEFT JOIN billing_apps a ON a.id = c.app_id
]]

local function present_coupon(row)
    if not row then return nil end
    -- Plan ids -> uuids for the API.
    local ids = row.plan_ids
    if type(ids) == "table" and #ids > 0 then
        local plans = db.query("SELECT uuid FROM billing_plans WHERE id IN ?", db.list(ids))
        local out = {}
        for i, p in ipairs(plans) do out[i] = p.uuid end
        row.plans = Common.arr(out)
    else
        row.plans = nil
    end
    row.plan_ids = nil
    return row
end

function Offers.listCoupons(namespace_id, params)
    local where, vals = { "c.namespace_id = ?", "c.deleted_at IS NULL" }, { namespace_id }
    if Common.nilify(params.app) then
        where[#where + 1] = "(a.uuid = ? OR a.slug = ?)"
        vals[#vals + 1], vals[#vals + 2] = params.app, params.app
    end
    if Common.nilify(params.search) then
        where[#where + 1] = "c.code ILIKE ?"
        vals[#vals + 1] = "%" .. tostring(params.search):upper():gsub("[%%_\\]", "\\%0") .. "%"
    end
    local page, per_page, offset = Common.paging(params)
    local sql = COUPON_SELECT .. " WHERE " .. table.concat(where, " AND ")
    local total = db.query("SELECT count(*) AS n FROM (" .. sql .. ") x", unpack(vals))[1].n
    vals[#vals + 1], vals[#vals + 2] = per_page, offset
    local rows = db.query(sql .. " ORDER BY c.created_at DESC LIMIT ? OFFSET ?", unpack(vals))
    for i, r in ipairs(rows) do rows[i] = present_coupon(r) end
    return Common.arr(rows), Common.meta(total, page, per_page)
end

local function coupon_row(namespace_id, uuid)
    return db.query("SELECT * FROM billing_coupons WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL",
        namespace_id, uuid)[1]
end

function Offers.getCoupon(namespace_id, uuid)
    return present_coupon(db.query(COUPON_SELECT .. " WHERE c.namespace_id = ? AND c.uuid = ? AND c.deleted_at IS NULL",
        namespace_id, uuid)[1])
end

-- Validate coupon fields. `current` = the coupon being edited (discount fields
-- are fixed once it has been used).
local function clean_coupon(namespace_id, b, current)
    local f = {}
    local used = current and tonumber(current.redemptions_count) > 0
    if not current then
        local code = type(b.code) == "string" and b.code:upper():gsub("%s", "") or ""
        if not code:match("^[A-Z0-9_-]+$") or #code < 2 or #code > 40 then
            return nil, "code must be 2-40 letters, digits, - or _"
        end
        f.code = code
        if Common.nilify(b.app) then
            local app = Apps.find(namespace_id, b.app)
            if not app then return nil, "App not found" end
            f.app_id = app.id
        end
    end
    local touches_discount = b.discount_type ~= nil or b.percent_off ~= nil or b.amount_off ~= nil
        or b.currency ~= nil or b.duration ~= nil or b.duration_months ~= nil
    if used and touches_discount then return nil, "a coupon's discount can't change after it has been used" end
    if not current or touches_discount then
        local dtype = b.discount_type or (current and current.discount_type)
        if dtype == "percent" then
            local pct = tonumber(b.percent_off or (current and current.percent_off))
            if not pct or pct <= 0 or pct > 100 then return nil, "percent_off must be more than 0 and at most 100" end
            f.discount_type, f.percent_off, f.amount_off, f.currency = "percent", pct, db.NULL, db.NULL
        elseif dtype == "amount" then
            local amt = tonumber(b.amount_off or (current and current.amount_off))
            local cur = b.currency or (current and current.currency)
            if not amt or amt <= 0 or amt ~= math.floor(amt) then
                return nil, "amount_off must be a whole number of minor units (e.g. pence) above 0"
            end
            if type(cur) ~= "string" or not cur:match("^%a%a%a$") then return nil, "currency is required for amount coupons" end
            f.discount_type, f.amount_off, f.currency, f.percent_off = "amount", amt, cur:lower(), db.NULL
        else
            return nil, "discount_type must be percent or amount"
        end
        local duration = b.duration or (current and current.duration) or "once"
        if duration ~= "once" and duration ~= "repeating" and duration ~= "forever" then
            return nil, "duration must be once, repeating or forever"
        end
        f.duration = duration
        if duration == "repeating" then
            local m = tonumber(b.duration_months or (current and current.duration_months))
            if not m or m < 1 or m > 120 or m ~= math.floor(m) then return nil, "duration_months must be 1-120" end
            f.duration_months = m
        else
            f.duration_months = db.NULL
        end
    end
    if b.name ~= nil then
        if b.name ~= cjson.null and (type(b.name) ~= "string" or #b.name > 120) then return nil, "name must be text" end
        f.name = b.name == cjson.null and db.NULL or b.name
    end
    for _, k in ipairs({ "max_redemptions", "per_customer_limit" }) do
        local v, err = int_or_null(b[k], k, 1)
        if err then return nil, err end
        if v ~= nil then f[k] = v end
    end
    for _, k in ipairs({ "starts_at", "expires_at" }) do
        if b[k] ~= nil then
            local v, err = ts(b[k], k)
            if not v then return nil, err end
            f[k] = v
        end
    end
    if b.active ~= nil then f.active = b.active == true end
    if b.plans ~= nil then
        if b.plans == cjson.null or (type(b.plans) == "table" and #b.plans == 0) then
            f.plan_ids = db.NULL
        else
            local app_id = f.app_id or (current and current.app_id)
            if not app_id or app_id == db.NULL then return nil, "limit a coupon to plans only together with an app" end
            if type(b.plans) ~= "table" then return nil, "plans must be a list of plan ids or keys" end
            local ids = {}
            for _, ref in ipairs(b.plans) do
                local p = Subs.appPlan(app_id, tostring(ref))
                if not p then return nil, "plan " .. tostring(ref) .. " not found in this app" end
                ids[#ids + 1] = tonumber(p.id)
            end
            f.plan_ids = db.raw(db.escape_literal(cjson.encode(ids)) .. "::jsonb")
        end
    end
    return f
end

local function write(fn, conflict)
    local ok, res = pcall(fn)
    if ok then return res end
    local msg = tostring(res)
    if msg:find("duplicate key", 1, true) then return nil, conflict end
    if msg:find("invalid input syntax", 1, true) or msg:find("out of range", 1, true) then
        return nil, "dates must be valid ISO-8601 dates"
    end
    error(res)
end

function Offers.createCoupon(namespace_id, actor, b)
    local f, err = clean_coupon(namespace_id, b, nil)
    if not f then return nil, err end
    f.uuid, f.namespace_id, f.created_by = Common.uuid(), namespace_id, actor
    local ok, werr = write(function() return db.insert("billing_coupons", f) end,
        "a coupon with this code already exists")
    if not ok then return nil, werr end
    return Offers.getCoupon(namespace_id, f.uuid)
end

function Offers.updateCoupon(namespace_id, uuid, b)
    local current = coupon_row(namespace_id, uuid)
    if not current then return nil, "Coupon not found" end
    local f, err = clean_coupon(namespace_id, b, current)
    if not f then return nil, err end
    if next(f) ~= nil then
        f.updated_at = db.raw("NOW()")
        local ok, werr = write(function() return db.update("billing_coupons", f, { id = current.id }) end, "conflict")
        if not ok then return nil, werr end
    end
    return Offers.getCoupon(namespace_id, uuid)
end

function Offers.deleteCoupon(namespace_id, uuid)
    local res = db.query([[UPDATE billing_coupons SET deleted_at = NOW(), active = FALSE, updated_at = NOW()
        WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL]], namespace_id, uuid)
    if (res.affected_rows or 0) == 0 then return nil, "Coupon not found" end
    return true
end

function Offers.redemptions(namespace_id, uuid, params)
    local c = coupon_row(namespace_id, uuid)
    if not c then return nil, "Coupon not found" end
    local page, per_page, offset = Common.paging(params)
    local total = db.query("SELECT count(*) AS n FROM billing_coupon_redemptions WHERE coupon_id = ?", c.id)[1].n
    local rows = db.query([[
        SELECT r.uuid, r.amount_off, r.currency, r.redeemed_at, cu.uuid AS customer_uuid, cu.email AS customer_email,
               pu.uuid AS purchase_uuid, s.uuid AS subscription_uuid
        FROM billing_coupon_redemptions r JOIN customers cu ON cu.id = r.customer_id
        LEFT JOIN billing_purchases pu ON pu.id = r.purchase_id
        LEFT JOIN billing_subscriptions s ON s.id = r.subscription_id
        WHERE r.coupon_id = ? ORDER BY r.redeemed_at DESC LIMIT ? OFFSET ?]], c.id, per_page, offset)
    return Common.arr(rows), Common.meta(total, page, per_page)
end

--- Does `code` apply to `plan` (for `customer_id`, optional) at `amount`?
-- @return { coupon, discount, total } | nil, code, message
function Offers.checkCoupon(namespace_id, app, code, plan, amount, currency, customer_id)
    code = type(code) == "string" and code:upper():gsub("%s", "") or ""
    local c = db.query([[SELECT *, (starts_at IS NOT NULL AND starts_at > NOW()) AS not_started,
            (expires_at IS NOT NULL AND expires_at <= NOW()) AS expired
        FROM billing_coupons WHERE namespace_id = ? AND code = ? AND deleted_at IS NULL]], namespace_id, code)[1]
    if not c or (c.app_id ~= db.NULL and c.app_id and tonumber(c.app_id) ~= tonumber(app.id)) then
        return nil, "coupon_not_found", "This coupon code isn't valid"
    end
    if not c.active then return nil, "coupon_inactive", "This coupon is no longer active" end
    if c.not_started then return nil, "coupon_not_started", "This coupon isn't valid yet" end
    if c.expired then return nil, "coupon_expired", "This coupon has expired" end
    if c.max_redemptions ~= db.NULL and c.max_redemptions and tonumber(c.redemptions_count) >= tonumber(c.max_redemptions) then
        return nil, "coupon_exhausted", "This coupon has been used up"
    end
    if type(c.plan_ids) == "table" and #c.plan_ids > 0 then
        local ok = false
        for _, id in ipairs(c.plan_ids) do ok = ok or tonumber(id) == tonumber(plan.id) end
        if not ok then return nil, "coupon_not_for_plan", "This coupon doesn't apply to this plan" end
    end
    if customer_id and c.per_customer_limit ~= db.NULL and c.per_customer_limit then
        local used = db.query("SELECT count(*)::int AS n FROM billing_coupon_redemptions WHERE coupon_id = ? AND customer_id = ?",
            c.id, customer_id)[1].n
        if used >= tonumber(c.per_customer_limit) then
            return nil, "coupon_customer_limit", "You've already used this coupon"
        end
    end
    amount = tonumber(amount) or 0
    local discount
    if c.discount_type == "percent" then
        discount = math.floor(amount * tonumber(c.percent_off) / 100 + 0.5)
    else
        if tostring(c.currency):lower() ~= tostring(currency):lower() then
            return nil, "coupon_currency", "This coupon is for " .. tostring(c.currency):upper() .. " prices"
        end
        discount = math.min(tonumber(c.amount_off), amount)
    end
    return { coupon = c, discount = discount, total = amount - discount,
        duration = c.duration, duration_months = c.duration_months ~= db.NULL and c.duration_months or nil }
end

--- Record a use (atomic against max_redemptions). refs = { purchase_id?, subscription_id? }.
function Offers.redeem(coupon, customer_id, discount, currency, refs)
    local claimed = db.query([[UPDATE billing_coupons SET redemptions_count = redemptions_count + 1, updated_at = NOW()
        WHERE id = ? AND (max_redemptions IS NULL OR redemptions_count < max_redemptions) RETURNING id]], coupon.id)[1]
    if not claimed then return nil, "coupon_exhausted" end
    db.insert("billing_coupon_redemptions", {
        uuid = Common.uuid(), coupon_id = coupon.id, namespace_id = coupon.namespace_id, customer_id = customer_id,
        purchase_id = refs.purchase_id or db.NULL, subscription_id = refs.subscription_id or db.NULL,
        amount_off = discount, currency = currency,
    })
    return true
end

-- ---------------------------------------------------------------------------
-- Upgrade paths
-- ---------------------------------------------------------------------------

local PATH_SELECT = [[
    SELECT u.uuid, u.pricing, u.amount, u.currency, u.active, u.created_at, u.updated_at,
           f.uuid AS from_plan_uuid, f.plan_key AS from_plan_key, f.name AS from_plan_name,
           t.uuid AS to_plan_uuid, t.plan_key AS to_plan_key, t.name AS to_plan_name
    FROM billing_plan_upgrades u JOIN billing_plans f ON f.id = u.from_plan_id JOIN billing_plans t ON t.id = u.to_plan_id
]]

function Offers.listUpgrades(app)
    return Common.arr(db.query(PATH_SELECT .. " WHERE u.app_id = ? ORDER BY f.sort_order, t.sort_order", app.id))
end

local function clean_path(app, b, current)
    local f = {}
    if not current then
        local from = Subs.appPlan(app.id, tostring(b.from_plan or ""))
        local to = Subs.appPlan(app.id, tostring(b.to_plan or ""))
        if not from or not to then return nil, "from_plan and to_plan must be plans of this app" end
        if from.id == to.id then return nil, "from_plan and to_plan must differ" end
        f.from_plan_id, f.to_plan_id = from.id, to.id
    end
    local pricing = b.pricing or (current and current.pricing) or "difference"
    if pricing ~= "difference" and pricing ~= "fixed" and pricing ~= "free" then
        return nil, "pricing must be difference, fixed or free"
    end
    f.pricing = pricing
    if pricing == "fixed" then
        local amt = tonumber(b.amount or (current and current.amount))
        if not amt or amt < 0 or amt ~= math.floor(amt) then return nil, "a fixed upgrade needs amount (minor units)" end
        f.amount = amt
        local cur = b.currency or (current and current.currency ~= db.NULL and current.currency)
        if cur ~= nil and (type(cur) ~= "string" or not cur:match("^%a%a%a$")) then return nil, "currency must be a 3-letter code" end
        f.currency = cur and cur:lower() or db.NULL
    else
        f.amount, f.currency = db.NULL, db.NULL
    end
    if b.active ~= nil then f.active = b.active == true end
    return f
end

function Offers.createUpgrade(app, b)
    local f, err = clean_path(app, b, nil)
    if not f then return nil, err end
    f.uuid, f.app_id = Common.uuid(), app.id
    local ok, werr = write(function() return db.insert("billing_plan_upgrades", f) end,
        "this upgrade path already exists")
    if not ok then return nil, werr end
    return db.query(PATH_SELECT .. " WHERE u.uuid = ?", f.uuid)[1]
end

function Offers.updateUpgrade(app, uuid, b)
    local current = db.query("SELECT * FROM billing_plan_upgrades WHERE app_id = ? AND uuid = ?", app.id, uuid)[1]
    if not current then return nil, "Upgrade path not found" end
    local f, err = clean_path(app, b, current)
    if not f then return nil, err end
    f.updated_at = db.raw("NOW()")
    db.update("billing_plan_upgrades", f, { id = current.id })
    return db.query(PATH_SELECT .. " WHERE u.uuid = ?", uuid)[1]
end

function Offers.deleteUpgrade(app, uuid)
    local res = db.query("DELETE FROM billing_plan_upgrades WHERE app_id = ? AND uuid = ?", app.id, uuid)
    if (res.affected_rows or 0) == 0 then return nil, "Upgrade path not found" end
    return true
end

--- The active path between two plans and its price.
-- @return { path, amount, currency } | nil, err
function Offers.upgradePrice(app, from_plan, to_plan)
    local path = db.query([[SELECT * FROM billing_plan_upgrades WHERE app_id = ? AND from_plan_id = ? AND to_plan_id = ?
        AND active]], app.id, from_plan.id, to_plan.id)[1]
    if not path then return nil, "There is no upgrade from " .. from_plan.name .. " to " .. to_plan.name end
    local currency = to_plan.currency or "gbp"
    if path.pricing == "free" then return { path = path, amount = 0, currency = currency } end
    if path.pricing == "fixed" then
        return { path = path, amount = tonumber(path.amount), currency = path.currency ~= db.NULL and path.currency or currency }
    end
    if tostring(from_plan.currency) ~= tostring(to_plan.currency) then
        return nil, "the plans have different currencies: use a fixed-price upgrade path"
    end
    return { path = path, amount = math.max(tonumber(to_plan.amount) - tonumber(from_plan.amount), 0), currency = currency }
end

return Offers
