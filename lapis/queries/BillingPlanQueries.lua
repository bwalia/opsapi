--[[
    Billing Plan Queries
    ====================

    CRUD for `billing_plans` (dynamic, namespace-scoped) plus lazy Stripe sync.

    Plans live in our DB as the source of truth; their Stripe Product/Price are
    created on demand (ensureStripeSync). Prices are immutable in Stripe, so a
    price-affecting change creates a NEW Price and repoints the plan.

    Amounts are MINOR units (pence) throughout — same as Stripe `unit_amount`.
]]

local BillingPlanModel = require("models.BillingPlanModel")
local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

local BillingPlanQueries = {}

local VALID_TYPES = { subscription = true, one_time = true }
local VALID_INTERVALS = { day = true, week = true, month = true, year = true }

-- Validate plan input. Returns (true) or (false, error_message).
function BillingPlanQueries.validate(params)
    if not params.name or params.name == "" then
        return false, "name is required"
    end
    local plan_type = params.plan_type or "subscription"
    if not VALID_TYPES[plan_type] then
        return false, "plan_type must be 'subscription' or 'one_time'"
    end
    local amount = tonumber(params.amount)
    if not amount or amount < 0 or math.floor(amount) ~= amount then
        return false, "amount must be a non-negative integer (minor units, e.g. pence)"
    end
    if plan_type == "subscription" then
        if not params.billing_interval or not VALID_INTERVALS[params.billing_interval] then
            return false, "billing_interval must be one of day|week|month|year for subscriptions"
        end
    elseif params.billing_interval ~= nil then
        return false, "one_time plans must not set billing_interval"
    end
    return true
end

local function encode_features(v)
    if v == nil then return nil end
    if type(v) == "table" then return cjson.encode(v) end
    return v
end

-- Decode JSONB-ish columns on a row for API responses.
local function decode_row(row)
    if not row then return row end
    if type(row.features) == "string" then
        local ok, decoded = pcall(cjson.decode, row.features)
        if ok then row.features = decoded end
    end
    if type(row.metadata) == "string" then
        local ok, decoded = pcall(cjson.decode, row.metadata)
        if ok then row.metadata = decoded end
    end
    return row
end
BillingPlanQueries.decode_row = decode_row

-- Create a plan. Caller must have validated and set namespace_id.
function BillingPlanQueries.create(params)
    params.uuid = params.uuid or Global.generateUUID()
    params.plan_type = params.plan_type or "subscription"
    params.currency = (params.currency or "gbp"):lower()
    params.interval_count = tonumber(params.interval_count) or 1
    params.trial_days = tonumber(params.trial_days) or 0
    params.amount = math.floor(tonumber(params.amount) or 0)
    params.features = encode_features(params.features)
    params.metadata = encode_features(params.metadata)
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")
    return BillingPlanModel:create(params, { returning = "*" })
end

-- Fetch a plan by uuid (any namespace); caller verifies ownership.
function BillingPlanQueries.getByUuid(uuid)
    local rows = db.query(
        "SELECT * FROM billing_plans WHERE uuid = ? AND deleted_at IS NULL LIMIT 1", uuid)
    return rows and rows[1] or nil
end

-- List a namespace's plans. opts.include_inactive, opts.plan_type filter.
function BillingPlanQueries.listByNamespace(namespace_id, opts)
    opts = opts or {}
    local where = { "namespace_id = ?", "deleted_at IS NULL" }
    local vals = { namespace_id }
    if not opts.include_inactive then
        table.insert(where, "active = TRUE")
    end
    if opts.plan_type and VALID_TYPES[opts.plan_type] then
        table.insert(where, "plan_type = ?")
        table.insert(vals, opts.plan_type)
    end
    local sql = "SELECT * FROM billing_plans WHERE " .. table.concat(where, " AND ") ..
        " ORDER BY sort_order ASC, created_at ASC"
    local rows = db.query(sql, unpack(vals))
    for i = 1, #rows do decode_row(rows[i]) end
    return rows
end

-- Update a plan by uuid. Returns the updated model or nil.
function BillingPlanQueries.update(uuid, fields)
    local plan = BillingPlanModel:find({ uuid = uuid })
    if not plan then return nil end
    fields.updated_at = db.raw("NOW()")
    if fields.features ~= nil then fields.features = encode_features(fields.features) end
    if fields.metadata ~= nil then fields.metadata = encode_features(fields.metadata) end
    if fields.amount ~= nil then fields.amount = math.floor(tonumber(fields.amount) or 0) end
    if fields.currency ~= nil then fields.currency = tostring(fields.currency):lower() end
    plan:update(fields)
    return plan
end

-- Soft delete (and deactivate) a plan.
function BillingPlanQueries.softDelete(uuid)
    local plan = BillingPlanModel:find({ uuid = uuid })
    if not plan then return nil end
    plan:update({ active = false, deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return plan
end

-- Null out the Stripe price id so the next ensureStripeSync mints a fresh
-- Price (used when a price-affecting field changes — Stripe Prices are
-- immutable, so the old one is archived and replaced).
function BillingPlanQueries.clearStripePrice(uuid)
    local plan = BillingPlanModel:find({ uuid = uuid })
    if not plan then return nil end
    plan:update({ stripe_price_id = db.NULL, updated_at = db.raw("NOW()") })
    return plan
end

-- Ensure a plan has a Stripe Product + Price (creating them on demand).
-- Returns (plan, nil) when synced/already-synced, or (plan, error) on failure.
-- `stripe` is a platform client (no connected account) — destination charges
-- keep products/prices on the platform account.
function BillingPlanQueries.ensureStripeSync(plan, stripe)
    if not plan then return plan, "plan not found" end
    if plan.stripe_price_id and plan.stripe_price_id ~= "" then
        return plan, nil
    end

    local product_id = plan.stripe_product_id
    if not product_id or product_id == "" then
        local product, perr = stripe:create_product({
            name = plan.name,
            description = plan.description,
            metadata = { plan_uuid = plan.uuid, namespace_id = tostring(plan.namespace_id) },
        })
        if not product or not product.id then
            return plan, "Failed to create Stripe product: " .. tostring(perr)
        end
        product_id = product.id
    end

    local price_opts = {
        product = product_id,
        unit_amount = math.floor(tonumber(plan.amount) or 0),
        currency = (plan.currency or "gbp"):lower(),
        metadata = { plan_uuid = plan.uuid },
    }
    if plan.plan_type == "subscription" then
        price_opts.recurring = {
            interval = plan.billing_interval,
            interval_count = tonumber(plan.interval_count) or 1,
        }
    end

    local price, prerr = stripe:create_price(price_opts)
    if not price or not price.id then
        -- Persist the product id so a retry doesn't create a duplicate product.
        BillingPlanQueries.update(plan.uuid, { stripe_product_id = product_id })
        return plan, "Failed to create Stripe price: " .. tostring(prerr)
    end

    local updated = BillingPlanQueries.update(plan.uuid, {
        stripe_product_id = product_id,
        stripe_price_id = price.id,
    })
    return (updated or plan), nil
end

return BillingPlanQueries
