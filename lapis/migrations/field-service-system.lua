--[[
    Field Service System Migrations
    ===============================

    Engineer site visits + service manager: jobs broken into phases, with
    engineer visits scheduled against them.

    - fs_job_types        : job categories (e.g. "Boiler Service", "Installation")
    - fs_phase_templates  : ordered phase templates per job type
    - fs_sites            : customer site addresses (linked to crm_accounts)
    - fs_job_sequences    : per-namespace job number counter (JOB-0001)
    - fs_jobs             : service jobs (customer, site, manager, status)
    - fs_job_phases       : a job's phases — copied from the job type's
                            templates on creation, then editable per job
    - fs_visits           : engineer site visits (schedule, check-in/out,
                            labour hours, timesheet + invoice links)
    - fs_job_items        : parts / materials / expenses charged to a job
    - fs_job_activity     : per-job audit trail

    Gated on FEATURES.FIELD_SERVICE. Every preset that enables it also enables
    CRM, TIMESHEETS and INVOICING (see helper/project-config.lua), and those
    tables are created by lower-numbered migrations, so the hard FKs to
    crm_accounts / crm_contacts / invoices below are safe.
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
    -- [1] fs_job_types
    -- ========================================
    [1] = function()
        if table_exists("fs_job_types") then return end

        db.query([[
            CREATE TABLE fs_job_types (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                description TEXT,
                color TEXT,
                default_hourly_rate DECIMAL(10,2),
                is_active BOOLEAN NOT NULL DEFAULT true,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_job_types_namespace_idx ON fs_job_types (namespace_id, is_active)]])
    end,

    -- ========================================
    -- [2] fs_phase_templates
    -- ========================================
    [2] = function()
        if table_exists("fs_phase_templates") then return end

        db.query([[
            CREATE TABLE fs_phase_templates (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                job_type_id BIGINT NOT NULL REFERENCES fs_job_types(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                description TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                requires_visit BOOLEAN NOT NULL DEFAULT true,
                requires_signoff BOOLEAN NOT NULL DEFAULT false,
                estimated_hours DECIMAL(8,2),
                checklist JSONB NOT NULL DEFAULT '[]',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_phase_templates_job_type_idx ON fs_phase_templates (job_type_id, sort_order)]])
    end,

    -- ========================================
    -- [3] fs_sites
    -- ========================================
    [3] = function()
        if table_exists("fs_sites") then return end

        db.query([[
            CREATE TABLE fs_sites (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                account_id BIGINT REFERENCES crm_accounts(id) ON DELETE SET NULL,
                name TEXT NOT NULL,
                address_line1 TEXT,
                address_line2 TEXT,
                city TEXT,
                county TEXT,
                postal_code TEXT,
                country TEXT DEFAULT 'GB',
                latitude DECIMAL(10,7),
                longitude DECIMAL(10,7),
                contact_name TEXT,
                contact_phone TEXT,
                contact_email TEXT,
                access_notes TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_sites_namespace_account_idx ON fs_sites (namespace_id, account_id)]])
        index([[CREATE INDEX fs_sites_postal_code_idx ON fs_sites (namespace_id, postal_code)]])
    end,

    -- ========================================
    -- [4] fs_job_sequences + fs_jobs
    -- ========================================
    [4] = function()
        if not table_exists("fs_job_sequences") then
            db.query([[
                CREATE TABLE fs_job_sequences (
                    namespace_id BIGINT PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
                    prefix TEXT NOT NULL DEFAULT 'JOB',
                    current_number INTEGER NOT NULL DEFAULT 0,
                    updated_at TIMESTAMP DEFAULT NOW()
                )
            ]])
        end

        if table_exists("fs_jobs") then return end

        db.query([[
            CREATE TABLE fs_jobs (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                job_number TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT,
                job_type_id BIGINT REFERENCES fs_job_types(id) ON DELETE SET NULL,
                account_id BIGINT REFERENCES crm_accounts(id) ON DELETE SET NULL,
                contact_id BIGINT REFERENCES crm_contacts(id) ON DELETE SET NULL,
                site_id BIGINT REFERENCES fs_sites(id) ON DELETE SET NULL,
                status TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'scheduled', 'in_progress', 'on_hold', 'completed', 'cancelled')),
                priority TEXT NOT NULL DEFAULT 'normal'
                    CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
                service_manager_uuid TEXT,
                customer_reference TEXT,
                due_date DATE,
                estimated_hours DECIMAL(8,2),
                hourly_rate DECIMAL(10,2),
                currency TEXT NOT NULL DEFAULT 'GBP',
                started_at TIMESTAMP,
                completed_at TIMESTAMP,
                cancelled_reason TEXT,
                invoice_id BIGINT REFERENCES invoices(id) ON DELETE SET NULL,
                invoiced_at TIMESTAMP,
                notes TEXT,
                metadata JSONB DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP,
                UNIQUE (namespace_id, job_number)
            )
        ]])

        index([[CREATE INDEX fs_jobs_namespace_status_idx ON fs_jobs (namespace_id, status)]])
        index([[CREATE INDEX fs_jobs_account_idx ON fs_jobs (namespace_id, account_id)]])
        index([[CREATE INDEX fs_jobs_manager_idx ON fs_jobs (namespace_id, service_manager_uuid)]])
        index([[CREATE INDEX fs_jobs_created_at_brin ON fs_jobs USING BRIN (created_at)]])
    end,

    -- ========================================
    -- [5] fs_job_phases
    -- ========================================
    [5] = function()
        if table_exists("fs_job_phases") then return end

        db.query([[
            CREATE TABLE fs_job_phases (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                job_id BIGINT NOT NULL REFERENCES fs_jobs(id) ON DELETE CASCADE,
                template_id BIGINT REFERENCES fs_phase_templates(id) ON DELETE SET NULL,
                name TEXT NOT NULL,
                description TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'in_progress', 'blocked', 'completed', 'skipped')),
                requires_visit BOOLEAN NOT NULL DEFAULT true,
                requires_signoff BOOLEAN NOT NULL DEFAULT false,
                estimated_hours DECIMAL(8,2),
                checklist JSONB NOT NULL DEFAULT '[]',
                started_at TIMESTAMP,
                completed_at TIMESTAMP,
                completed_by_uuid TEXT,
                signed_off_at TIMESTAMP,
                signed_off_by_uuid TEXT,
                signoff_name TEXT,
                notes TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_job_phases_job_idx ON fs_job_phases (job_id, sort_order)]])
    end,

    -- ========================================
    -- [6] fs_visits
    -- ========================================
    [6] = function()
        if table_exists("fs_visits") then return end

        db.query([[
            CREATE TABLE fs_visits (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                job_id BIGINT NOT NULL REFERENCES fs_jobs(id) ON DELETE CASCADE,
                phase_id BIGINT REFERENCES fs_job_phases(id) ON DELETE SET NULL,
                engineer_user_uuid TEXT,
                status TEXT NOT NULL DEFAULT 'scheduled'
                    CHECK (status IN ('scheduled', 'en_route', 'on_site', 'completed', 'cancelled', 'no_access')),
                scheduled_start TIMESTAMP NOT NULL,
                scheduled_end TIMESTAMP,
                checked_in_at TIMESTAMP,
                checked_out_at TIMESTAMP,
                check_in_lat DECIMAL(10,7),
                check_in_lng DECIMAL(10,7),
                check_out_lat DECIMAL(10,7),
                check_out_lng DECIMAL(10,7),
                instructions TEXT,
                work_summary TEXT,
                labour_hours DECIMAL(6,2),
                is_billable BOOLEAN NOT NULL DEFAULT true,
                hourly_rate DECIMAL(10,2),
                customer_signoff_name TEXT,
                customer_signed_at TIMESTAMP,
                follow_up_required BOOLEAN NOT NULL DEFAULT false,
                follow_up_notes TEXT,
                cancelled_reason TEXT,
                timesheet_uuid TEXT,
                timesheet_entry_id BIGINT,
                invoice_line_item_id BIGINT,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_visits_job_idx ON fs_visits (job_id)]])
        index([[CREATE INDEX fs_visits_engineer_schedule_idx ON fs_visits (namespace_id, engineer_user_uuid, scheduled_start)]])
        index([[CREATE INDEX fs_visits_schedule_idx ON fs_visits (namespace_id, scheduled_start)]])
    end,

    -- ========================================
    -- [7] fs_job_items
    -- ========================================
    [7] = function()
        if table_exists("fs_job_items") then return end

        db.query([[
            CREATE TABLE fs_job_items (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                job_id BIGINT NOT NULL REFERENCES fs_jobs(id) ON DELETE CASCADE,
                visit_id BIGINT REFERENCES fs_visits(id) ON DELETE SET NULL,
                phase_id BIGINT REFERENCES fs_job_phases(id) ON DELETE SET NULL,
                item_type TEXT NOT NULL DEFAULT 'part'
                    CHECK (item_type IN ('part', 'material', 'labour', 'expense', 'other')),
                description TEXT NOT NULL,
                quantity DECIMAL(10,2) NOT NULL DEFAULT 1,
                unit_price DECIMAL(12,2) NOT NULL DEFAULT 0,
                tax_rate DECIMAL(5,2) NOT NULL DEFAULT 0,
                is_billable BOOLEAN NOT NULL DEFAULT true,
                invoice_line_item_id BIGINT,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        index([[CREATE INDEX fs_job_items_job_idx ON fs_job_items (job_id)]])
    end,

    -- ========================================
    -- [8] fs_job_activity
    -- ========================================
    [8] = function()
        if table_exists("fs_job_activity") then return end

        db.query([[
            CREATE TABLE fs_job_activity (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                job_id BIGINT NOT NULL REFERENCES fs_jobs(id) ON DELETE CASCADE,
                actor_uuid TEXT,
                action TEXT NOT NULL,
                message TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        index([[CREATE INDEX fs_job_activity_job_idx ON fs_job_activity (job_id, created_at DESC)]])
    end,
}
