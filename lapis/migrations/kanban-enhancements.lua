--[[
    Kanban Project System Enhancements
    ===================================

    Production-ready enhancements for the kanban system:

    1. Time Tracking System
       - Time entries for tasks
       - Billable hours tracking
       - Time reports per project/user

    2. Unified Notifications System
       - Cross-platform notifications (task updates, mentions, deadlines)
       - Notification preferences per user per project
       - Digest emails support

    3. Project Activity Feed
       - Aggregated activity across all project tasks
       - Filterable by action type, user, date range

    4. Enhanced Sprint Management
       - Sprint velocity tracking
       - Burndown data points
       - Sprint retrospective notes
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

-- Helper to check if table exists
local function table_exists(table_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_name = ?
        ) as exists
    ]], table_name)
    return result[1] and result[1].exists
end

-- Helper to check if column exists
local function column_exists(table_name, column_name)
    local result = db.query([[
        SELECT column_name FROM information_schema.columns
        WHERE table_name = ? AND column_name = ?
    ]], table_name, column_name)
    return #result > 0
end

-- Helper to check if index exists
local function index_exists(index_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM pg_indexes
            WHERE indexname = ?
        ) as exists
    ]], index_name)
    return result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create kanban_time_entries table
    -- ========================================
    [1] = function()
        if table_exists("kanban_time_entries") then return end

        schema.create_table("kanban_time_entries", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "task_id", types.integer },
            { "user_uuid", types.varchar },
            { "description", types.text({ null = true }) },
            -- Time tracking
            { "started_at", types.time },
            { "ended_at", types.time({ null = true }) },
            { "duration_minutes", types.integer({ default = 0 }) },
            -- Billing
            { "is_billable", types.boolean({ default = true }) },
            { "hourly_rate", "DECIMAL(10,2) DEFAULT NULL" },
            { "billed_amount", "DECIMAL(12,2) DEFAULT NULL" },
            { "invoice_id", types.varchar({ null = true }) },
            -- Status
            { "status", types.varchar({ default = "'logged'" }) }, -- logged, approved, invoiced
            { "approved_by", types.varchar({ null = true }) },
            { "approved_at", types.time({ null = true }) },
            -- Metadata
            { "metadata", "JSONB DEFAULT '{}'" },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_tasks
        pcall(function()
            db.query([[
                ALTER TABLE kanban_time_entries
                ADD CONSTRAINT kanban_time_entries_task_fk
                FOREIGN KEY (task_id) REFERENCES kanban_tasks(id) ON DELETE CASCADE
            ]])
        end)

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_time_entries
                ADD CONSTRAINT kanban_time_entries_status_check
                CHECK (status IN ('running', 'logged', 'approved', 'invoiced', 'rejected'))
            ]])
        end)
    end,

    -- ========================================
    -- [2] Add kanban_time_entries indexes
    -- ========================================
    [2] = function()
        if not index_exists("idx_kanban_time_entries_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_time_entries_uuid ON kanban_time_entries (uuid)")
        end

        -- Task time entries (most common query)
        if not index_exists("idx_kanban_time_entries_task") then
            db.query([[
                CREATE INDEX idx_kanban_time_entries_task
                ON kanban_time_entries (task_id, started_at DESC)
                WHERE deleted_at IS NULL
            ]])
        end

        -- User time entries (for timesheets)
        if not index_exists("idx_kanban_time_entries_user") then
            db.query([[
                CREATE INDEX idx_kanban_time_entries_user
                ON kanban_time_entries (user_uuid, started_at DESC)
                WHERE deleted_at IS NULL
            ]])
        end

        -- Date range queries for reports
        if not index_exists("idx_kanban_time_entries_date_range") then
            db.query([[
                CREATE INDEX idx_kanban_time_entries_date_range
                ON kanban_time_entries (started_at, ended_at)
                WHERE deleted_at IS NULL
            ]])
        end

        -- Billable entries for invoicing
        if not index_exists("idx_kanban_time_entries_billable") then
            db.query([[
                CREATE INDEX idx_kanban_time_entries_billable
                ON kanban_time_entries (is_billable, status)
                WHERE deleted_at IS NULL AND is_billable = true
            ]])
        end

        -- Running timers (for checking active timers)
        if not index_exists("idx_kanban_time_entries_running") then
            db.query([[
                CREATE INDEX idx_kanban_time_entries_running
                ON kanban_time_entries (user_uuid)
                WHERE deleted_at IS NULL AND status = 'running' AND ended_at IS NULL
            ]])
        end

        -- BRIN for time-series
        if not index_exists("idx_kanban_time_entries_started_brin") then
            pcall(function()
                db.query([[
                    CREATE INDEX idx_kanban_time_entries_started_brin
                    ON kanban_time_entries USING BRIN (started_at)
                ]])
            end)
        end
    end,

    -- ========================================
    -- [3] Create kanban_notifications table
    -- ========================================
    [3] = function()
        if table_exists("kanban_notifications") then return end

        schema.create_table("kanban_notifications", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "recipient_user_uuid", types.varchar },
            -- Notification content
            { "type", types.varchar }, -- task_assigned, task_commented, task_mentioned, due_date, etc.
            { "title", types.varchar },
            { "message", types.text },
            { "action_url", types.varchar({ null = true }) },
            -- Related entities
            { "project_id", types.integer({ null = true }) },
            { "task_id", types.integer({ null = true }) },
            { "comment_id", types.integer({ null = true }) },
            { "actor_user_uuid", types.varchar({ null = true }) },
            -- Status
            { "is_read", types.boolean({ default = false }) },
            { "read_at", types.time({ null = true }) },
            { "is_email_sent", types.boolean({ default = false }) },
            { "email_sent_at", types.time({ null = true }) },
            { "is_push_sent", types.boolean({ default = false }) },
            { "push_sent_at", types.time({ null = true }) },
            -- Priority and grouping
            { "priority", types.varchar({ default = "'normal'" }) }, -- low, normal, high, urgent
            { "group_key", types.varchar({ null = true }) }, -- For grouping similar notifications
            -- Metadata
            { "metadata", "JSONB DEFAULT '{}'" },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "expires_at", types.time({ null = true }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign keys
        pcall(function()
            db.query([[
                ALTER TABLE kanban_notifications
                ADD CONSTRAINT kanban_notifications_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE kanban_notifications
                ADD CONSTRAINT kanban_notifications_project_fk
                FOREIGN KEY (project_id) REFERENCES kanban_projects(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE kanban_notifications
                ADD CONSTRAINT kanban_notifications_task_fk
                FOREIGN KEY (task_id) REFERENCES kanban_tasks(id) ON DELETE CASCADE
            ]])
        end)

        -- Type constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_notifications
                ADD CONSTRAINT kanban_notifications_type_check
                CHECK (type IN (
                    'task_assigned', 'task_unassigned', 'task_commented', 'task_mentioned',
                    'task_completed', 'task_status_changed', 'task_due_soon', 'task_overdue',
                    'project_invited', 'project_removed', 'project_role_changed',
                    'sprint_started', 'sprint_ended', 'checklist_completed',
                    'comment_reply', 'comment_mentioned', 'general'
                ))
            ]])
        end)

        -- Priority constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_notifications
                ADD CONSTRAINT kanban_notifications_priority_check
                CHECK (priority IN ('low', 'normal', 'high', 'urgent'))
            ]])
        end)
    end,

    -- ========================================
    -- [4] Add kanban_notifications indexes
    -- ========================================
    [4] = function()
        if not index_exists("idx_kanban_notifications_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_notifications_uuid ON kanban_notifications (uuid)")
        end

        -- User's unread notifications (critical for performance)
        if not index_exists("idx_kanban_notifications_user_unread") then
            db.query([[
                CREATE INDEX idx_kanban_notifications_user_unread
                ON kanban_notifications (recipient_user_uuid, created_at DESC)
                WHERE deleted_at IS NULL AND is_read = false
            ]])
        end

        -- All user notifications
        if not index_exists("idx_kanban_notifications_user_all") then
            db.query([[
                CREATE INDEX idx_kanban_notifications_user_all
                ON kanban_notifications (recipient_user_uuid, created_at DESC)
                WHERE deleted_at IS NULL
            ]])
        end

        -- By type for filtering
        if not index_exists("idx_kanban_notifications_type") then
            db.query([[
                CREATE INDEX idx_kanban_notifications_type
                ON kanban_notifications (type, created_at DESC)
                WHERE deleted_at IS NULL
            ]])
        end

        -- Group key for deduplication/grouping
        if not index_exists("idx_kanban_notifications_group") then
            db.query([[
                CREATE INDEX idx_kanban_notifications_group
                ON kanban_notifications (group_key, recipient_user_uuid)
                WHERE group_key IS NOT NULL AND deleted_at IS NULL
            ]])
        end

        -- Email pending
        if not index_exists("idx_kanban_notifications_email_pending") then
            db.query([[
                CREATE INDEX idx_kanban_notifications_email_pending
                ON kanban_notifications (created_at)
                WHERE deleted_at IS NULL AND is_email_sent = false
            ]])
        end

        -- BRIN for time-series
        if not index_exists("idx_kanban_notifications_created_brin") then
            pcall(function()
                db.query([[
                    CREATE INDEX idx_kanban_notifications_created_brin
                    ON kanban_notifications USING BRIN (created_at)
                ]])
            end)
        end
    end,

    -- ========================================
    -- [5] Create notification preferences table
    -- ========================================
    [5] = function()
        if table_exists("kanban_notification_preferences") then return end

        schema.create_table("kanban_notification_preferences", {
            { "id", types.serial },
            { "user_uuid", types.varchar },
            { "project_id", types.integer({ null = true }) }, -- NULL = global preferences
            -- Notification type settings (JSONB for flexibility)
            { "email_enabled", types.boolean({ default = true }) },
            { "push_enabled", types.boolean({ default = true }) },
            { "in_app_enabled", types.boolean({ default = true }) },
            -- Per-type settings
            { "preferences", "JSONB DEFAULT '{}'" },
            -- Digest settings
            { "digest_frequency", types.varchar({ default = "'instant'" }) }, -- instant, hourly, daily, weekly
            { "digest_hour", types.integer({ default = 9 }) }, -- Hour of day for digest (0-23)
            { "digest_day", types.integer({ default = 1 }) }, -- Day of week for weekly digest (0=Sun)
            -- Quiet hours
            { "quiet_hours_enabled", types.boolean({ default = false }) },
            { "quiet_hours_start", types.integer({ null = true }) }, -- Hour of day (0-23)
            { "quiet_hours_end", types.integer({ null = true }) },
            { "timezone", types.varchar({ default = "'UTC'" }) },
            -- Timestamps
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key
        pcall(function()
            db.query([[
                ALTER TABLE kanban_notification_preferences
                ADD CONSTRAINT kanban_notification_preferences_project_fk
                FOREIGN KEY (project_id) REFERENCES kanban_projects(id) ON DELETE CASCADE
            ]])
        end)

        -- Unique constraint: one preference record per user per project (or global)
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX kanban_notification_preferences_unique
                ON kanban_notification_preferences (user_uuid, COALESCE(project_id, 0))
            ]])
        end)
    end,

    -- ========================================
    -- [6] Create project activity feed view
    -- ========================================
    [6] = function()
        -- Drop existing view if it exists
        pcall(function()
            db.query("DROP VIEW IF EXISTS kanban_project_activity_feed")
        end)

        -- Create materialized view for project activity (better performance)
        pcall(function()
            db.query([[
                CREATE OR REPLACE VIEW kanban_project_activity_feed AS
                SELECT
                    a.id,
                    a.uuid,
                    a.task_id,
                    a.user_uuid,
                    a.action,
                    a.entity_type,
                    a.entity_id,
                    a.old_value,
                    a.new_value,
                    a.metadata,
                    a.created_at,
                    t.uuid as task_uuid,
                    t.title as task_title,
                    t.task_number,
                    b.id as board_id,
                    b.uuid as board_uuid,
                    b.name as board_name,
                    p.id as project_id,
                    p.uuid as project_uuid,
                    p.name as project_name,
                    p.namespace_id,
                    u.first_name as user_first_name,
                    u.last_name as user_last_name,
                    u.email as user_email
                FROM kanban_task_activities a
                INNER JOIN kanban_tasks t ON t.id = a.task_id
                INNER JOIN kanban_boards b ON b.id = t.board_id
                INNER JOIN kanban_projects p ON p.id = b.project_id
                LEFT JOIN users u ON u.uuid = a.user_uuid
                ORDER BY a.created_at DESC
            ]])
        end)
    end,

    -- ========================================
    -- [7] Add sprint burndown tracking
    -- ========================================
    [7] = function()
        if table_exists("kanban_sprint_burndown") then return end

        schema.create_table("kanban_sprint_burndown", {
            { "id", types.serial },
            { "sprint_id", types.integer },
            { "recorded_date", types.date },
            -- Points/counts at this snapshot
            { "total_points", types.integer({ default = 0 }) },
            { "completed_points", types.integer({ default = 0 }) },
            { "remaining_points", types.integer({ default = 0 }) },
            { "total_tasks", types.integer({ default = 0 }) },
            { "completed_tasks", types.integer({ default = 0 }) },
            { "remaining_tasks", types.integer({ default = 0 }) },
            -- Scope changes
            { "added_points", types.integer({ default = 0 }) },
            { "removed_points", types.integer({ default = 0 }) },
            -- Ideal burndown (for comparison)
            { "ideal_remaining", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key
        pcall(function()
            db.query([[
                ALTER TABLE kanban_sprint_burndown
                ADD CONSTRAINT kanban_sprint_burndown_sprint_fk
                FOREIGN KEY (sprint_id) REFERENCES kanban_sprints(id) ON DELETE CASCADE
            ]])
        end)

        -- Unique constraint: one record per sprint per day
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX kanban_sprint_burndown_unique
                ON kanban_sprint_burndown (sprint_id, recorded_date)
            ]])
        end)
    end,

    -- ========================================
    -- [8] Add sprint retrospective notes
    -- ========================================
    [8] = function()
        if column_exists("kanban_sprints", "retrospective") then return end

        -- Add retrospective and review fields to sprints
        pcall(function()
            schema.add_column("kanban_sprints", "retrospective", "JSONB DEFAULT '{}'")
        end)

        pcall(function()
            schema.add_column("kanban_sprints", "velocity", types.integer({ null = true }))
        end)

        pcall(function()
            schema.add_column("kanban_sprints", "review_notes", types.text({ null = true }))
        end)
    end,

    -- ========================================
    -- [9] Add task time tracking aggregates
    -- ========================================
    [9] = function()
        -- Trigger to update task time_spent_minutes from time entries
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_task_time_spent()
                RETURNS TRIGGER AS $$
                DECLARE
                    v_total_minutes INTEGER;
                BEGIN
                    -- Calculate total logged time for the task
                    SELECT COALESCE(SUM(duration_minutes), 0) INTO v_total_minutes
                    FROM kanban_time_entries
                    WHERE task_id = COALESCE(NEW.task_id, OLD.task_id)
                      AND deleted_at IS NULL
                      AND status NOT IN ('rejected');

                    -- Update task
                    UPDATE kanban_tasks
                    SET time_spent_minutes = v_total_minutes,
                        updated_at = NOW()
                    WHERE id = COALESCE(NEW.task_id, OLD.task_id);

                    RETURN COALESCE(NEW, OLD);
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_time_entries_task_update ON kanban_time_entries
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_time_entries_task_update
                AFTER INSERT OR UPDATE OR DELETE ON kanban_time_entries
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_task_time_spent()
            ]])
        end)
    end,

    -- ========================================
    -- [10] Add project budget tracking from time entries
    -- ========================================
    [10] = function()
        -- Trigger to update project budget_spent from time entries
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_project_budget_spent()
                RETURNS TRIGGER AS $$
                DECLARE
                    v_task_id INTEGER;
                    v_project_id INTEGER;
                    v_total_amount DECIMAL(15,2);
                BEGIN
                    v_task_id := COALESCE(NEW.task_id, OLD.task_id);

                    -- Get project_id from task
                    SELECT p.id INTO v_project_id
                    FROM kanban_projects p
                    INNER JOIN kanban_boards b ON b.project_id = p.id
                    INNER JOIN kanban_tasks t ON t.board_id = b.id
                    WHERE t.id = v_task_id;

                    IF v_project_id IS NULL THEN
                        RETURN COALESCE(NEW, OLD);
                    END IF;

                    -- Calculate total billed amount for the project
                    SELECT COALESCE(SUM(te.billed_amount), 0) INTO v_total_amount
                    FROM kanban_time_entries te
                    INNER JOIN kanban_tasks t ON t.id = te.task_id
                    INNER JOIN kanban_boards b ON b.id = t.board_id
                    WHERE b.project_id = v_project_id
                      AND te.deleted_at IS NULL
                      AND te.is_billable = true
                      AND te.status IN ('approved', 'invoiced');

                    -- Update project
                    UPDATE kanban_projects
                    SET budget_spent = v_total_amount,
                        updated_at = NOW()
                    WHERE id = v_project_id;

                    RETURN COALESCE(NEW, OLD);
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_time_entries_budget_update ON kanban_time_entries
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_time_entries_budget_update
                AFTER INSERT OR UPDATE OR DELETE ON kanban_time_entries
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_project_budget_spent()
            ]])
        end)
    end,

    -- ========================================
    -- [11] Create due date notification job support
    -- ========================================
    [11] = function()
        -- This creates a function that can be called by a cron job to generate due date notifications
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION generate_due_date_notifications()
                RETURNS INTEGER AS $$
                DECLARE
                    v_count INTEGER := 0;
                    v_task RECORD;
                    v_assignee RECORD;
                BEGIN
                    -- Tasks due tomorrow (that haven't been notified)
                    FOR v_task IN
                        SELECT t.*, p.name as project_name, p.namespace_id
                        FROM kanban_tasks t
                        INNER JOIN kanban_boards b ON b.id = t.board_id
                        INNER JOIN kanban_projects p ON p.id = b.project_id
                        WHERE t.due_date = CURRENT_DATE + INTERVAL '1 day'
                          AND t.status NOT IN ('completed', 'cancelled')
                          AND t.deleted_at IS NULL
                          AND t.archived_at IS NULL
                          AND NOT EXISTS (
                              SELECT 1 FROM kanban_notifications n
                              WHERE n.task_id = t.id
                                AND n.type = 'task_due_soon'
                                AND n.created_at > NOW() - INTERVAL '24 hours'
                          )
                    LOOP
                        -- Notify all assignees
                        FOR v_assignee IN
                            SELECT user_uuid FROM kanban_task_assignees
                            WHERE task_id = v_task.id AND deleted_at IS NULL
                        LOOP
                            INSERT INTO kanban_notifications (
                                uuid, namespace_id, recipient_user_uuid, type, title, message,
                                action_url, project_id, task_id, priority, created_at
                            ) VALUES (
                                gen_random_uuid()::text,
                                v_task.namespace_id,
                                v_assignee.user_uuid,
                                'task_due_soon',
                                'Task Due Tomorrow',
                                'Task "' || v_task.title || '" in project "' || v_task.project_name || '" is due tomorrow.',
                                '/projects/' || v_task.project_uuid || '/tasks/' || v_task.uuid,
                                (SELECT id FROM kanban_projects WHERE namespace_id = v_task.namespace_id LIMIT 1),
                                v_task.id,
                                'high',
                                NOW()
                            );
                            v_count := v_count + 1;
                        END LOOP;
                    END LOOP;

                    -- Overdue tasks
                    FOR v_task IN
                        SELECT t.*, p.name as project_name, p.namespace_id
                        FROM kanban_tasks t
                        INNER JOIN kanban_boards b ON b.id = t.board_id
                        INNER JOIN kanban_projects p ON p.id = b.project_id
                        WHERE t.due_date < CURRENT_DATE
                          AND t.status NOT IN ('completed', 'cancelled')
                          AND t.deleted_at IS NULL
                          AND t.archived_at IS NULL
                          AND NOT EXISTS (
                              SELECT 1 FROM kanban_notifications n
                              WHERE n.task_id = t.id
                                AND n.type = 'task_overdue'
                                AND n.created_at > NOW() - INTERVAL '24 hours'
                          )
                    LOOP
                        FOR v_assignee IN
                            SELECT user_uuid FROM kanban_task_assignees
                            WHERE task_id = v_task.id AND deleted_at IS NULL
                        LOOP
                            INSERT INTO kanban_notifications (
                                uuid, namespace_id, recipient_user_uuid, type, title, message,
                                action_url, project_id, task_id, priority, created_at
                            ) VALUES (
                                gen_random_uuid()::text,
                                v_task.namespace_id,
                                v_assignee.user_uuid,
                                'task_overdue',
                                'Task Overdue',
                                'Task "' || v_task.title || '" in project "' || v_task.project_name || '" is overdue!',
                                '/projects/' || v_task.project_uuid || '/tasks/' || v_task.uuid,
                                (SELECT id FROM kanban_projects WHERE namespace_id = v_task.namespace_id LIMIT 1),
                                v_task.id,
                                'urgent',
                                NOW()
                            );
                            v_count := v_count + 1;
                        END LOOP;
                    END LOOP;

                    RETURN v_count;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)
    end,

    -- ========================================
    -- [12] Add models for new tables
    -- ========================================
    [12] = function()
        -- This migration step is a placeholder
        -- The actual model files are created separately in lapis/models/
        -- Models created: KanbanTimeEntryModel, KanbanNotificationModel,
        -- KanbanNotificationPreferenceModel, KanbanSprintBurndownModel
        print("[Migration] Kanban enhancements migration completed.")
    end,

    -- ========================================
    -- [13] Fix nullable FK columns with DEFAULT 0
    -- ========================================
    [13] = function()
        -- Fix nullable FK columns that incorrectly have DEFAULT 0
        -- This causes FK constraint violations when inserting without providing a value
        -- because 0 is used as the default, but 0 doesn't exist in the referenced table

        local columns_to_fix = {
            { table = "kanban_task_comments", column = "parent_comment_id" },
            { table = "kanban_notification_preferences", column = "project_id" },
            { table = "kanban_notifications", column = "comment_id" },
            { table = "kanban_notifications", column = "project_id" },
            { table = "kanban_notifications", column = "task_id" },
            { table = "kanban_sprints", column = "board_id" },
            { table = "kanban_task_activities", column = "entity_id" },
        }

        for _, fix in ipairs(columns_to_fix) do
            pcall(function()
                db.query(string.format(
                    "ALTER TABLE %s ALTER COLUMN %s DROP DEFAULT",
                    fix.table, fix.column
                ))
            end)
        end

        print("[Migration] Fixed nullable FK columns with DEFAULT 0")
    end
}
