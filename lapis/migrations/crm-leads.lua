--[[
    CRM Leads Migrations
    ====================

    Lead capture and management for the CRM system.
    Supports inbound leads from websites, email, social media, and manual entry
    with a conversion workflow into CRM contacts and deals.

    Tables created:
    - crm_leads : Inbound lead capture with source tracking and conversion workflow
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

local function column_exists(tbl, col)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.columns
            WHERE table_name = ? AND column_name = ?
        ) as exists
    ]], tbl, col)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create crm_leads table
    -- ========================================
    [1] = function()
        if table_exists("crm_leads") then return end

        db.query([[
            CREATE TABLE IF NOT EXISTS crm_leads (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,

                -- Contact info
                first_name TEXT NOT NULL,
                last_name TEXT,
                email TEXT,
                phone TEXT,
                company_name TEXT,
                job_title TEXT,

                -- Source tracking
                source TEXT DEFAULT 'manual',
                channel TEXT,
                campaign TEXT,
                referrer_url TEXT,
                landing_page_url TEXT,

                -- Status workflow
                status TEXT DEFAULT 'new',
                lost_reason TEXT,

                -- Assignment & scoring
                owner_user_uuid TEXT,
                score INTEGER DEFAULT 0,
                priority TEXT DEFAULT 'medium',

                -- Notes
                notes TEXT,

                -- Conversion tracking
                converted_at TIMESTAMP,
                converted_contact_id BIGINT REFERENCES crm_contacts(id) ON DELETE SET NULL,
                converted_deal_id BIGINT REFERENCES crm_deals(id) ON DELETE SET NULL,

                -- Standard CRM columns
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        pcall(function()
            db.query([[CREATE INDEX crm_leads_namespace_status_idx ON crm_leads (namespace_id, status)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_leads_uuid_idx ON crm_leads (uuid)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_leads_owner_user_uuid_idx ON crm_leads (owner_user_uuid)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_leads_email_idx ON crm_leads (email)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_leads_namespace_source_idx ON crm_leads (namespace_id, source)]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_leads_created_at_brin_idx ON crm_leads USING BRIN (created_at)]])
        end)
    end,

    -- ========================================
    -- [2] Add enquiry_id link column (bridges existing enquiries)
    -- ========================================
    [2] = function()
        if not table_exists("crm_leads") then return end
        if column_exists("crm_leads", "enquiry_id") then return end

        pcall(function()
            db.query([[ALTER TABLE crm_leads ADD COLUMN enquiry_id BIGINT]])
        end)
        pcall(function()
            db.query([[CREATE INDEX crm_leads_enquiry_id_idx ON crm_leads (enquiry_id)]])
        end)
        -- Only add FK if enquiries table exists
        if table_exists("enquiries") then
            pcall(function()
                db.query([[
                    ALTER TABLE crm_leads
                    ADD CONSTRAINT crm_leads_enquiry_fk
                    FOREIGN KEY (enquiry_id) REFERENCES enquiries(id) ON DELETE SET NULL
                ]])
            end)
        end
    end
}
