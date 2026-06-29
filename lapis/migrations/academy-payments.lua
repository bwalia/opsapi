--[[
    Academy Payments & Subscriptions Migration
    ==========================================

    Marketplace money layer for the Academy module (per-creator / Skool model):
      - creator_accounts            : creator (namespace) <-> Stripe Connect account
      - creator_subscription_plans  : a creator's community subscription price
      - academy_subscriptions       : learner <-> creator community subscription
      - academy_payments            : payment records (one-time course + subscription)
      - processed_stripe_events     : webhook idempotency guard

    Namespace-scoped; feature-gated under ACADEMY. opsapi stays the source of
    truth for entitlements + records; Stripe API calls live in the Node layer.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

local function table_exists(table_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.tables WHERE table_name = ?
        ) as exists
    ]], table_name)
    return result[1] and result[1].exists
end

local function index_exists(index_name)
    local result = db.query([[
        SELECT EXISTS (SELECT FROM pg_indexes WHERE indexname = ?) as exists
    ]], index_name)
    return result[1] and result[1].exists
end

local function add_namespace_fk(table_name, constraint_name)
    pcall(function()
        db.query(string.format([[
            ALTER TABLE %s ADD CONSTRAINT %s
            FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
        ]], table_name, constraint_name))
    end)
end

return {
    -- ========================================================================
    -- [1] creator_accounts  (namespace <-> Stripe Connect)
    -- ========================================================================
    [1] = function()
        if table_exists("creator_accounts") then return end
        schema.create_table("creator_accounts", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "stripe_account_id", types.varchar({ null = true }) },
            { "onboarding_status", types.varchar({ default = "none" }) }, -- none|pending|complete
            { "charges_enabled", types.boolean({ default = false }) },
            { "payouts_enabled", types.boolean({ default = false }) },
            { "default_currency", types.varchar({ default = "usd" }) },
            { "platform_fee_pct", types.numeric({ default = 20 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        add_namespace_fk("creator_accounts", "creator_accounts_namespace_fk")
        pcall(function()
            db.query("CREATE UNIQUE INDEX creator_accounts_namespace_unique ON creator_accounts (namespace_id)")
        end)
    end,

    -- ========================================================================
    -- [2] creator_subscription_plans  (a creator's community price)
    -- ========================================================================
    [2] = function()
        if table_exists("creator_subscription_plans") then return end
        schema.create_table("creator_subscription_plans", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "stripe_price_id", types.varchar({ null = true }) },
            { "interval", types.varchar({ default = "month" }) }, -- month|year
            { "amount", types.integer({ default = 0 }) },         -- minor units
            { "currency", types.varchar({ default = "usd" }) },
            { "active", types.boolean({ default = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        add_namespace_fk("creator_subscription_plans", "creator_sub_plans_namespace_fk")
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX creator_sub_plans_ns_active_unique
                ON creator_subscription_plans (namespace_id) WHERE active
            ]])
        end)
    end,

    -- ========================================================================
    -- [3] academy_subscriptions  (learner <-> creator community)
    -- ========================================================================
    [3] = function()
        if table_exists("academy_subscriptions") then return end
        schema.create_table("academy_subscriptions", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_uuid", types.varchar },
            { "namespace_id", types.integer },
            { "stripe_subscription_id", types.varchar({ null = true }) },
            { "stripe_customer_id", types.varchar({ null = true }) },
            { "status", types.varchar({ default = "incomplete" }) }, -- active|trialing|past_due|canceled|incomplete
            { "current_period_end", types.time({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        add_namespace_fk("academy_subscriptions", "academy_subscriptions_namespace_fk")
        pcall(function()
            db.query("CREATE INDEX idx_academy_subscriptions_user_ns ON academy_subscriptions (user_uuid, namespace_id)")
        end)
        pcall(function()
            db.query("CREATE UNIQUE INDEX idx_academy_subscriptions_stripe ON academy_subscriptions (stripe_subscription_id) WHERE stripe_subscription_id IS NOT NULL")
        end)
    end,

    -- ========================================================================
    -- [4] academy_payments  (one-time course + subscription invoices)
    -- ========================================================================
    [4] = function()
        if table_exists("academy_payments") then return end
        schema.create_table("academy_payments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_uuid", types.varchar },
            { "namespace_id", types.integer },
            { "course_id", types.integer({ null = true }) },
            { "kind", types.varchar({ default = "course" }) }, -- course|subscription
            { "stripe_ref", types.varchar({ null = true }) },  -- payment_intent / invoice id
            { "amount", types.integer({ default = 0 }) },
            { "platform_fee", types.integer({ default = 0 }) },
            { "currency", types.varchar({ default = "usd" }) },
            { "status", types.varchar({ default = "pending" }) }, -- pending|succeeded|refunded|failed
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        add_namespace_fk("academy_payments", "academy_payments_namespace_fk")
        pcall(function()
            db.query("CREATE INDEX idx_academy_payments_user ON academy_payments (user_uuid, namespace_id)")
        end)
    end,

    -- ========================================================================
    -- [5] processed_stripe_events  (webhook idempotency)
    -- ========================================================================
    [5] = function()
        if table_exists("processed_stripe_events") then return end
        schema.create_table("processed_stripe_events", {
            { "id", types.serial },
            { "event_id", types.varchar({ unique = true }) },
            { "type", types.varchar({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        if not index_exists("idx_processed_stripe_events_event") then
            db.query("CREATE UNIQUE INDEX idx_processed_stripe_events_event ON processed_stripe_events (event_id)")
        end
    end,
}
