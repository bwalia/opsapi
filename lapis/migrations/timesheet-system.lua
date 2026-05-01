--[[
    Timesheet System Migrations
    ===========================

    Creates tables for timesheet management:
    - timesheets: Period-based timesheet records with approval workflow
    - timesheet_entries: Individual time entries within a timesheet
    - timesheet_approvals: Audit trail for approval/rejection actions
]]

local db = require("lapis.db")

-- Helper to check if table exists
local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create timesheets table
    -- ========================================
    [1] = function()
        if table_exists("timesheets") then return end

        db.query([[
            CREATE TABLE timesheets (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                user_uuid TEXT NOT NULL,
                period_start DATE NOT NULL,
                period_end DATE NOT NULL,
                status TEXT DEFAULT 'draft' CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'void')),
                total_hours DECIMAL(8,2) DEFAULT 0,
                billable_hours DECIMAL(8,2) DEFAULT 0,
                submitted_at TIMESTAMP,
                approved_at TIMESTAMP,
                approved_by_uuid TEXT,
                rejected_at TIMESTAMP,
                rejected_by_uuid TEXT,
                rejection_reason TEXT,
                notes TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- Indexes
        pcall(function()
            db.query([[
                CREATE INDEX timesheets_namespace_user_idx
                ON timesheets (namespace_id, user_uuid)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX timesheets_namespace_status_idx
                ON timesheets (namespace_id, status)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX timesheets_period_idx
                ON timesheets (period_start, period_end)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX timesheets_created_at_brin
                ON timesheets USING BRIN (created_at)
            ]])
        end)
    end,

    -- ========================================
    -- [2] Create timesheet_entries table
    -- ========================================
    [2] = function()
        if table_exists("timesheet_entries") then return end

        db.query([[
            CREATE TABLE timesheet_entries (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                timesheet_id BIGINT NOT NULL REFERENCES timesheets(id) ON DELETE CASCADE,
                user_uuid TEXT NOT NULL,
                entry_date DATE NOT NULL,
                hours DECIMAL(6,2) NOT NULL CHECK (hours >= 0 AND hours <= 24),
                description TEXT,
                project_reference TEXT,
                task_reference TEXT,
                is_billable BOOLEAN DEFAULT true,
                hourly_rate DECIMAL(10,2),
                category TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- Indexes
        pcall(function()
            db.query([[
                CREATE INDEX timesheet_entries_timesheet_id_idx
                ON timesheet_entries (timesheet_id)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX timesheet_entries_namespace_user_date_idx
                ON timesheet_entries (namespace_id, user_uuid, entry_date)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX timesheet_entries_is_billable_idx
                ON timesheet_entries (is_billable)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX timesheet_entries_created_at_brin
                ON timesheet_entries USING BRIN (created_at)
            ]])
        end)
    end,

    -- ========================================
    -- [3] Create timesheet_approvals table
    -- ========================================
    [3] = function()
        if table_exists("timesheet_approvals") then return end

        db.query([[
            CREATE TABLE timesheet_approvals (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                timesheet_id BIGINT NOT NULL REFERENCES timesheets(id) ON DELETE CASCADE,
                approver_uuid TEXT NOT NULL,
                action TEXT NOT NULL CHECK (action IN ('approved', 'rejected')),
                comments TEXT,
                created_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Indexes
        pcall(function()
            db.query([[
                CREATE INDEX timesheet_approvals_timesheet_id_idx
                ON timesheet_approvals (timesheet_id)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX timesheet_approvals_approver_uuid_idx
                ON timesheet_approvals (approver_uuid)
            ]])
        end)
    end,
}
