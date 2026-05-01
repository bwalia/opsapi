--[[
    CRM System Migrations
    =====================

    A multi-tenant CRM system with pipelines, accounts, contacts, deals,
    and activities tracking.

    Tables created:
    - crm_pipelines    : Sales pipelines with configurable stages
    - crm_accounts     : Company/organization accounts
    - crm_contacts     : Individual contacts linked to accounts
    - crm_deals        : Sales deals/opportunities in pipelines
    - crm_activities   : Activity log (calls, emails, meetings, notes, tasks)
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create crm_pipelines table
    -- ========================================
    [1] = function()
        if table_exists("crm_pipelines") then return end

        db.query([[
            CREATE TABLE crm_pipelines (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                description TEXT,
                stages JSONB DEFAULT '[]',
                is_default BOOLEAN DEFAULT false,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        pcall(function()
            db.query([[CREATE INDEX crm_pipelines_namespace_id_idx ON crm_pipelines (namespace_id)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_pipelines_uuid_idx ON crm_pipelines (uuid)]])
        end)
    end,

    -- ========================================
    -- [2] Create crm_accounts table
    -- ========================================
    [2] = function()
        if table_exists("crm_accounts") then return end

        db.query([[
            CREATE TABLE crm_accounts (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                industry TEXT,
                website TEXT,
                phone TEXT,
                email TEXT,
                address_line1 TEXT,
                address_line2 TEXT,
                city TEXT,
                state TEXT,
                postal_code TEXT,
                country TEXT,
                annual_revenue DECIMAL(15,2),
                employee_count INTEGER,
                owner_user_uuid TEXT NOT NULL,
                status TEXT DEFAULT 'active',
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        pcall(function()
            db.query([[CREATE INDEX crm_accounts_namespace_status_idx ON crm_accounts (namespace_id, status)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_accounts_owner_user_uuid_idx ON crm_accounts (owner_user_uuid)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_accounts_email_idx ON crm_accounts (email)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_accounts_created_at_brin_idx ON crm_accounts USING BRIN (created_at)]])
        end)
    end,

    -- ========================================
    -- [3] Create crm_contacts table
    -- ========================================
    [3] = function()
        if table_exists("crm_contacts") then return end

        db.query([[
            CREATE TABLE crm_contacts (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                account_id BIGINT DEFAULT NULL REFERENCES crm_accounts(id) ON DELETE SET NULL,
                first_name TEXT NOT NULL,
                last_name TEXT,
                email TEXT,
                phone TEXT,
                mobile TEXT,
                job_title TEXT,
                department TEXT,
                owner_user_uuid TEXT NOT NULL,
                status TEXT DEFAULT 'active',
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        pcall(function()
            db.query([[CREATE INDEX crm_contacts_namespace_status_idx ON crm_contacts (namespace_id, status)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_contacts_account_id_idx ON crm_contacts (account_id)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_contacts_owner_user_uuid_idx ON crm_contacts (owner_user_uuid)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_contacts_email_idx ON crm_contacts (email)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_contacts_created_at_brin_idx ON crm_contacts USING BRIN (created_at)]])
        end)
    end,

    -- ========================================
    -- [4] Create crm_deals table
    -- ========================================
    [4] = function()
        if table_exists("crm_deals") then return end

        db.query([[
            CREATE TABLE crm_deals (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                pipeline_id BIGINT DEFAULT NULL REFERENCES crm_pipelines(id) ON DELETE SET NULL,
                account_id BIGINT DEFAULT NULL REFERENCES crm_accounts(id) ON DELETE SET NULL,
                contact_id BIGINT DEFAULT NULL REFERENCES crm_contacts(id) ON DELETE SET NULL,
                name TEXT NOT NULL,
                value DECIMAL(15,2) DEFAULT 0,
                currency TEXT DEFAULT 'USD',
                stage TEXT DEFAULT 'new',
                probability INTEGER DEFAULT 0,
                expected_close_date DATE,
                actual_close_date DATE,
                won_at TIMESTAMP,
                lost_at TIMESTAMP,
                lost_reason TEXT,
                owner_user_uuid TEXT NOT NULL,
                status TEXT DEFAULT 'open',
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        pcall(function()
            db.query([[CREATE INDEX crm_deals_namespace_status_idx ON crm_deals (namespace_id, status)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_deals_pipeline_id_idx ON crm_deals (pipeline_id)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_deals_account_id_idx ON crm_deals (account_id)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_deals_contact_id_idx ON crm_deals (contact_id)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_deals_owner_user_uuid_idx ON crm_deals (owner_user_uuid)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_deals_stage_idx ON crm_deals (stage)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_deals_created_at_brin_idx ON crm_deals USING BRIN (created_at)]])
        end)
    end,

    -- ========================================
    -- [5] Create crm_activities table
    -- ========================================
    [5] = function()
        if table_exists("crm_activities") then return end

        db.query([[
            CREATE TABLE crm_activities (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                activity_type TEXT NOT NULL,
                subject TEXT NOT NULL,
                description TEXT,
                account_id BIGINT DEFAULT NULL REFERENCES crm_accounts(id) ON DELETE SET NULL,
                contact_id BIGINT DEFAULT NULL REFERENCES crm_contacts(id) ON DELETE SET NULL,
                deal_id BIGINT DEFAULT NULL REFERENCES crm_deals(id) ON DELETE SET NULL,
                owner_user_uuid TEXT NOT NULL,
                activity_date TIMESTAMP DEFAULT NOW(),
                duration_minutes INTEGER,
                completed_at TIMESTAMP,
                status TEXT DEFAULT 'planned',
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        pcall(function()
            db.query([[CREATE INDEX crm_activities_namespace_type_idx ON crm_activities (namespace_id, activity_type)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_activities_account_id_idx ON crm_activities (account_id)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_activities_contact_id_idx ON crm_activities (contact_id)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_activities_deal_id_idx ON crm_activities (deal_id)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_activities_owner_user_uuid_idx ON crm_activities (owner_user_uuid)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_activities_created_at_brin_idx ON crm_activities USING BRIN (created_at)]])
        end)
    end
}
