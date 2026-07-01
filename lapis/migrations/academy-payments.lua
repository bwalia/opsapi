--[[
    Academy Payments & Payouts Migration  (platform-as-merchant-of-record)
    =====================================================================

    All charges settle in the PLATFORM's own Stripe account. We keep our cut and
    owe the creator the rest, tracked in a ledger and paid out manually (bank
    transfer) — creators never connect a Stripe account; they just add bank
    details. The cut % is dynamic: a global default (super admin) with an
    optional per-creator override.

      - creator_accounts            : creator (namespace) bank details + fee override
      - creator_subscription_plans  : a creator's community subscription price
                                      (Stripe price on the PLATFORM account)
      - academy_subscriptions       : learner <-> community subscription
      - academy_payments            : LEDGER — gross, platform_cut, creator_net,
                                      payout_status (owed|paid)
      - academy_settings            : platform-wide config (e.g. default_fee_pct)
      - creator_payouts             : manual payout records (mark-as-paid)
      - processed_stripe_events     : webhook idempotency guard

    Namespace-scoped; feature-gated under ACADEMY.
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

local function column_exists(table_name, column_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.columns
            WHERE table_name = ? AND column_name = ?
        ) as exists
    ]], table_name, column_name)
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
    -- [1] creator_accounts  (bank details + per-creator fee override)
    -- ========================================================================
    [1] = function()
        if table_exists("creator_accounts") then return end
        schema.create_table("creator_accounts", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            -- Per-creator cut override (percent). NULL = use the global default.
            { "fee_pct_override", types.numeric({ null = true }) },
            -- Bank / payout details (for manual transfers).
            { "account_holder_name", types.varchar({ null = true }) },
            { "bank_name", types.varchar({ null = true }) },
            { "account_number", types.varchar({ null = true }) },
            { "routing_number", types.varchar({ null = true }) },  -- US
            { "sort_code", types.varchar({ null = true }) },       -- UK
            { "iban", types.varchar({ null = true }) },
            { "swift_bic", types.varchar({ null = true }) },
            { "bank_country", types.varchar({ null = true }) },
            { "payout_email", types.varchar({ null = true }) },
            { "bank_details_complete", types.boolean({ default = false }) },
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
    -- [2] creator_subscription_plans  (community price, on the PLATFORM account)
    -- ========================================================================
    [2] = function()
        if table_exists("creator_subscription_plans") then return end
        schema.create_table("creator_subscription_plans", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "stripe_price_id", types.varchar({ null = true }) },
            { "interval", types.varchar({ default = "month" }) },
            { "amount", types.integer({ default = 0 }) },
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
    -- [3] academy_subscriptions  (learner <-> community)
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
            { "status", types.varchar({ default = "incomplete" }) },
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
    -- [4] academy_payments  (LEDGER: gross / platform_cut / creator_net)
    -- ========================================================================
    [4] = function()
        if table_exists("academy_payments") then return end
        schema.create_table("academy_payments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_uuid", types.varchar },                       -- buyer
            { "namespace_id", types.integer },                    -- creator/community
            { "course_id", types.integer({ null = true }) },
            { "kind", types.varchar({ default = "course" }) },    -- course|subscription
            { "stripe_ref", types.varchar({ null = true }) },
            { "amount", types.integer({ default = 0 }) },         -- gross (minor units)
            { "platform_cut", types.integer({ default = 0 }) },
            { "creator_net", types.integer({ default = 0 }) },
            { "fee_pct", types.numeric({ default = 0 }) },        -- applied %
            { "currency", types.varchar({ default = "usd" }) },
            { "status", types.varchar({ default = "succeeded" }) }, -- succeeded|refunded|failed
            { "payout_status", types.varchar({ default = "owed" }) }, -- owed|paid
            { "payout_id", types.integer({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        add_namespace_fk("academy_payments", "academy_payments_namespace_fk")
        pcall(function()
            db.query("CREATE INDEX idx_academy_payments_ns_payout ON academy_payments (namespace_id, payout_status)")
        end)
        pcall(function()
            db.query("CREATE INDEX idx_academy_payments_user ON academy_payments (user_uuid)")
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

    -- ========================================================================
    -- [6] academy_settings  (platform-wide config; e.g. default_fee_pct)
    -- ========================================================================
    [6] = function()
        if table_exists("academy_settings") then return end
        schema.create_table("academy_settings", {
            { "id", types.serial },
            { "key", types.varchar({ unique = true }) },
            { "value", types.varchar({ null = true }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        if not index_exists("idx_academy_settings_key") then
            db.query("CREATE UNIQUE INDEX idx_academy_settings_key ON academy_settings (key)")
        end
        -- Seed a sensible default platform cut (20%). Super admin can change it.
        pcall(function()
            db.query("INSERT INTO academy_settings (key, value, updated_at) VALUES ('default_fee_pct', '20', NOW()) ON CONFLICT (key) DO NOTHING")
        end)
    end,

    -- ========================================================================
    -- [7] creator_payouts  (manual payout records — mark as paid)
    -- ========================================================================
    [7] = function()
        if table_exists("creator_payouts") then return end
        schema.create_table("creator_payouts", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "amount", types.integer({ default = 0 }) },
            { "currency", types.varchar({ default = "usd" }) },
            { "status", types.varchar({ default = "paid" }) }, -- record of a manual transfer
            { "reference", types.varchar({ null = true }) },   -- bank ref / note
            { "paid_by_uuid", types.varchar({ null = true }) },
            { "paid_at", types.time({ default = db.raw("NOW()") }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        add_namespace_fk("creator_payouts", "creator_payouts_namespace_fk")
        pcall(function()
            db.query("CREATE INDEX idx_creator_payouts_ns ON creator_payouts (namespace_id)")
        end)
    end,

    -- ========================================================================
    -- [8] Per-instructor payouts (marketplace with a single academy namespace)
    -- ------------------------------------------------------------------------
    -- Phase A treated the "creator" as the namespace. The marketplace hosts many
    -- instructors inside ONE academy namespace (instructor = RBAC role), so
    -- earnings/bank/payouts must attribute to the SELLER (course.owner_user_uuid),
    -- not the namespace. Additive + idempotent; safe to re-run.
    -- ========================================================================
    [8] = function()
        -- academy_payments: which user earns this sale. NULL = platform revenue
        -- (e.g. an academy-wide community subscription, not tied to one instructor).
        if table_exists("academy_payments") and not column_exists("academy_payments", "seller_user_uuid") then
            db.query("ALTER TABLE academy_payments ADD COLUMN seller_user_uuid varchar")
            -- Backfill existing course sales from the course owner.
            pcall(function()
                db.query([[
                    UPDATE academy_payments p SET seller_user_uuid = c.owner_user_uuid
                    FROM academy_courses c
                    WHERE p.course_id = c.id AND p.seller_user_uuid IS NULL
                ]])
            end)
            pcall(function()
                db.query("CREATE INDEX idx_academy_payments_seller_payout ON academy_payments (seller_user_uuid, payout_status)")
            end)
        end

        -- creator_accounts: key by instructor (user), not namespace. One namespace
        -- now has many instructor accounts, so drop the namespace-unique constraint,
        -- add a per-user unique, and make namespace_id optional.
        if table_exists("creator_accounts") then
            if not column_exists("creator_accounts", "user_uuid") then
                db.query("ALTER TABLE creator_accounts ADD COLUMN user_uuid varchar")
            end
            pcall(function() db.query("DROP INDEX IF EXISTS creator_accounts_namespace_unique") end)
            pcall(function() db.query("ALTER TABLE creator_accounts ALTER COLUMN namespace_id DROP NOT NULL") end)
            pcall(function()
                db.query("CREATE UNIQUE INDEX creator_accounts_user_unique ON creator_accounts (user_uuid) WHERE user_uuid IS NOT NULL")
            end)
        end

        -- creator_payouts: record which instructor was paid.
        if table_exists("creator_payouts") and not column_exists("creator_payouts", "user_uuid") then
            db.query("ALTER TABLE creator_payouts ADD COLUMN user_uuid varchar")
            pcall(function()
                db.query("CREATE INDEX idx_creator_payouts_user ON creator_payouts (user_uuid)")
            end)
        end
    end,
}
