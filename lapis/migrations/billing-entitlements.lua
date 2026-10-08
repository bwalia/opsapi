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
                offline_policy TEXT NOT NULL DEFAULT 'fail_closed' CHECK (offline_policy IN ('fail_open', 'fail_closed')),
                offline_grace_seconds INTEGER NOT NULL DEFAULT 259200 CHECK (offline_grace_seconds >= 0),
                entitlement_ttl_seconds INTEGER NOT NULL DEFAULT 900 CHECK (entitlement_ttl_seconds BETWEEN 60 AND 86400),
                past_due_grace_days INTEGER NOT NULL DEFAULT 7 CHECK (past_due_grace_days >= 0),
                allowed_return_urls JSONB NOT NULL DEFAULT '[]',
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
}
