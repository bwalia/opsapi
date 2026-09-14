--[[
    Field Service — Service Requests (complaints) migrations
    ========================================================

    Phase 2 of the complaint / job-management extension
    (see FIELD_SERVICE_COMPLAINT_MANAGEMENT_PLAN.md).

    - fs_request_sequences : per-namespace SR-0001 counter (race-safe, own migration)
    - fs_service_requests  : the complaint intake layer. One request can spawn
                             many jobs; FKs into crm_accounts / crm_contacts /
                             fs_sites / fs_assets.
    - fs_jobs (ALTER)      : + service_request_id, + asset_id (nullable, so existing
                             and ad-hoc jobs still work).

    Gated on FEATURES.FIELD_SERVICE. crm_*/fs_sites/fs_assets exist from
    lower-numbered migrations. One table per migration entry.
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
    -- [1] fs_request_sequences   (868)
    -- ========================================
    [1] = function()
        if table_exists("fs_request_sequences") then return end

        db.query([[
            CREATE TABLE fs_request_sequences (
                namespace_id BIGINT PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
                prefix TEXT NOT NULL DEFAULT 'SR',
                current_number INTEGER NOT NULL DEFAULT 0,
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])
    end,

    -- ========================================
    -- [2] fs_service_requests   (869)
    -- ========================================
    [2] = function()
        if table_exists("fs_service_requests") then return end

        db.query([[
            CREATE TABLE fs_service_requests (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                request_number TEXT NOT NULL,
                account_id BIGINT REFERENCES crm_accounts(id) ON DELETE SET NULL,   -- the customer (hospital)
                contact_id BIGINT REFERENCES crm_contacts(id) ON DELETE SET NULL,   -- who called
                site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL,
                asset_id BIGINT REFERENCES fs_assets(id) ON DELETE SET NULL,        -- the unit that's faulty
                title TEXT NOT NULL,
                description TEXT,
                fault_category TEXT,                    -- lookup-driven
                channel TEXT NOT NULL DEFAULT 'phone'
                    CHECK (channel IN ('phone', 'app', 'email', 'portal', 'web', 'other')),
                reported_by TEXT,                       -- free-text name when the caller isn't a stored contact
                priority TEXT NOT NULL DEFAULT 'normal'
                    CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
                status TEXT NOT NULL DEFAULT 'new'
                    CHECK (status IN ('new', 'triaged', 'assigned', 'in_progress', 'on_hold',
                                      'resolved', 'closed', 'rejected', 'duplicate')),
                assigned_manager_uuid TEXT,
                sla_response_due_at TIMESTAMP,
                sla_resolve_due_at TIMESTAMP,
                first_response_at TIMESTAMP,
                resolved_at TIMESTAMP,
                closed_at TIMESTAMP,
                resolution_notes TEXT,
                metadata JSONB DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP,
                UNIQUE (namespace_id, request_number)
            )
        ]])

        index([[CREATE INDEX fs_service_requests_ns_status_idx ON fs_service_requests (namespace_id, status)]])
        index([[CREATE INDEX fs_service_requests_ns_account_idx ON fs_service_requests (namespace_id, account_id)]])
        index([[CREATE INDEX fs_service_requests_ns_asset_idx ON fs_service_requests (namespace_id, asset_id)]])
        index([[CREATE INDEX fs_service_requests_ns_manager_idx
                ON fs_service_requests (namespace_id, assigned_manager_uuid)]])
        index([[CREATE INDEX fs_service_requests_created_at_brin ON fs_service_requests USING BRIN (created_at)]])
    end,

    -- ========================================
    -- [3] fs_jobs: link to a service request + asset   (870)
    -- ========================================
    [3] = function()
        db.query([[
            ALTER TABLE fs_jobs
                ADD COLUMN IF NOT EXISTS service_request_id BIGINT
                    REFERENCES fs_service_requests(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS asset_id BIGINT
                    REFERENCES fs_assets(id) ON DELETE SET NULL
        ]])
        index([[CREATE INDEX IF NOT EXISTS fs_jobs_service_request_idx
                ON fs_jobs (namespace_id, service_request_id)]])
        index([[CREATE INDEX IF NOT EXISTS fs_jobs_asset_idx ON fs_jobs (namespace_id, asset_id)]])
    end,
}
