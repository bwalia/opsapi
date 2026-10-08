--[[
    Billing & Entitlements (phase 1) — docs/BILLING_ENTITLEMENTS.md
    ==============================================================
    A client (workspace) registers its apps, defines features and flat-tier
    plans, and its apps check what each customer may use. Builds on the
    existing billing tables (migrations/billing-system.lua) and the customers
    table; new tables only where nothing existed.

      [1] customers: external_id (the client's own user id, unique per
          workspace) and email unique PER WORKSPACE (it was unique across all
          workspaces, so one person could not be a customer of two clients).
      [2] billing_apps
      [3] billing_features (the feature catalogue of an app)
      [4] billing_plans: app_id, plan_key, is_default, is_public
      [5] billing_subscriptions: app_id, customer_id (user_uuid becomes optional)
      [6] billing_grants (manual / trial / comped access, may expire)
      [7] billing_licenses + billing_license_activations
      [8] RBAC modules (billing, subscriptions, entitlements, licenses,
          customers) granted to owner/admin roles on first insert, + menu items
      v2 (docs/BILLING_ENTITLEMENTS.md §5):
      [9]  app tunables -> settings JSONB (validated by lib/billing-settings.lua),
           cache_generation
      [10] purchase types, feature release dates, sources + store ids,
           licence access/updates windows
      [11] billing_purchases (one_time / fixed_term, any source)
      [12] upgrade paths, coupons + redemptions, plan-change history
      [13] access links (magic links), customer sessions, idempotency keys

    Additive and idempotent. Existing tax billing rows are untouched.
]]

local db = require("lapis.db")

local function constraint_exists(name)
    return #db.query("SELECT 1 FROM pg_constraint WHERE conname = ?", name) > 0
end

return {
    [1] = function()
        db.query("ALTER TABLE customers ADD COLUMN IF NOT EXISTS external_id TEXT")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS customers_ns_external_id_uidx
            ON customers (namespace_id, external_id) WHERE external_id IS NOT NULL
        ]])
        -- Email: unique per workspace (case-insensitive) instead of globally.
        -- Customers without a workspace (the legacy marketplace checkout) keep
        -- their own global uniqueness.
        local ok = pcall(db.query, [[
            CREATE UNIQUE INDEX IF NOT EXISTS customers_ns_email_uidx
            ON customers (namespace_id, lower(email)) WHERE namespace_id IS NOT NULL
        ]])
        if not ok then
            -- Existing rows differing only by case: keep exact-match uniqueness.
            db.query([[
                CREATE UNIQUE INDEX IF NOT EXISTS customers_ns_email_uidx
                ON customers (namespace_id, email) WHERE namespace_id IS NOT NULL
            ]])
            print("[Billing] customers: case-variant duplicate emails exist; email unique per workspace (case-sensitive)")
        end
        pcall(db.query, [[
            CREATE UNIQUE INDEX IF NOT EXISTS customers_no_ns_email_uidx
            ON customers (email) WHERE namespace_id IS NULL
        ]])
        db.query("DROP INDEX IF EXISTS customers_email_unique_idx")
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_apps (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                slug TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'web' CHECK (kind IN ('web', 'desktop', 'self_hosted', 'mobile')),
                mode TEXT NOT NULL DEFAULT 'test' CHECK (mode IN ('test', 'live')),
                publishable_key TEXT NOT NULL UNIQUE,
                settings JSONB NOT NULL DEFAULT '{}',
                active BOOLEAN NOT NULL DEFAULT TRUE,
                created_by TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                deleted_at TIMESTAMPTZ
            )
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS billing_apps_ns_slug_uidx
            ON billing_apps (namespace_id, slug) WHERE deleted_at IS NULL
        ]])
        db.query("CREATE INDEX IF NOT EXISTS billing_apps_ns_idx ON billing_apps (namespace_id)")
    end,

    [3] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_features (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                app_id BIGINT NOT NULL REFERENCES billing_apps(id) ON DELETE CASCADE,
                key TEXT NOT NULL CHECK (key ~ '^[a-z0-9_]{1,64}$'),
                name TEXT NOT NULL,
                description TEXT,
                type TEXT NOT NULL DEFAULT 'boolean' CHECK (type IN ('boolean', 'limit')),
                unit TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS billing_features_app_key_uidx ON billing_features (app_id, key)")
    end,

    [4] = function()
        db.query("ALTER TABLE billing_plans ADD COLUMN IF NOT EXISTS app_id BIGINT REFERENCES billing_apps(id) ON DELETE CASCADE")
        db.query("ALTER TABLE billing_plans ADD COLUMN IF NOT EXISTS plan_key TEXT")
        db.query("ALTER TABLE billing_plans ADD COLUMN IF NOT EXISTS is_default BOOLEAN NOT NULL DEFAULT FALSE")
        db.query("ALTER TABLE billing_plans ADD COLUMN IF NOT EXISTS is_public BOOLEAN NOT NULL DEFAULT TRUE")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS billing_plans_app_key_uidx
            ON billing_plans (app_id, plan_key) WHERE app_id IS NOT NULL AND deleted_at IS NULL
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS billing_plans_app_default_uidx
            ON billing_plans (app_id) WHERE app_id IS NOT NULL AND is_default AND deleted_at IS NULL
        ]])
    end,

    [5] = function()
        db.query("ALTER TABLE billing_subscriptions ADD COLUMN IF NOT EXISTS app_id BIGINT REFERENCES billing_apps(id) ON DELETE CASCADE")
        db.query("ALTER TABLE billing_subscriptions ADD COLUMN IF NOT EXISTS customer_id INTEGER REFERENCES customers(id) ON DELETE RESTRICT")
        db.query("ALTER TABLE billing_subscriptions ALTER COLUMN user_uuid DROP NOT NULL")
        if not constraint_exists("billing_subscriptions_subject_chk") then
            db.query([[
                ALTER TABLE billing_subscriptions ADD CONSTRAINT billing_subscriptions_subject_chk
                CHECK (user_uuid IS NOT NULL OR customer_id IS NOT NULL)
            ]])
        end
        db.query([[
            CREATE INDEX IF NOT EXISTS billing_subscriptions_app_customer_idx
            ON billing_subscriptions (app_id, customer_id, status) WHERE customer_id IS NOT NULL
        ]])
    end,

    [6] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_grants (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                app_id BIGINT NOT NULL REFERENCES billing_apps(id) ON DELETE CASCADE,
                customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
                plan_id BIGINT REFERENCES billing_plans(id) ON DELETE CASCADE,
                features JSONB NOT NULL DEFAULT '{}',
                reason TEXT,
                starts_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                expires_at TIMESTAMPTZ,
                granted_by TEXT,
                revoked_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CONSTRAINT billing_grants_what_chk CHECK (plan_id IS NOT NULL OR features <> '{}'::jsonb)
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS billing_grants_customer_idx
            ON billing_grants (app_id, customer_id) WHERE revoked_at IS NULL
        ]])
    end,

    [7] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_licenses (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                app_id BIGINT NOT NULL REFERENCES billing_apps(id) ON DELETE CASCADE,
                customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
                subscription_id BIGINT REFERENCES billing_subscriptions(id) ON DELETE SET NULL,
                plan_id BIGINT REFERENCES billing_plans(id) ON DELETE SET NULL,
                key_hash TEXT NOT NULL UNIQUE,
                key_prefix TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'revoked', 'expired')),
                max_activations INTEGER CHECK (max_activations IS NULL OR max_activations >= 1),
                expires_at TIMESTAMPTZ,
                metadata JSONB NOT NULL DEFAULT '{}',
                created_by TEXT,
                revoked_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS billing_licenses_app_customer_idx ON billing_licenses (app_id, customer_id)")
        db.query("CREATE INDEX IF NOT EXISTS billing_licenses_ns_idx ON billing_licenses (namespace_id)")
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_license_activations (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                license_id BIGINT NOT NULL REFERENCES billing_licenses(id) ON DELETE CASCADE,
                fingerprint_hash TEXT NOT NULL,
                name TEXT,
                platform TEXT,
                app_version TEXT,
                first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                deactivated_at TIMESTAMPTZ
            )
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS billing_license_activations_live_uidx
            ON billing_license_activations (license_id, fingerprint_hash) WHERE deactivated_at IS NULL
        ]])
    end,

    [8] = function()
        -- Only created under tax_copilot until now; the module rows need it.
        db.query("ALTER TABLE modules ADD COLUMN IF NOT EXISTS allowed_actions TEXT")
        local modules = {
            { "billing", "Billing", "Apps, features, flat-tier plans and billing reports", "Billing" },
            { "subscriptions", "Subscriptions", "Customers' subscriptions and manual access grants", "Billing" },
            { "entitlements", "Entitlements", "Check what a customer may use (server-to-server)", "Billing" },
            { "licenses", "Licences", "Licence keys and machine activations for desktop and self-hosted apps", "Billing" },
            { "customers", "Customers", "Customer management", "Commerce" },
        }
        for _, m in ipairs(modules) do
            -- Granted to owner/admin roles on FIRST insert only, so a permission
            -- an admin later takes away stays taken away.
            local inserted = db.query([[
                INSERT INTO modules (uuid, machine_name, name, description, category, priority,
                                     is_active, is_system, default_actions, created_at, updated_at)
                VALUES (gen_random_uuid()::text, ?, ?, ?, ?, '0', true, false,
                        'create,read,update,delete,manage', NOW(), NOW())
                ON CONFLICT (machine_name) DO NOTHING
                RETURNING id
            ]], m[1], m[2], m[3], m[4])
            if inserted[1] then
                require("queries.ModuleQueries").propagateToNamespaceAdmins(m[1])
                print("[Billing] Registered module " .. m[1] .. "; granted to owner/admin roles")
            end
        end
        local menu = {
            { "billing", "Billing", "Wallet", "/dashboard/billing", "billing", 60 },
            { "billing_subscriptions", "Subscriptions", "RefreshCw", "/dashboard/billing/subscriptions", "subscriptions", 61 },
            { "billing_licenses", "Licences", "KeyRound", "/dashboard/billing/licenses", "licenses", 62 },
            { "customers", "Customers", "UserCircle", "/dashboard/customers", "customers", 11 },
        }
        for _, item in ipairs(menu) do
            db.query([[
                INSERT INTO menu_items (uuid, key, name, icon, path, module, required_action, priority,
                                        is_active, is_admin_only, always_show, settings, created_at, updated_at)
                VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, 'read', ?, true, false, false, '{}', NOW(), NOW())
                ON CONFLICT (key) DO NOTHING
            ]], item[1], item[2], item[3], item[4], item[5], item[6])
        end
    end,
    [9] = function()
        db.query("ALTER TABLE billing_apps ADD COLUMN IF NOT EXISTS cache_generation BIGINT NOT NULL DEFAULT 1")
        -- Development databases that ran the v1 columns: carry the values over.
        local legacy = db.query([[SELECT 1 FROM information_schema.columns
            WHERE table_name = 'billing_apps' AND column_name = 'offline_grace_seconds']])[1]
        if legacy then
            db.query([[
                UPDATE billing_apps SET settings = jsonb_strip_nulls(jsonb_build_object(
                    'offline_policy', offline_policy,
                    'token_ttl_seconds', entitlement_ttl_seconds,
                    'grace_days', GREATEST(offline_grace_seconds / 86400, 0),
                    'past_due_grace_days', past_due_grace_days,
                    'allowed_redirect_urls', allowed_return_urls)) || settings
            ]])
            for _, col in ipairs({ "offline_policy", "offline_grace_seconds", "entitlement_ttl_seconds",
                "past_due_grace_days", "allowed_return_urls" }) do
                db.query("ALTER TABLE billing_apps DROP COLUMN IF EXISTS " .. col)
            end
        end
        -- Every app gets its public fingerprint salt (LICENCE_FORMAT.md §6).
        db.query([[
            UPDATE billing_apps SET settings = settings || jsonb_build_object('fingerprint_salt',
                md5(random()::text || clock_timestamp()::text || id::text))
            WHERE settings -> 'fingerprint_salt' IS NULL
        ]])
    end,

    [10] = function()
        db.query("ALTER TABLE billing_features ADD COLUMN IF NOT EXISTS released_at TIMESTAMPTZ")
        local plan_cols = {
            "purchase_type TEXT CHECK (purchase_type IN ('recurring', 'one_time', 'fixed_term'))",
            "term_days INTEGER CHECK (term_days IS NULL OR term_days BETWEEN 1 AND 36500)",
            "term_covers TEXT CHECK (term_covers IN ('access', 'updates'))",
            "updates_days INTEGER CHECK (updates_days IS NULL OR updates_days BETWEEN 1 AND 36500)",
            "store_products JSONB NOT NULL DEFAULT '{}'",
        }
        for _, c in ipairs(plan_cols) do db.query("ALTER TABLE billing_plans ADD COLUMN IF NOT EXISTS " .. c) end
        db.query("UPDATE billing_plans SET purchase_type = CASE WHEN plan_type = 'one_time' THEN 'one_time' "
            .. "ELSE 'recurring' END WHERE app_id IS NOT NULL AND purchase_type IS NULL")

        for _, c in ipairs({ "source TEXT NOT NULL DEFAULT 'stripe'", "external_transaction_id TEXT",
            "original_transaction_id TEXT" }) do
            db.query("ALTER TABLE billing_subscriptions ADD COLUMN IF NOT EXISTS " .. c)
        end
        -- Subscriptions now also come from manual sales and stores (docs §12).
        db.query("ALTER TABLE billing_subscriptions DROP CONSTRAINT IF EXISTS billing_subscriptions_provider_check")
        db.query([[ALTER TABLE billing_subscriptions ADD CONSTRAINT billing_subscriptions_provider_check
            CHECK (provider IN ('stripe', 'wise', 'manual', 'app_store', 'play_store', 'external'))]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS billing_subscriptions_source_txn_uidx
            ON billing_subscriptions (namespace_id, source, original_transaction_id)
            WHERE original_transaction_id IS NOT NULL
        ]])

        for _, c in ipairs({ "access_until TIMESTAMPTZ", "updates_until TIMESTAMPTZ",
            "source TEXT NOT NULL DEFAULT 'manual'", "purchase_id BIGINT", "key_rotated_at TIMESTAMPTZ" }) do
            db.query("ALTER TABLE billing_licenses ADD COLUMN IF NOT EXISTS " .. c)
        end
        -- v1 expiry = v2 access window.
        if db.query([[SELECT 1 FROM information_schema.columns
            WHERE table_name = 'billing_licenses' AND column_name = 'expires_at']])[1] then
            db.query("UPDATE billing_licenses SET access_until = expires_at WHERE access_until IS NULL AND expires_at IS NOT NULL")
            db.query("ALTER TABLE billing_licenses DROP COLUMN expires_at")
        end
        db.query("CREATE INDEX IF NOT EXISTS billing_license_activations_seen_idx ON billing_license_activations (last_seen_at) WHERE deactivated_at IS NULL")
    end,

    [11] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_purchases (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                app_id BIGINT NOT NULL REFERENCES billing_apps(id) ON DELETE CASCADE,
                customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
                plan_id BIGINT NOT NULL REFERENCES billing_plans(id) ON DELETE RESTRICT,
                purchase_type TEXT NOT NULL CHECK (purchase_type IN ('one_time', 'fixed_term')),
                source TEXT NOT NULL CHECK (source IN ('stripe', 'manual', 'app_store', 'play_store', 'external')),
                external_transaction_id TEXT,
                original_transaction_id TEXT,
                access_until TIMESTAMPTZ,
                updates_until TIMESTAMPTZ,
                amount BIGINT NOT NULL DEFAULT 0,
                currency TEXT NOT NULL DEFAULT 'gbp',
                status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'refunded', 'revoked')),
                refunded_amount BIGINT NOT NULL DEFAULT 0,
                refunded_at TIMESTAMPTZ,
                coupon_id BIGINT,
                metadata JSONB NOT NULL DEFAULT '{}',
                created_by TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS billing_purchases_app_customer_idx ON billing_purchases (app_id, customer_id, status)")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS billing_purchases_source_txn_uidx
            ON billing_purchases (namespace_id, source, external_transaction_id) WHERE external_transaction_id IS NOT NULL
        ]])
    end,

    [12] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_plan_upgrades (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                app_id BIGINT NOT NULL REFERENCES billing_apps(id) ON DELETE CASCADE,
                from_plan_id BIGINT NOT NULL REFERENCES billing_plans(id) ON DELETE CASCADE,
                to_plan_id BIGINT NOT NULL REFERENCES billing_plans(id) ON DELETE CASCADE,
                pricing TEXT NOT NULL DEFAULT 'difference' CHECK (pricing IN ('difference', 'fixed', 'free')),
                amount BIGINT CHECK (amount IS NULL OR amount >= 0),
                currency TEXT,
                active BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CONSTRAINT billing_plan_upgrades_distinct_chk CHECK (from_plan_id <> to_plan_id),
                CONSTRAINT billing_plan_upgrades_fixed_chk CHECK (pricing <> 'fixed' OR amount IS NOT NULL)
            )
        ]])
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS billing_plan_upgrades_path_uidx ON billing_plan_upgrades (from_plan_id, to_plan_id)")
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_coupons (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                app_id BIGINT REFERENCES billing_apps(id) ON DELETE CASCADE,
                code TEXT NOT NULL CHECK (code ~ '^[A-Z0-9_-]{2,40}$'),
                name TEXT,
                discount_type TEXT NOT NULL CHECK (discount_type IN ('percent', 'amount')),
                percent_off NUMERIC(5,2) CHECK (percent_off IS NULL OR (percent_off > 0 AND percent_off <= 100)),
                amount_off BIGINT CHECK (amount_off IS NULL OR amount_off > 0),
                currency TEXT,
                duration TEXT NOT NULL DEFAULT 'once' CHECK (duration IN ('once', 'repeating', 'forever')),
                duration_months INTEGER CHECK (duration_months IS NULL OR duration_months BETWEEN 1 AND 120),
                plan_ids JSONB,
                max_redemptions INTEGER CHECK (max_redemptions IS NULL OR max_redemptions >= 1),
                per_customer_limit INTEGER CHECK (per_customer_limit IS NULL OR per_customer_limit >= 1),
                redemptions_count INTEGER NOT NULL DEFAULT 0,
                starts_at TIMESTAMPTZ,
                expires_at TIMESTAMPTZ,
                active BOOLEAN NOT NULL DEFAULT TRUE,
                stripe_refs JSONB NOT NULL DEFAULT '{}',
                created_by TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                deleted_at TIMESTAMPTZ,
                CONSTRAINT billing_coupons_value_chk CHECK (
                    (discount_type = 'percent' AND percent_off IS NOT NULL AND amount_off IS NULL)
                    OR (discount_type = 'amount' AND amount_off IS NOT NULL AND currency IS NOT NULL AND percent_off IS NULL)),
                CONSTRAINT billing_coupons_duration_chk CHECK ((duration = 'repeating') = (duration_months IS NOT NULL))
            )
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS billing_coupons_ns_code_uidx
            ON billing_coupons (namespace_id, code) WHERE deleted_at IS NULL
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_coupon_redemptions (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                coupon_id BIGINT NOT NULL REFERENCES billing_coupons(id) ON DELETE CASCADE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
                purchase_id BIGINT REFERENCES billing_purchases(id) ON DELETE SET NULL,
                subscription_id BIGINT REFERENCES billing_subscriptions(id) ON DELETE SET NULL,
                amount_off BIGINT NOT NULL DEFAULT 0,
                currency TEXT,
                redeemed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS billing_coupon_redemptions_coupon_idx ON billing_coupon_redemptions (coupon_id, customer_id)")
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_plan_changes (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                app_id BIGINT NOT NULL REFERENCES billing_apps(id) ON DELETE CASCADE,
                customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
                from_plan_id BIGINT REFERENCES billing_plans(id) ON DELETE SET NULL,
                to_plan_id BIGINT REFERENCES billing_plans(id) ON DELETE SET NULL,
                kind TEXT NOT NULL CHECK (kind IN ('new', 'upgrade', 'downgrade', 'renewal', 'cancel')),
                source TEXT NOT NULL,
                amount BIGINT NOT NULL DEFAULT 0,
                currency TEXT,
                coupon_id BIGINT REFERENCES billing_coupons(id) ON DELETE SET NULL,
                purchase_id BIGINT REFERENCES billing_purchases(id) ON DELETE SET NULL,
                subscription_id BIGINT REFERENCES billing_subscriptions(id) ON DELETE SET NULL,
                license_id BIGINT REFERENCES billing_licenses(id) ON DELETE SET NULL,
                actor TEXT,
                note TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS billing_plan_changes_customer_idx ON billing_plan_changes (app_id, customer_id, created_at DESC)")
    end,

    [13] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_access_links (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                app_id BIGINT NOT NULL REFERENCES billing_apps(id) ON DELETE CASCADE,
                customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
                token_hash TEXT UNIQUE,
                return_url TEXT,
                expires_at TIMESTAMPTZ NOT NULL,
                sent_at TIMESTAMPTZ,
                used_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_customer_sessions (
                id BIGSERIAL PRIMARY KEY,
                app_id BIGINT NOT NULL REFERENCES billing_apps(id) ON DELETE CASCADE,
                customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
                token_hash TEXT NOT NULL UNIQUE,
                expires_at TIMESTAMPTZ NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS billing_idempotency (
                id BIGSERIAL PRIMARY KEY,
                scope TEXT NOT NULL,
                idem_key TEXT NOT NULL,
                request_hash TEXT NOT NULL,
                status INTEGER,
                response TEXT,
                expires_at TIMESTAMPTZ NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS billing_idempotency_key_uidx ON billing_idempotency (scope, idem_key)")
        db.query("CREATE INDEX IF NOT EXISTS billing_idempotency_expiry_idx ON billing_idempotency (expires_at)")
    end,
}
