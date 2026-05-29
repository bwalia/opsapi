--[[
    Billing System Migrations (Stripe Connect, multi-tenant SaaS)
    =============================================================

    Production billing for the platform: per-tenant Stripe Connect (Express)
    accounts collect from their own clients, with the platform taking a
    configurable application fee. Supports BOTH recurring subscriptions and
    one-time purchases, behind a provider abstraction so Wise (bank transfer)
    can be added later without schema changes.

    Design notes:
    - Every table is namespace-scoped (the tenant), mirroring the invoicing
      and CRM modules. The "paying client" is referenced by `user_uuid`
      (consistent with tax_user_subscriptions and the invoicing module).
    - Monetary amounts are stored in MINOR units (e.g. pence) as BIGINT to
      avoid floating-point rounding — same convention Stripe uses.
    - This is intentionally separate from the ecommerce `payments`/`orders`
      tables: billing here is subscription/Connect-centric, not order-centric.
    - Idempotency for webhooks is enforced by the UNIQUE event_id on
      stripe_webhook_events; replayed events are no-ops.

    Tables:
    =======
    1. namespace_payment_accounts - per-tenant Connect account + onboarding state
    2. billing_plans              - dynamic plans (subscription | one_time)
    3. billing_subscriptions      - recurring subscriptions per user
    4. billing_payments           - payment ledger (one-time + subscription invoices)
    5. billing_refunds            - refunds against billing_payments
    6. stripe_webhook_events      - webhook idempotency + audit
    7. usage_meters               - metered entitlement caps (e.g. AI classify)
]]

local db = require("lapis.db")

-- Helper: does a table already exist? Keeps every step idempotent so a
-- re-run (or running on a DB that predates this module) is a safe no-op.
local function table_exists(name)
    local result = db.query(
        "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================================================
    -- [1] (removed) Previously created namespace_payment_accounts for Stripe
    -- Connect connected accounts. Billing is now single-merchant — the platform's
    -- own Stripe account (STRIPE_SECRET_KEY) is the merchant — so no per-tenant
    -- connected accounts exist. Kept as a no-op to preserve migration ordering;
    -- fresh installs simply never create the table.
    -- ========================================================================
    [1] = function() end,

    -- ========================================================================
    -- [2] billing_plans — dynamic, namespace-scoped plan catalogue
    -- ========================================================================
    [2] = function()
        if table_exists("billing_plans") then return end

        db.query([[
            CREATE TABLE billing_plans (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                description TEXT,
                plan_type TEXT NOT NULL DEFAULT 'subscription' CHECK (plan_type IN ('subscription','one_time')),
                -- Minor units (e.g. 599 = £5.99).
                amount BIGINT NOT NULL CHECK (amount >= 0),
                currency TEXT NOT NULL DEFAULT 'gbp',
                -- Recurrence (subscriptions only).
                billing_interval TEXT CHECK (billing_interval IN ('day','week','month','year')),
                interval_count INTEGER NOT NULL DEFAULT 1 CHECK (interval_count >= 1),
                trial_days INTEGER NOT NULL DEFAULT 0 CHECK (trial_days >= 0),
                -- Stripe product/price ids, created on the platform account on first checkout/sync.
                stripe_product_id TEXT,
                stripe_price_id TEXT,
                -- Entitlements granted, e.g. {"file_to_hmrc":true,"max_bank_accounts":5,"ai_classify_cap":null}.
                features JSONB DEFAULT '{}',
                active BOOLEAN NOT NULL DEFAULT TRUE,
                sort_order INTEGER NOT NULL DEFAULT 0,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP,
                -- Subscriptions must declare an interval; one-time must not.
                CONSTRAINT billing_plans_interval_chk CHECK (
                    (plan_type = 'subscription' AND billing_interval IS NOT NULL) OR
                    (plan_type = 'one_time'     AND billing_interval IS NULL)
                )
            )
        ]])

        db.query([[ CREATE INDEX idx_billing_plans_namespace ON billing_plans (namespace_id) ]])
        db.query([[ CREATE INDEX idx_billing_plans_namespace_active ON billing_plans (namespace_id, active) ]])
        db.query([[
            CREATE INDEX idx_billing_plans_stripe_price ON billing_plans (stripe_price_id)
            WHERE stripe_price_id IS NOT NULL
        ]])
    end,

    -- ========================================================================
    -- [3] billing_subscriptions — recurring subscriptions per user
    -- ========================================================================
    [3] = function()
        if table_exists("billing_subscriptions") then return end

        db.query([[
            CREATE TABLE billing_subscriptions (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                user_uuid TEXT NOT NULL,
                plan_id BIGINT REFERENCES billing_plans(id) ON DELETE SET NULL,
                provider TEXT NOT NULL DEFAULT 'stripe' CHECK (provider IN ('stripe','wise')),
                stripe_subscription_id TEXT,
                stripe_customer_id TEXT,
                -- Mirrors Stripe subscription statuses.
                status TEXT NOT NULL DEFAULT 'incomplete'
                    CHECK (status IN ('incomplete','incomplete_expired','trialing','active','past_due','canceled','unpaid','paused')),
                current_period_start TIMESTAMP,
                current_period_end TIMESTAMP,
                cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
                canceled_at TIMESTAMP,
                trial_end TIMESTAMP,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        db.query([[
            CREATE UNIQUE INDEX idx_billing_subs_stripe_id ON billing_subscriptions (stripe_subscription_id)
            WHERE stripe_subscription_id IS NOT NULL
        ]])
        db.query([[ CREATE INDEX idx_billing_subs_namespace ON billing_subscriptions (namespace_id) ]])
        db.query([[ CREATE INDEX idx_billing_subs_user ON billing_subscriptions (user_uuid) ]])
        db.query([[ CREATE INDEX idx_billing_subs_namespace_user ON billing_subscriptions (namespace_id, user_uuid) ]])
        db.query([[ CREATE INDEX idx_billing_subs_status ON billing_subscriptions (status) ]])
        -- Reconciler sweeps expiring subscriptions by period end.
        db.query([[ CREATE INDEX idx_billing_subs_period_end ON billing_subscriptions (current_period_end) ]])
    end,

    -- ========================================================================
    -- [4] billing_payments — payment ledger (one-time + subscription invoices)
    -- ========================================================================
    [4] = function()
        if table_exists("billing_payments") then return end

        db.query([[
            CREATE TABLE billing_payments (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                user_uuid TEXT,
                plan_id BIGINT REFERENCES billing_plans(id) ON DELETE SET NULL,
                subscription_id BIGINT REFERENCES billing_subscriptions(id) ON DELETE SET NULL,
                provider TEXT NOT NULL DEFAULT 'stripe' CHECK (provider IN ('stripe','wise')),
                payment_type TEXT NOT NULL DEFAULT 'one_time' CHECK (payment_type IN ('one_time','subscription')),
                -- Stripe object references.
                stripe_payment_intent_id TEXT,
                stripe_checkout_session_id TEXT,
                stripe_charge_id TEXT,
                stripe_invoice_id TEXT,
                stripe_customer_id TEXT,
                -- Connected account that received the funds (Connect).
                connected_account_id TEXT,
                amount BIGINT NOT NULL CHECK (amount >= 0),
                currency TEXT NOT NULL DEFAULT 'gbp',
                application_fee_amount BIGINT NOT NULL DEFAULT 0 CHECK (application_fee_amount >= 0),
                status TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','processing','succeeded','failed','canceled','refunded','partially_refunded')),
                payment_method_type TEXT,
                card_brand TEXT,
                card_last4 TEXT,
                receipt_email TEXT,
                receipt_url TEXT,
                failure_code TEXT,
                failure_message TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        db.query([[
            CREATE UNIQUE INDEX idx_billing_payments_pi ON billing_payments (stripe_payment_intent_id)
            WHERE stripe_payment_intent_id IS NOT NULL
        ]])
        db.query([[
            CREATE INDEX idx_billing_payments_checkout ON billing_payments (stripe_checkout_session_id)
            WHERE stripe_checkout_session_id IS NOT NULL
        ]])
        db.query([[ CREATE INDEX idx_billing_payments_namespace ON billing_payments (namespace_id) ]])
        db.query([[ CREATE INDEX idx_billing_payments_user ON billing_payments (user_uuid) ]])
        db.query([[ CREATE INDEX idx_billing_payments_subscription ON billing_payments (subscription_id) ]])
        db.query([[ CREATE INDEX idx_billing_payments_status ON billing_payments (status) ]])
        db.query([[ CREATE INDEX idx_billing_payments_created ON billing_payments USING BRIN (created_at) ]])
    end,

    -- ========================================================================
    -- [5] billing_refunds — refunds against billing_payments
    -- ========================================================================
    [5] = function()
        if table_exists("billing_refunds") then return end

        db.query([[
            CREATE TABLE billing_refunds (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                payment_id BIGINT NOT NULL REFERENCES billing_payments(id) ON DELETE CASCADE,
                provider TEXT NOT NULL DEFAULT 'stripe' CHECK (provider IN ('stripe','wise')),
                stripe_refund_id TEXT,
                amount BIGINT NOT NULL CHECK (amount >= 0),
                currency TEXT NOT NULL DEFAULT 'gbp',
                reason TEXT,
                status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','succeeded','failed','canceled')),
                refund_type TEXT NOT NULL DEFAULT 'full' CHECK (refund_type IN ('full','partial')),
                processed_by_user_uuid TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        db.query([[
            CREATE UNIQUE INDEX idx_billing_refunds_stripe_id ON billing_refunds (stripe_refund_id)
            WHERE stripe_refund_id IS NOT NULL
        ]])
        db.query([[ CREATE INDEX idx_billing_refunds_namespace ON billing_refunds (namespace_id) ]])
        db.query([[ CREATE INDEX idx_billing_refunds_payment ON billing_refunds (payment_id) ]])
    end,

    -- ========================================================================
    -- [6] stripe_webhook_events — idempotency + audit for inbound webhooks
    -- ========================================================================
    [6] = function()
        if table_exists("stripe_webhook_events") then return end

        db.query([[
            CREATE TABLE stripe_webhook_events (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                -- Stripe event id (evt_...). UNIQUE = idempotency guard: a replayed
                -- webhook collides here and is treated as already-processed.
                event_id TEXT UNIQUE NOT NULL,
                event_type TEXT NOT NULL,
                -- Connected account the event belongs to (Connect). NULL = platform event.
                stripe_account_id TEXT,
                api_version TEXT,
                payload JSONB NOT NULL,
                status TEXT NOT NULL DEFAULT 'received' CHECK (status IN ('received','processed','failed','ignored')),
                error_message TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                processed_at TIMESTAMP,
                created_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        db.query([[ CREATE INDEX idx_swe_event_type ON stripe_webhook_events (event_type) ]])
        db.query([[ CREATE INDEX idx_swe_account ON stripe_webhook_events (stripe_account_id) ]])
        db.query([[ CREATE INDEX idx_swe_status ON stripe_webhook_events (status) ]])
        db.query([[ CREATE INDEX idx_swe_created ON stripe_webhook_events USING BRIN (created_at) ]])
    end,

    -- ========================================================================
    -- [7] usage_meters — metered entitlement caps (e.g. AI classify per period)
    -- ========================================================================
    [7] = function()
        if table_exists("usage_meters") then return end

        db.query([[
            CREATE TABLE usage_meters (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                user_uuid TEXT NOT NULL,
                meter_key TEXT NOT NULL,
                period_start DATE NOT NULL,
                period_end DATE NOT NULL,
                used_count BIGINT NOT NULL DEFAULT 0 CHECK (used_count >= 0),
                -- NULL = unlimited.
                limit_count BIGINT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- One counter row per (tenant, user, meter, period).
        db.query([[
            CREATE UNIQUE INDEX idx_usage_meters_unique
            ON usage_meters (namespace_id, user_uuid, meter_key, period_start)
        ]])
        db.query([[ CREATE INDEX idx_usage_meters_lookup ON usage_meters (namespace_id, user_uuid, meter_key) ]])
    end,

    -- ========================================================================
    -- [8] Audit / tracking columns (additive, idempotent). Added after the
    -- initial tables shipped, so ADD COLUMN IF NOT EXISTS keeps it safe to
    -- re-run on databases that already have the base schema.
    -- ========================================================================
    [8] = function()
        -- Subscriptions: which webhook last touched the row, trial start, and
        -- when access actually ended (vs canceled_at = when cancellation was set).
        db.query("ALTER TABLE billing_subscriptions ADD COLUMN IF NOT EXISTS last_event_id TEXT")
        db.query("ALTER TABLE billing_subscriptions ADD COLUMN IF NOT EXISTS last_event_at TIMESTAMP")
        db.query("ALTER TABLE billing_subscriptions ADD COLUMN IF NOT EXISTS trial_start TIMESTAMP")
        db.query("ALTER TABLE billing_subscriptions ADD COLUMN IF NOT EXISTS ended_at TIMESTAMP")

        -- Payments: when the charge actually settled (for revenue reporting).
        db.query("ALTER TABLE billing_payments ADD COLUMN IF NOT EXISTS paid_at TIMESTAMP")

        -- Webhook events: test vs live, so test traffic is never mistaken for real.
        db.query("ALTER TABLE stripe_webhook_events ADD COLUMN IF NOT EXISTS livemode BOOLEAN")
    end,

    -- ========================================================================
    -- [9] Drop the dead Stripe Connect table. Billing is single-merchant now;
    -- step [1] no longer creates namespace_payment_accounts, but databases
    -- migrated before that pivot still have it (unused, no FKs into it).
    -- Idempotent — a no-op where it was never created.
    -- ========================================================================
    [9] = function()
        db.query("DROP TABLE IF EXISTS namespace_payment_accounts CASCADE")
    end,

    -- ========================================================================
    -- [10] Dedupe + unique index on stripe_invoice_id.
    --
    -- Webhooks `checkout.session.completed` and `invoice.paid` arrive
    -- together (same second) for a successful subscription checkout and
    -- both can attempt to insert a billing_payments row carrying the same
    -- stripe_invoice_id. The checkout handler creates a row tied to the
    -- session; the invoice handler races to look it up by invoice_id, finds
    -- nothing (the other handler hasn't committed yet), and inserts a
    -- second row. Result: two "succeeded" rows visible on the user's billing
    -- page, even though Stripe only saw one transaction (acc 2026-05-29).
    --
    -- Fix: a unique partial index makes the race impossible at the DB level —
    -- the losing handler's INSERT fails with a unique violation, and the
    -- code path in routes/billing-webhook.lua catches that, looks up the
    -- winner by invoice_id, and applies its enrichment fields to it instead.
    --
    -- Dedupe first so the index can be created on environments that already
    -- accumulated duplicates. Strategy: keep the oldest row per invoice_id
    -- (it carries the checkout session id), merge non-null fields from the
    -- duplicate, delete the duplicate. No data is lost — just consolidated.
    -- Idempotent: a re-run on a clean table is a no-op.
    -- ========================================================================
    [10] = function()
        -- Defensive pre-dedup: any duplicate invoice rows get merged into
        -- the oldest, then the duplicates are removed.
        db.query([[
            WITH dupes AS (
              SELECT stripe_invoice_id,
                     MIN(id) AS keep_id,
                     MAX(id) AS drop_id
              FROM billing_payments
              WHERE stripe_invoice_id IS NOT NULL
              GROUP BY stripe_invoice_id
              HAVING COUNT(*) > 1
            )
            UPDATE billing_payments p
            SET receipt_url              = COALESCE(p.receipt_url,              d_row.receipt_url),
                stripe_customer_id       = COALESCE(p.stripe_customer_id,       d_row.stripe_customer_id),
                stripe_payment_intent_id = COALESCE(p.stripe_payment_intent_id, d_row.stripe_payment_intent_id),
                subscription_id          = COALESCE(p.subscription_id,          d_row.subscription_id),
                updated_at = NOW()
            FROM dupes d
            JOIN billing_payments d_row ON d_row.id = d.drop_id
            WHERE p.id = d.keep_id
        ]])

        db.query([[
            DELETE FROM billing_payments p
            USING (
              SELECT stripe_invoice_id, MAX(id) AS drop_id
              FROM billing_payments
              WHERE stripe_invoice_id IS NOT NULL
              GROUP BY stripe_invoice_id
              HAVING COUNT(*) > 1
            ) d
            WHERE p.id = d.drop_id
        ]])

        -- Unique partial index. Permits unlimited NULL values (rows in the
        -- pending pre-invoice state) but only one row per real invoice id.
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_payments_invoice
            ON billing_payments (stripe_invoice_id)
            WHERE stripe_invoice_id IS NOT NULL
        ]])
    end,
}
