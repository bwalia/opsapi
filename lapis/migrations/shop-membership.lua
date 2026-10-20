--[[
    Shop VIP price-lock membership (FEATURES.SHOP + FEATURES.BILLING)
    ==================================================================

    Members pay on the shop's Stripe account (mode=subscription). Each
    membership is ALSO a billing_subscriptions row (customer_id → customers)
    under a "workstation-vip" billing_apps row, so it shows in the existing
    billing admin. These shop tables hold what billing has no place for:

      shop_membership_settings  per-namespace prices, cap, lock days, thresholds
      shop_memberships          tier (founding|standard), founding-spot
                                reservation, price snapshot, fees paid
      shop_member_tokens        emailed sign-in links + signed-in sessions
                                (only sha256 hashes stored)
      shop_credits              order credit ledger (VIP fee refunds; loyalty
                                credits use the same table)
      shop_waitlist             "tell me when it's back" with member priority
      shop_account_deactivations  deactivate now → auto-close after 90 days

    Plus: shop_products.public_launch_at (members see it early_access_hours
    sooner), shop_quotes.price_locked, shop_orders.credit_minor.

    Plus (zzs26): Trade discount — shop_membership_settings.founding_discount_pct /
    standard_discount_pct, shop_orders.member_discount_minor / member_discount_pct.

    Plus (zzs27): fixed Trade discount — shop_membership_settings.discount_fixed_minor /
    discount_min_order_minor (£500 off orders of £5,000+ ex VAT by default).

    Plus (zzs28): membership v2 — a lower fixed tier (discount_tier2_minor / discount_tier2_min_order_minor),
    a yearly cap (discount_cap_minor), refunds with clawback (shop_orders.refunded_minor / returned_net_minor /
    refund_clawback_minor), 48-hour join credits (shop_credits.source 'join_credit', one per order) and
    refund-the-gap claims (shop_membership_gap_claims, one per membership year).

    Registered in migrations.lua as zzs19–zzs21, zzs25, zzs26, zzs27 and zzs28. Idempotent.
]]

local db = require("lapis.db")

return {
    -- [1] settings + memberships ------------------------------------------------------
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_membership_settings (
                namespace_id integer PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
                enabled boolean NOT NULL DEFAULT false,
                monthly_price_minor integer NOT NULL DEFAULT 7500 CHECK (monthly_price_minor > 0),
                yearly_months_charged integer NOT NULL DEFAULT 10 CHECK (yearly_months_charged BETWEEN 1 AND 12),
                vat_rate numeric(5,4) NOT NULL DEFAULT 0.20,
                founding_cap integer NOT NULL DEFAULT 100 CHECK (founding_cap >= 0),
                uplift_pct numeric(6,2) NOT NULL DEFAULT 33,
                lock_days integer NOT NULL DEFAULT 90 CHECK (lock_days IN (90, 120)),
                refund_threshold_minor bigint NOT NULL DEFAULT 10000000,
                credit_expiry_days integer NOT NULL DEFAULT 365,
                early_access_hours integer NOT NULL DEFAULT 24,
                long_lead_days integer NOT NULL DEFAULT 21,
                terms_version varchar(32) NOT NULL DEFAULT '2026-10',
                billing_app_id bigint,
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_memberships (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                email varchar(254) NOT NULL,
                tier varchar(16) NOT NULL CHECK (tier IN ('founding', 'standard')),
                billing_interval varchar(8) NOT NULL CHECK (billing_interval IN ('month', 'year')),
                net_minor integer NOT NULL,
                vat_minor integer NOT NULL,
                status varchar(24) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'active', 'past_due', 'canceled', 'expired', 'abandoned')),
                reserve_expires_at timestamptz,
                stripe_session_id varchar(255),
                stripe_subscription_id varchar(255),
                stripe_customer_id varchar(255),
                billing_subscription_id bigint,
                customer_id integer,
                joined_at timestamptz,
                current_period_end timestamptz,
                cancel_at_period_end boolean NOT NULL DEFAULT false,
                canceled_at timestamptz,
                fees_paid_net_minor bigint NOT NULL DEFAULT 0,
                fees_credited_net_minor bigint NOT NULL DEFAULT 0,
                last_invoice_id varchar(255),
                terms_version varchar(32) NOT NULL,
                terms_accepted_at timestamptz NOT NULL,
                created_at timestamptz NOT NULL DEFAULT NOW(),
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_memberships_email_idx ON shop_memberships (namespace_id, lower(email))]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS shop_memberships_sub_uidx ON shop_memberships (stripe_subscription_id)
                   WHERE stripe_subscription_id IS NOT NULL]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_memberships_tier_idx ON shop_memberships (namespace_id, tier, status)]])
    end,

    -- [2] sign-in tokens + credits + waitlist ----------------------------------------------
    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_member_tokens (
                id serial PRIMARY KEY,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                email varchar(254) NOT NULL,
                kind varchar(8) NOT NULL CHECK (kind IN ('link', 'session')),
                token_hash varchar(64) NOT NULL UNIQUE,
                expires_at timestamptz NOT NULL,
                used_at timestamptz,
                created_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_credits (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                email varchar(254) NOT NULL,
                amount_minor integer NOT NULL CHECK (amount_minor > 0),
                min_order_minor bigint NOT NULL DEFAULT 0,
                source varchar(16) NOT NULL CHECK (source IN ('vip_refund', 'loyalty', 'admin')),
                reason text,
                status varchar(16) NOT NULL DEFAULT 'available'
                    CHECK (status IN ('available', 'reserved', 'used', 'void')),
                reserved_order_id integer REFERENCES shop_orders(id) ON DELETE SET NULL,
                used_order_id integer REFERENCES shop_orders(id) ON DELETE SET NULL,
                earned_order_id integer REFERENCES shop_orders(id) ON DELETE SET NULL,
                membership_id integer REFERENCES shop_memberships(id) ON DELETE SET NULL,
                crm_lead_id bigint,
                expires_at timestamptz,
                created_by varchar(255),
                created_at timestamptz NOT NULL DEFAULT NOW(),
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_credits_email_idx ON shop_credits (namespace_id, lower(email), status)]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_waitlist (
                id serial PRIMARY KEY,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                email varchar(254) NOT NULL,
                is_member boolean NOT NULL DEFAULT false,
                notified_at timestamptz,
                created_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS shop_waitlist_uidx ON shop_waitlist (product_id, lower(email))]])
    end,

    -- [3] columns on existing shop tables ------------------------------------------------
    [3] = function()
        db.query([[ALTER TABLE shop_products ADD COLUMN IF NOT EXISTS public_launch_at timestamptz]])
        db.query([[ALTER TABLE shop_quotes ADD COLUMN IF NOT EXISTS price_locked boolean NOT NULL DEFAULT false]])
        db.query([[ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS credit_minor integer NOT NULL DEFAULT 0]])
        db.query([[ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS stripe_coupon_id varchar(255)]])
    end,

    -- [4] account deactivation (90-day grace, then auto-close) -----------------------------
    [4] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_account_deactivations (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                email varchar(254) NOT NULL,
                status varchar(16) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'closed', 'reactivated')),
                deactivated_at timestamptz NOT NULL DEFAULT NOW(),
                close_at timestamptz NOT NULL,
                closed_at timestamptz,
                reactivated_at timestamptz,
                created_at timestamptz NOT NULL DEFAULT NOW(),
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS shop_account_deactivations_pending_uidx
                ON shop_account_deactivations (namespace_id, lower(email))
                WHERE status = 'pending'
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS shop_account_deactivations_closed_uidx
                ON shop_account_deactivations (namespace_id, lower(email))
                WHERE status = 'closed'
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_account_deactivations_close_idx
                ON shop_account_deactivations (close_at) WHERE status = 'pending'
        ]])
    end,
    -- [5] Trade discount: % off catalogue (cart) orders for members, by tier -----------------
    [5] = function()
        db.query([[ALTER TABLE shop_membership_settings ADD COLUMN IF NOT EXISTS founding_discount_pct numeric(5,2)
                   NOT NULL DEFAULT 5 CHECK (founding_discount_pct BETWEEN 0 AND 50)]])
        db.query([[ALTER TABLE shop_membership_settings ADD COLUMN IF NOT EXISTS standard_discount_pct numeric(5,2)
                   NOT NULL DEFAULT 2.5 CHECK (standard_discount_pct BETWEEN 0 AND 50)]])
        db.query([[ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS member_discount_minor integer NOT NULL DEFAULT 0]])
        db.query([[ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS member_discount_pct numeric(5,2)]])
    end,
    -- [6] Fixed Trade discount: £ off basket orders at or above a minimum (replaces the % when > 0) ---
    [6] = function()
        db.query([[ALTER TABLE shop_membership_settings ADD COLUMN IF NOT EXISTS discount_fixed_minor integer
                   NOT NULL DEFAULT 50000 CHECK (discount_fixed_minor >= 0)]])
        db.query([[ALTER TABLE shop_membership_settings ADD COLUMN IF NOT EXISTS discount_min_order_minor integer
                   NOT NULL DEFAULT 500000 CHECK (discount_min_order_minor >= 0)]])
    end,
    -- [7] Membership v2: tiers, yearly cap, refunds with clawback, join credits, gap claims ------------
    [7] = function()
        db.query([[ALTER TABLE shop_membership_settings ADD COLUMN IF NOT EXISTS discount_tier2_minor integer
                   NOT NULL DEFAULT 25000 CHECK (discount_tier2_minor >= 0)]])
        db.query([[ALTER TABLE shop_membership_settings ADD COLUMN IF NOT EXISTS discount_tier2_min_order_minor integer
                   NOT NULL DEFAULT 300000 CHECK (discount_tier2_min_order_minor >= 0)]])
        db.query([[ALTER TABLE shop_membership_settings ADD COLUMN IF NOT EXISTS discount_cap_minor integer
                   NOT NULL DEFAULT 150000 CHECK (discount_cap_minor >= 0)]])
        -- Refunds through the admin API: running totals so a second partial return claws back only the difference.
        db.query([[ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS refunded_minor integer NOT NULL DEFAULT 0]])
        db.query([[ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS returned_net_minor integer NOT NULL DEFAULT 0]])
        db.query([[ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS refund_clawback_minor integer NOT NULL DEFAULT 0]])
        -- 48-hour join credit: its own source, at most one per earning order.
        db.query([[ALTER TABLE shop_credits DROP CONSTRAINT IF EXISTS shop_credits_source_check]])
        db.query([[ALTER TABLE shop_credits ADD CONSTRAINT shop_credits_source_check
                   CHECK (source IN ('vip_refund', 'loyalty', 'admin', 'join_credit'))]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS shop_credits_join_credit_uidx ON shop_credits (earned_order_id)
                   WHERE source = 'join_credit']])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_membership_gap_claims (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                membership_id integer NOT NULL REFERENCES shop_memberships(id) ON DELETE CASCADE,
                email varchar(254) NOT NULL,
                year_start timestamptz NOT NULL,
                year_end timestamptz NOT NULL,
                fees_paid_net_minor integer NOT NULL,
                discounts_minor integer NOT NULL,
                credits_minor integer NOT NULL,
                gap_minor integer NOT NULL CHECK (gap_minor > 0),
                status varchar(16) NOT NULL DEFAULT 'claimed' CHECK (status IN ('claimed', 'refunded', 'rejected')),
                crm_lead_id bigint,
                created_at timestamptz NOT NULL DEFAULT NOW(),
                updated_at timestamptz NOT NULL DEFAULT NOW(),
                UNIQUE (membership_id, year_start)
            )
        ]])
    end,
}
