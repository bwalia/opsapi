--[[
    Field Service — Assets & Employees migrations
    =============================================

    Phase 1 of the complaint / job-management extension
    (see FIELD_SERVICE_COMPLAINT_MANAGEMENT_PLAN.md).

    - fs_assets  : the equipment installed at a customer site — the AC / fridge
                   units a complaint is raised against. FKs into crm_accounts
                   (owner) and fs_sites (where it lives).
    - employees  : staff directory linked to a users login. An engineer is an
                   active employee flagged is_engineer; assignment picks from here.

    Gated on FEATURES.FIELD_SERVICE. crm_accounts / fs_sites are created by
    lower-numbered migrations, so the FKs below are safe.

    One table per migration entry (lesson from the 853 reconcile blind spot).
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

local function index(sql)
    pcall(function() db.query(sql) end)
end

return {
    -- ========================================
    -- [1] fs_assets   (862)
    -- ========================================
    [1] = function()
        if table_exists("fs_assets") then return end

        db.query([[
            CREATE TABLE fs_assets (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                account_id BIGINT REFERENCES crm_accounts(id) ON DELETE SET NULL,   -- owner (e.g. the hospital)
                site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL,          -- where it lives
                name TEXT NOT NULL,
                asset_tag TEXT,
                serial_number TEXT,
                category TEXT,                          -- air_conditioner | refrigerator | ... (lookup-driven)
                manufacturer TEXT,
                model TEXT,
                location_detail TEXT,                   -- building / floor / room within the site
                installed_at DATE,
                warranty_expires_at DATE,
                status TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive', 'decommissioned')),
                notes TEXT,
                metadata JSONB DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_assets_namespace_account_idx ON fs_assets (namespace_id, account_id)]])
        index([[CREATE INDEX fs_assets_namespace_site_idx ON fs_assets (namespace_id, site_id)]])
        index([[CREATE INDEX fs_assets_namespace_status_idx ON fs_assets (namespace_id, status)]])
        index([[CREATE INDEX fs_assets_serial_idx ON fs_assets (namespace_id, serial_number)]])
    end,

    -- ========================================
    -- [2] employees   (863)
    -- ========================================
    [2] = function()
        if table_exists("employees") then return end

        db.query([[
            CREATE TABLE employees (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                user_uuid TEXT NOT NULL,                -- → users.uuid (their OpsAPI login)
                employee_code TEXT,
                job_title TEXT,
                is_engineer BOOLEAN NOT NULL DEFAULT false,
                is_active BOOLEAN NOT NULL DEFAULT true,
                phone TEXT,
                email TEXT,
                region TEXT,                            -- team / area for assignment
                skills JSONB NOT NULL DEFAULT '[]',     -- certifications / competencies
                hourly_cost_rate DECIMAL(10,2),         -- INTERNAL cost (≠ the customer bill rate)
                metadata JSONB DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- One live employee profile per user per tenant (partial, so a soft-deleted
        -- profile can be re-created).
        index([[CREATE UNIQUE INDEX employees_ns_user_active_idx
                ON employees (namespace_id, user_uuid) WHERE deleted_at IS NULL]])
        index([[CREATE INDEX employees_ns_engineer_idx ON employees (namespace_id, is_engineer, is_active)]])
    end,
}
