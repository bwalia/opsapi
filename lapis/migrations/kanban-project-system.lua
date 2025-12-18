--[[
    Kanban Project Management System Migrations
    ============================================

    A comprehensive project management system with Kanban boards integrated with
    the chat module. Projects are namespace-scoped for multi-tenant support.

    Production-Ready Features:
    ==========================
    - Budget tracking with currency support
    - Soft deletes (deleted_at) on all tables
    - BRIN indexes for time-series data (millions of records)
    - Partial indexes for active records
    - Table partitioning ready
    - Composite indexes for common queries
    - Proper foreign key constraints with ON DELETE CASCADE

    Architecture:
    =============
    - Projects belong to a namespace (multi-tenant isolation)
    - Each project can have multiple boards (e.g., Sprint 1, Sprint 2)
    - Each board has columns (e.g., Backlog, To Do, In Progress, Done)
    - Tasks belong to a board and are placed in columns
    - Tasks can be assigned to users
    - When a task is assigned, a chat channel is auto-created for project discussion

    Tables:
    =======
    1. kanban_projects          - Projects (namespace-scoped) with budget tracking
    2. kanban_project_members   - Project team members with roles
    3. kanban_boards            - Boards within projects
    4. kanban_columns           - Columns within boards
    5. kanban_tasks             - Tasks/cards within columns
    6. kanban_task_assignees    - Task assignees (many-to-many)
    7. kanban_task_labels       - Labels for categorizing tasks
    8. kanban_task_label_links  - Task-label associations
    9. kanban_task_comments     - Comments on tasks
    10. kanban_task_attachments - File attachments on tasks
    11. kanban_task_checklists  - Checklists within tasks
    12. kanban_checklist_items  - Items within checklists
    13. kanban_task_activities  - Activity log for tasks
    14. kanban_sprints          - Sprint management (optional)
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

-- Helper to check if constraint exists
local function constraint_exists(constraint_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM pg_constraint
            WHERE conname = ?
        ) as exists
    ]], constraint_name)
    return result[1] and result[1].exists
end

-- Helper to check if trigger exists
local function trigger_exists(trigger_name, table_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM pg_trigger
            WHERE tgname = ? AND tgrelid = ?::regclass
        ) as exists
    ]], trigger_name, table_name)
    return result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create kanban_projects table
    -- ========================================
    [1] = function()
        if table_exists("kanban_projects") then return end

        schema.create_table("kanban_projects", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "name", types.varchar },
            { "slug", types.varchar },
            { "description", types.text({ null = true }) },
            { "status", types.varchar({ default = "'active'" }) },
            { "visibility", types.varchar({ default = "'private'" }) },
            { "color", types.varchar({ null = true }) },
            { "icon", types.varchar({ null = true }) },
            { "cover_image_url", types.varchar({ null = true }) },
            -- Budget tracking
            { "budget", "DECIMAL(15,2) DEFAULT 0" },
            { "budget_spent", "DECIMAL(15,2) DEFAULT 0" },
            { "budget_currency", types.varchar({ default = "'USD'" }) },
            { "hourly_rate", "DECIMAL(10,2) DEFAULT NULL" },
            -- Dates
            { "start_date", types.date({ null = true }) },
            { "due_date", types.date({ null = true }) },
            { "completed_at", types.time({ null = true }) },
            -- Ownership
            { "owner_user_uuid", types.varchar },
            { "chat_channel_uuid", types.varchar({ null = true }) },
            -- Settings and metadata (JSONB for better performance)
            { "settings", "JSONB DEFAULT '{}'" },
            { "metadata", "JSONB DEFAULT '{}'" },
            -- Denormalized counts for performance
            { "task_count", types.integer({ default = 0 }) },
            { "completed_task_count", types.integer({ default = 0 }) },
            { "member_count", types.integer({ default = 1 }) },
            -- Timestamps with soft delete
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "archived_at", types.time({ null = true }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to namespaces
        pcall(function()
            db.query([[
                ALTER TABLE kanban_projects
                ADD CONSTRAINT kanban_projects_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_projects
                ADD CONSTRAINT kanban_projects_status_check
                CHECK (status IN ('active', 'on_hold', 'completed', 'archived', 'cancelled'))
            ]])
        end)

        -- Visibility constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_projects
                ADD CONSTRAINT kanban_projects_visibility_check
                CHECK (visibility IN ('public', 'private', 'internal'))
            ]])
        end)

        -- Budget currency constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_projects
                ADD CONSTRAINT kanban_projects_currency_check
                CHECK (budget_currency IN ('USD', 'EUR', 'GBP', 'INR', 'CAD', 'AUD', 'JPY', 'CNY'))
            ]])
        end)

        -- Unique slug per namespace (only for non-deleted)
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX kanban_projects_namespace_slug_unique
                ON kanban_projects (namespace_id, slug)
                WHERE deleted_at IS NULL
            ]])
        end)
    end,

    -- ========================================
    -- [2] Add kanban_projects indexes (Production-optimized)
    -- ========================================
    [2] = function()
        -- Primary lookup indexes
        if not index_exists("idx_kanban_projects_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_projects_uuid ON kanban_projects (uuid)")
        end

        -- Namespace filtering (most common query)
        if not index_exists("idx_kanban_projects_namespace_active") then
            db.query([[
                CREATE INDEX idx_kanban_projects_namespace_active
                ON kanban_projects (namespace_id, status)
                WHERE deleted_at IS NULL
            ]])
        end

        -- Owner lookup
        if not index_exists("idx_kanban_projects_owner") then
            db.query([[
                CREATE INDEX idx_kanban_projects_owner
                ON kanban_projects (owner_user_uuid)
                WHERE deleted_at IS NULL
            ]])
        end

        -- Status filtering
        if not index_exists("idx_kanban_projects_status") then
            db.query([[
                CREATE INDEX idx_kanban_projects_status
                ON kanban_projects (status)
                WHERE deleted_at IS NULL
            ]])
        end

        -- Chat channel lookup
        if not index_exists("idx_kanban_projects_chat_channel") then
            db.query([[
                CREATE INDEX idx_kanban_projects_chat_channel
                ON kanban_projects (chat_channel_uuid)
                WHERE chat_channel_uuid IS NOT NULL
            ]])
        end

        -- BRIN index for time-series queries (efficient for millions of records)
        if not index_exists("idx_kanban_projects_created_brin") then
            pcall(function()
                db.query([[
                    CREATE INDEX idx_kanban_projects_created_brin
                    ON kanban_projects USING BRIN (created_at)
                ]])
            end)
        end

        -- Due date for deadline queries
        if not index_exists("idx_kanban_projects_due_date") then
            db.query([[
                CREATE INDEX idx_kanban_projects_due_date
                ON kanban_projects (due_date)
                WHERE due_date IS NOT NULL AND deleted_at IS NULL AND status != 'completed'
            ]])
        end
    end,

    -- ========================================
    -- [3] Create kanban_project_members table
    -- ========================================
    [3] = function()
        if table_exists("kanban_project_members") then return end

        schema.create_table("kanban_project_members", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "project_id", types.integer },
            { "user_uuid", types.varchar },
            { "role", types.varchar({ default = "'member'" }) },
            { "permissions", "JSONB DEFAULT '{}'" },
            { "joined_at", types.time({ default = db.raw("NOW()") }) },
            { "invited_by", types.varchar({ null = true }) },
            { "is_starred", types.boolean({ default = false }) },
            { "notification_preference", types.varchar({ default = "'all'" }) },
            { "last_accessed_at", types.time({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "left_at", types.time({ null = true }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_projects
        pcall(function()
            db.query([[
                ALTER TABLE kanban_project_members
                ADD CONSTRAINT kanban_project_members_project_fk
                FOREIGN KEY (project_id) REFERENCES kanban_projects(id) ON DELETE CASCADE
            ]])
        end)

        -- Role constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_project_members
                ADD CONSTRAINT kanban_project_members_role_check
                CHECK (role IN ('owner', 'admin', 'member', 'viewer', 'guest'))
            ]])
        end)

        -- Unique member per project (only for active members)
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX kanban_project_members_unique
                ON kanban_project_members (project_id, user_uuid)
                WHERE deleted_at IS NULL AND left_at IS NULL
            ]])
        end)
    end,

    -- ========================================
    -- [4] Add kanban_project_members indexes
    -- ========================================
    [4] = function()
        if not index_exists("idx_kanban_project_members_project_active") then
            db.query([[
                CREATE INDEX idx_kanban_project_members_project_active
                ON kanban_project_members (project_id, role)
                WHERE deleted_at IS NULL AND left_at IS NULL
            ]])
        end
        if not index_exists("idx_kanban_project_members_user_active") then
            db.query([[
                CREATE INDEX idx_kanban_project_members_user_active
                ON kanban_project_members (user_uuid)
                WHERE deleted_at IS NULL AND left_at IS NULL
            ]])
        end
        if not index_exists("idx_kanban_project_members_starred") then
            db.query([[
                CREATE INDEX idx_kanban_project_members_starred
                ON kanban_project_members (user_uuid, project_id)
                WHERE is_starred = true AND deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [5] Create kanban_boards table
    -- ========================================
    [5] = function()
        if table_exists("kanban_boards") then return end

        schema.create_table("kanban_boards", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "project_id", types.integer },
            { "name", types.varchar },
            { "description", types.text({ null = true }) },
            { "position", types.integer({ default = 0 }) },
            { "is_default", types.boolean({ default = false }) },
            { "settings", "JSONB DEFAULT '{}'" },
            { "wip_limit", types.integer({ null = true }) },
            { "column_count", types.integer({ default = 0 }) },
            { "task_count", types.integer({ default = 0 }) },
            { "created_by", types.varchar },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "archived_at", types.time({ null = true }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_projects
        pcall(function()
            db.query([[
                ALTER TABLE kanban_boards
                ADD CONSTRAINT kanban_boards_project_fk
                FOREIGN KEY (project_id) REFERENCES kanban_projects(id) ON DELETE CASCADE
            ]])
        end)
    end,

    -- ========================================
    -- [6] Add kanban_boards indexes
    -- ========================================
    [6] = function()
        if not index_exists("idx_kanban_boards_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_boards_uuid ON kanban_boards (uuid)")
        end
        if not index_exists("idx_kanban_boards_project_active") then
            db.query([[
                CREATE INDEX idx_kanban_boards_project_active
                ON kanban_boards (project_id, position)
                WHERE deleted_at IS NULL AND archived_at IS NULL
            ]])
        end
        if not index_exists("idx_kanban_boards_default") then
            db.query([[
                CREATE INDEX idx_kanban_boards_default
                ON kanban_boards (project_id)
                WHERE is_default = true AND deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [7] Create kanban_columns table
    -- ========================================
    [7] = function()
        if table_exists("kanban_columns") then return end

        schema.create_table("kanban_columns", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "board_id", types.integer },
            { "name", types.varchar },
            { "description", types.text({ null = true }) },
            { "position", types.integer({ default = 0 }) },
            { "color", types.varchar({ null = true }) },
            { "wip_limit", types.integer({ null = true }) },
            { "is_done_column", types.boolean({ default = false }) },
            { "auto_close_tasks", types.boolean({ default = false }) },
            { "task_count", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_boards
        pcall(function()
            db.query([[
                ALTER TABLE kanban_columns
                ADD CONSTRAINT kanban_columns_board_fk
                FOREIGN KEY (board_id) REFERENCES kanban_boards(id) ON DELETE CASCADE
            ]])
        end)
    end,

    -- ========================================
    -- [8] Add kanban_columns indexes
    -- ========================================
    [8] = function()
        if not index_exists("idx_kanban_columns_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_columns_uuid ON kanban_columns (uuid)")
        end
        if not index_exists("idx_kanban_columns_board_active") then
            db.query([[
                CREATE INDEX idx_kanban_columns_board_active
                ON kanban_columns (board_id, position)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [9] Create kanban_tasks table
    -- ========================================
    [9] = function()
        if table_exists("kanban_tasks") then return end

        schema.create_table("kanban_tasks", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "board_id", types.integer },
            { "column_id", types.integer },
            { "parent_task_id", types.integer({ null = true }) },
            { "task_number", types.integer },
            { "title", types.varchar },
            { "description", types.text({ null = true }) },
            { "status", types.varchar({ default = "'open'" }) },
            { "priority", types.varchar({ default = "'medium'" }) },
            { "position", types.integer({ default = 0 }) },
            -- Effort tracking
            { "story_points", types.integer({ null = true }) },
            { "time_estimate_minutes", types.integer({ null = true }) },
            { "time_spent_minutes", types.integer({ default = 0 }) },
            -- Budget tracking for task
            { "budget", "DECIMAL(12,2) DEFAULT NULL" },
            { "budget_spent", "DECIMAL(12,2) DEFAULT 0" },
            -- Dates
            { "start_date", types.date({ null = true }) },
            { "due_date", types.date({ null = true }) },
            { "completed_at", types.time({ null = true }) },
            -- Ownership
            { "reporter_user_uuid", types.varchar },
            { "chat_channel_uuid", types.varchar({ null = true }) },
            -- Display
            { "cover_image_url", types.varchar({ null = true }) },
            { "cover_color", types.varchar({ null = true }) },
            -- Metadata (JSONB for better performance)
            { "metadata", "JSONB DEFAULT '{}'" },
            -- Denormalized counts
            { "comment_count", types.integer({ default = 0 }) },
            { "attachment_count", types.integer({ default = 0 }) },
            { "subtask_count", types.integer({ default = 0 }) },
            { "completed_subtask_count", types.integer({ default = 0 }) },
            { "assignee_count", types.integer({ default = 0 }) },
            -- Timestamps with soft delete
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "archived_at", types.time({ null = true }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign keys
        pcall(function()
            db.query([[
                ALTER TABLE kanban_tasks
                ADD CONSTRAINT kanban_tasks_board_fk
                FOREIGN KEY (board_id) REFERENCES kanban_boards(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE kanban_tasks
                ADD CONSTRAINT kanban_tasks_column_fk
                FOREIGN KEY (column_id) REFERENCES kanban_columns(id) ON DELETE SET NULL
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE kanban_tasks
                ADD CONSTRAINT kanban_tasks_parent_fk
                FOREIGN KEY (parent_task_id) REFERENCES kanban_tasks(id) ON DELETE SET NULL
            ]])
        end)

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_tasks
                ADD CONSTRAINT kanban_tasks_status_check
                CHECK (status IN ('open', 'in_progress', 'blocked', 'review', 'completed', 'cancelled'))
            ]])
        end)

        -- Priority constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_tasks
                ADD CONSTRAINT kanban_tasks_priority_check
                CHECK (priority IN ('critical', 'high', 'medium', 'low', 'none'))
            ]])
        end)

        -- Unique task number per board
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX kanban_tasks_board_number_unique
                ON kanban_tasks (board_id, task_number)
            ]])
        end)
    end,

    -- ========================================
    -- [10] Add kanban_tasks indexes (Production-optimized for millions)
    -- ========================================
    [10] = function()
        -- Primary UUID lookup
        if not index_exists("idx_kanban_tasks_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_tasks_uuid ON kanban_tasks (uuid)")
        end

        -- Board listing (most common query) - composite for column ordering
        if not index_exists("idx_kanban_tasks_board_column_pos") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_board_column_pos
                ON kanban_tasks (board_id, column_id, position)
                WHERE deleted_at IS NULL AND archived_at IS NULL
            ]])
        end

        -- Column task count
        if not index_exists("idx_kanban_tasks_column_active") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_column_active
                ON kanban_tasks (column_id)
                WHERE deleted_at IS NULL AND archived_at IS NULL
            ]])
        end

        -- Status filtering
        if not index_exists("idx_kanban_tasks_status_active") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_status_active
                ON kanban_tasks (board_id, status)
                WHERE deleted_at IS NULL
            ]])
        end

        -- Priority filtering
        if not index_exists("idx_kanban_tasks_priority") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_priority
                ON kanban_tasks (priority)
                WHERE deleted_at IS NULL AND status NOT IN ('completed', 'cancelled')
            ]])
        end

        -- Due date for deadline queries (critical for production)
        if not index_exists("idx_kanban_tasks_due_date_active") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_due_date_active
                ON kanban_tasks (due_date)
                WHERE due_date IS NOT NULL AND deleted_at IS NULL AND status NOT IN ('completed', 'cancelled')
            ]])
        end

        -- Reporter lookup
        if not index_exists("idx_kanban_tasks_reporter") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_reporter
                ON kanban_tasks (reporter_user_uuid)
                WHERE deleted_at IS NULL
            ]])
        end

        -- Parent task (subtasks)
        if not index_exists("idx_kanban_tasks_parent") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_parent
                ON kanban_tasks (parent_task_id)
                WHERE parent_task_id IS NOT NULL AND deleted_at IS NULL
            ]])
        end

        -- Chat channel lookup
        if not index_exists("idx_kanban_tasks_chat_channel") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_chat_channel
                ON kanban_tasks (chat_channel_uuid)
                WHERE chat_channel_uuid IS NOT NULL
            ]])
        end

        -- BRIN index for time-series (very efficient for millions of rows)
        if not index_exists("idx_kanban_tasks_created_brin") then
            pcall(function()
                db.query([[
                    CREATE INDEX idx_kanban_tasks_created_brin
                    ON kanban_tasks USING BRIN (created_at)
                ]])
            end)
        end
    end,

    -- ========================================
    -- [11] Create kanban_task_assignees table
    -- ========================================
    [11] = function()
        if table_exists("kanban_task_assignees") then return end

        schema.create_table("kanban_task_assignees", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "task_id", types.integer },
            { "user_uuid", types.varchar },
            { "assigned_by", types.varchar },
            { "assigned_at", types.time({ default = db.raw("NOW()") }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_tasks
        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_assignees
                ADD CONSTRAINT kanban_task_assignees_task_fk
                FOREIGN KEY (task_id) REFERENCES kanban_tasks(id) ON DELETE CASCADE
            ]])
        end)

        -- Unique assignee per task (only for active assignments)
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX kanban_task_assignees_unique
                ON kanban_task_assignees (task_id, user_uuid)
                WHERE deleted_at IS NULL
            ]])
        end)
    end,

    -- ========================================
    -- [12] Add kanban_task_assignees indexes
    -- ========================================
    [12] = function()
        if not index_exists("idx_kanban_task_assignees_task_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_assignees_task_active
                ON kanban_task_assignees (task_id)
                WHERE deleted_at IS NULL
            ]])
        end
        -- User's assigned tasks (critical for "My Tasks" view)
        if not index_exists("idx_kanban_task_assignees_user_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_assignees_user_active
                ON kanban_task_assignees (user_uuid, task_id)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [13] Create kanban_task_labels table
    -- ========================================
    [13] = function()
        if table_exists("kanban_task_labels") then return end

        schema.create_table("kanban_task_labels", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "project_id", types.integer },
            { "name", types.varchar },
            { "color", types.varchar({ default = "'#6B7280'" }) },
            { "description", types.text({ null = true }) },
            { "usage_count", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_projects
        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_labels
                ADD CONSTRAINT kanban_task_labels_project_fk
                FOREIGN KEY (project_id) REFERENCES kanban_projects(id) ON DELETE CASCADE
            ]])
        end)

        -- Unique label name per project (only for active labels)
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX kanban_task_labels_unique
                ON kanban_task_labels (project_id, name)
                WHERE deleted_at IS NULL
            ]])
        end)
    end,

    -- ========================================
    -- [14] Add kanban_task_labels indexes
    -- ========================================
    [14] = function()
        if not index_exists("idx_kanban_task_labels_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_task_labels_uuid ON kanban_task_labels (uuid)")
        end
        if not index_exists("idx_kanban_task_labels_project_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_labels_project_active
                ON kanban_task_labels (project_id)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [15] Create kanban_task_label_links table
    -- ========================================
    [15] = function()
        if table_exists("kanban_task_label_links") then return end

        schema.create_table("kanban_task_label_links", {
            { "id", types.serial },
            { "task_id", types.integer },
            { "label_id", types.integer },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign keys
        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_label_links
                ADD CONSTRAINT kanban_task_label_links_task_fk
                FOREIGN KEY (task_id) REFERENCES kanban_tasks(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_label_links
                ADD CONSTRAINT kanban_task_label_links_label_fk
                FOREIGN KEY (label_id) REFERENCES kanban_task_labels(id) ON DELETE CASCADE
            ]])
        end)

        -- Unique link (only for active links)
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX kanban_task_label_links_unique
                ON kanban_task_label_links (task_id, label_id)
                WHERE deleted_at IS NULL
            ]])
        end)
    end,

    -- ========================================
    -- [16] Add kanban_task_label_links indexes
    -- ========================================
    [16] = function()
        if not index_exists("idx_kanban_task_label_links_task_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_label_links_task_active
                ON kanban_task_label_links (task_id)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_kanban_task_label_links_label_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_label_links_label_active
                ON kanban_task_label_links (label_id)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [17] Create kanban_task_comments table
    -- ========================================
    [17] = function()
        if table_exists("kanban_task_comments") then return end

        schema.create_table("kanban_task_comments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "task_id", types.integer },
            { "parent_comment_id", types.integer({ null = true }) },
            { "user_uuid", types.varchar },
            { "content", types.text },
            { "is_edited", types.boolean({ default = false }) },
            { "edited_at", types.time({ null = true }) },
            { "reaction_count", types.integer({ default = 0 }) },
            { "reply_count", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign keys
        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_comments
                ADD CONSTRAINT kanban_task_comments_task_fk
                FOREIGN KEY (task_id) REFERENCES kanban_tasks(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_comments
                ADD CONSTRAINT kanban_task_comments_parent_fk
                FOREIGN KEY (parent_comment_id) REFERENCES kanban_task_comments(id) ON DELETE CASCADE
            ]])
        end)
    end,

    -- ========================================
    -- [18] Add kanban_task_comments indexes
    -- ========================================
    [18] = function()
        if not index_exists("idx_kanban_task_comments_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_task_comments_uuid ON kanban_task_comments (uuid)")
        end
        -- Task comments listing (most common query)
        if not index_exists("idx_kanban_task_comments_task_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_comments_task_active
                ON kanban_task_comments (task_id, created_at DESC)
                WHERE deleted_at IS NULL AND parent_comment_id IS NULL
            ]])
        end
        -- Replies
        if not index_exists("idx_kanban_task_comments_parent_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_comments_parent_active
                ON kanban_task_comments (parent_comment_id, created_at ASC)
                WHERE deleted_at IS NULL AND parent_comment_id IS NOT NULL
            ]])
        end
        -- User's comments
        if not index_exists("idx_kanban_task_comments_user") then
            db.query([[
                CREATE INDEX idx_kanban_task_comments_user
                ON kanban_task_comments (user_uuid)
                WHERE deleted_at IS NULL
            ]])
        end
        -- BRIN for time-series
        if not index_exists("idx_kanban_task_comments_created_brin") then
            pcall(function()
                db.query([[
                    CREATE INDEX idx_kanban_task_comments_created_brin
                    ON kanban_task_comments USING BRIN (created_at)
                ]])
            end)
        end
    end,

    -- ========================================
    -- [19] Create kanban_task_attachments table
    -- ========================================
    [19] = function()
        if table_exists("kanban_task_attachments") then return end

        schema.create_table("kanban_task_attachments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "task_id", types.integer },
            { "uploaded_by", types.varchar },
            { "file_name", types.varchar },
            { "file_url", types.text },
            { "file_type", types.varchar({ null = true }) },
            { "file_size", "BIGINT DEFAULT NULL" },
            { "thumbnail_url", types.text({ null = true }) },
            { "metadata", "JSONB DEFAULT '{}'" },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_tasks
        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_attachments
                ADD CONSTRAINT kanban_task_attachments_task_fk
                FOREIGN KEY (task_id) REFERENCES kanban_tasks(id) ON DELETE CASCADE
            ]])
        end)
    end,

    -- ========================================
    -- [20] Add kanban_task_attachments indexes
    -- ========================================
    [20] = function()
        if not index_exists("idx_kanban_task_attachments_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_task_attachments_uuid ON kanban_task_attachments (uuid)")
        end
        if not index_exists("idx_kanban_task_attachments_task_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_attachments_task_active
                ON kanban_task_attachments (task_id, created_at DESC)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [21] Create kanban_task_checklists table
    -- ========================================
    [21] = function()
        if table_exists("kanban_task_checklists") then return end

        schema.create_table("kanban_task_checklists", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "task_id", types.integer },
            { "name", types.varchar },
            { "position", types.integer({ default = 0 }) },
            { "item_count", types.integer({ default = 0 }) },
            { "completed_item_count", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_tasks
        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_checklists
                ADD CONSTRAINT kanban_task_checklists_task_fk
                FOREIGN KEY (task_id) REFERENCES kanban_tasks(id) ON DELETE CASCADE
            ]])
        end)
    end,

    -- ========================================
    -- [22] Add kanban_task_checklists indexes
    -- ========================================
    [22] = function()
        if not index_exists("idx_kanban_task_checklists_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_task_checklists_uuid ON kanban_task_checklists (uuid)")
        end
        if not index_exists("idx_kanban_task_checklists_task_active") then
            db.query([[
                CREATE INDEX idx_kanban_task_checklists_task_active
                ON kanban_task_checklists (task_id, position)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [23] Create kanban_checklist_items table
    -- ========================================
    [23] = function()
        if table_exists("kanban_checklist_items") then return end

        schema.create_table("kanban_checklist_items", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "checklist_id", types.integer },
            { "content", types.varchar },
            { "is_completed", types.boolean({ default = false }) },
            { "completed_at", types.time({ null = true }) },
            { "completed_by", types.varchar({ null = true }) },
            { "assignee_user_uuid", types.varchar({ null = true }) },
            { "due_date", types.date({ null = true }) },
            { "position", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_task_checklists
        pcall(function()
            db.query([[
                ALTER TABLE kanban_checklist_items
                ADD CONSTRAINT kanban_checklist_items_checklist_fk
                FOREIGN KEY (checklist_id) REFERENCES kanban_task_checklists(id) ON DELETE CASCADE
            ]])
        end)
    end,

    -- ========================================
    -- [24] Add kanban_checklist_items indexes
    -- ========================================
    [24] = function()
        if not index_exists("idx_kanban_checklist_items_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_checklist_items_uuid ON kanban_checklist_items (uuid)")
        end
        if not index_exists("idx_kanban_checklist_items_checklist_active") then
            db.query([[
                CREATE INDEX idx_kanban_checklist_items_checklist_active
                ON kanban_checklist_items (checklist_id, position)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_kanban_checklist_items_assignee") then
            db.query([[
                CREATE INDEX idx_kanban_checklist_items_assignee
                ON kanban_checklist_items (assignee_user_uuid)
                WHERE deleted_at IS NULL AND assignee_user_uuid IS NOT NULL
            ]])
        end
    end,

    -- ========================================
    -- [25] Create kanban_task_activities table
    -- ========================================
    [25] = function()
        if table_exists("kanban_task_activities") then return end

        schema.create_table("kanban_task_activities", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "task_id", types.integer },
            { "user_uuid", types.varchar },
            { "action", types.varchar },
            { "entity_type", types.varchar({ null = true }) },
            { "entity_id", types.integer({ null = true }) },
            { "old_value", types.text({ null = true }) },
            { "new_value", types.text({ null = true }) },
            { "metadata", "JSONB DEFAULT '{}'" },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign key to kanban_tasks
        pcall(function()
            db.query([[
                ALTER TABLE kanban_task_activities
                ADD CONSTRAINT kanban_task_activities_task_fk
                FOREIGN KEY (task_id) REFERENCES kanban_tasks(id) ON DELETE CASCADE
            ]])
        end)
    end,

    -- ========================================
    -- [26] Add kanban_task_activities indexes
    -- ========================================
    [26] = function()
        if not index_exists("idx_kanban_task_activities_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_task_activities_uuid ON kanban_task_activities (uuid)")
        end
        -- Task activity listing
        if not index_exists("idx_kanban_task_activities_task_created") then
            db.query([[
                CREATE INDEX idx_kanban_task_activities_task_created
                ON kanban_task_activities (task_id, created_at DESC)
            ]])
        end
        -- User's activities
        if not index_exists("idx_kanban_task_activities_user") then
            db.query("CREATE INDEX idx_kanban_task_activities_user ON kanban_task_activities (user_uuid)")
        end
        -- Action type filtering
        if not index_exists("idx_kanban_task_activities_action") then
            db.query("CREATE INDEX idx_kanban_task_activities_action ON kanban_task_activities (action)")
        end
        -- BRIN for time-series (very efficient for audit logs)
        if not index_exists("idx_kanban_task_activities_created_brin") then
            pcall(function()
                db.query([[
                    CREATE INDEX idx_kanban_task_activities_created_brin
                    ON kanban_task_activities USING BRIN (created_at)
                ]])
            end)
        end
    end,

    -- ========================================
    -- [27] Create kanban_sprints table
    -- ========================================
    [27] = function()
        if table_exists("kanban_sprints") then return end

        schema.create_table("kanban_sprints", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "project_id", types.integer },
            { "board_id", types.integer({ null = true }) },
            { "name", types.varchar },
            { "goal", types.text({ null = true }) },
            { "status", types.varchar({ default = "'planned'" }) },
            { "start_date", types.date({ null = true }) },
            { "end_date", types.date({ null = true }) },
            { "completed_at", types.time({ null = true }) },
            { "total_points", types.integer({ default = 0 }) },
            { "completed_points", types.integer({ default = 0 }) },
            { "task_count", types.integer({ default = 0 }) },
            { "completed_task_count", types.integer({ default = 0 }) },
            { "created_by", types.varchar },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Foreign keys
        pcall(function()
            db.query([[
                ALTER TABLE kanban_sprints
                ADD CONSTRAINT kanban_sprints_project_fk
                FOREIGN KEY (project_id) REFERENCES kanban_projects(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE kanban_sprints
                ADD CONSTRAINT kanban_sprints_board_fk
                FOREIGN KEY (board_id) REFERENCES kanban_boards(id) ON DELETE SET NULL
            ]])
        end)

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE kanban_sprints
                ADD CONSTRAINT kanban_sprints_status_check
                CHECK (status IN ('planned', 'active', 'completed', 'cancelled'))
            ]])
        end)
    end,

    -- ========================================
    -- [28] Add kanban_sprints indexes
    -- ========================================
    [28] = function()
        if not index_exists("idx_kanban_sprints_uuid") then
            db.query("CREATE UNIQUE INDEX idx_kanban_sprints_uuid ON kanban_sprints (uuid)")
        end
        if not index_exists("idx_kanban_sprints_project_active") then
            db.query([[
                CREATE INDEX idx_kanban_sprints_project_active
                ON kanban_sprints (project_id, status)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_kanban_sprints_board") then
            db.query([[
                CREATE INDEX idx_kanban_sprints_board
                ON kanban_sprints (board_id)
                WHERE deleted_at IS NULL AND board_id IS NOT NULL
            ]])
        end
        if not index_exists("idx_kanban_sprints_dates") then
            db.query([[
                CREATE INDEX idx_kanban_sprints_dates
                ON kanban_sprints (start_date, end_date)
                WHERE deleted_at IS NULL AND status = 'active'
            ]])
        end
    end,

    -- ========================================
    -- [29] Add sprint_id to kanban_tasks
    -- ========================================
    [29] = function()
        if column_exists("kanban_tasks", "sprint_id") then return end

        schema.add_column("kanban_tasks", "sprint_id", types.integer({ null = true }))

        pcall(function()
            db.query([[
                ALTER TABLE kanban_tasks
                ADD CONSTRAINT kanban_tasks_sprint_fk
                FOREIGN KEY (sprint_id) REFERENCES kanban_sprints(id) ON DELETE SET NULL
            ]])
        end)

        if not index_exists("idx_kanban_tasks_sprint_active") then
            db.query([[
                CREATE INDEX idx_kanban_tasks_sprint_active
                ON kanban_tasks (sprint_id)
                WHERE sprint_id IS NOT NULL AND deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================
    -- [30] Create triggers for task/column counts
    -- ========================================
    [30] = function()
        -- Trigger to update column task count
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_column_task_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL AND NEW.archived_at IS NULL THEN
                            UPDATE kanban_columns
                            SET task_count = task_count + 1
                            WHERE id = NEW.column_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL AND OLD.archived_at IS NULL THEN
                            UPDATE kanban_columns
                            SET task_count = GREATEST(0, task_count - 1)
                            WHERE id = OLD.column_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        -- Handle column change
                        IF OLD.column_id IS DISTINCT FROM NEW.column_id THEN
                            IF OLD.deleted_at IS NULL AND OLD.archived_at IS NULL THEN
                                UPDATE kanban_columns
                                SET task_count = GREATEST(0, task_count - 1)
                                WHERE id = OLD.column_id;
                            END IF;
                            IF NEW.deleted_at IS NULL AND NEW.archived_at IS NULL THEN
                                UPDATE kanban_columns
                                SET task_count = task_count + 1
                                WHERE id = NEW.column_id;
                            END IF;
                        -- Handle soft delete/restore
                        ELSIF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) OR
                              (OLD.archived_at IS NULL) != (NEW.archived_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL AND NEW.archived_at IS NULL THEN
                                -- Task restored
                                UPDATE kanban_columns
                                SET task_count = task_count + 1
                                WHERE id = NEW.column_id;
                            ELSE
                                -- Task deleted/archived
                                UPDATE kanban_columns
                                SET task_count = GREATEST(0, task_count - 1)
                                WHERE id = NEW.column_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_tasks_column_count_trigger ON kanban_tasks
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_tasks_column_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_tasks
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_column_task_count()
            ]])
        end)

        -- Trigger to update project task count
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_project_task_count()
                RETURNS TRIGGER AS $$
                DECLARE
                    v_project_id INTEGER;
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        SELECT kp.id INTO v_project_id
                        FROM kanban_boards kb
                        JOIN kanban_projects kp ON kp.id = kb.project_id
                        WHERE kb.id = NEW.board_id;

                        IF NEW.deleted_at IS NULL THEN
                            UPDATE kanban_projects
                            SET task_count = task_count + 1,
                                completed_task_count = completed_task_count + (CASE WHEN NEW.status = 'completed' THEN 1 ELSE 0 END),
                                updated_at = NOW()
                            WHERE id = v_project_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        SELECT kp.id INTO v_project_id
                        FROM kanban_boards kb
                        JOIN kanban_projects kp ON kp.id = kb.project_id
                        WHERE kb.id = OLD.board_id;

                        IF OLD.deleted_at IS NULL THEN
                            UPDATE kanban_projects
                            SET task_count = GREATEST(0, task_count - 1),
                                completed_task_count = GREATEST(0, completed_task_count - (CASE WHEN OLD.status = 'completed' THEN 1 ELSE 0 END)),
                                updated_at = NOW()
                            WHERE id = v_project_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        SELECT kp.id INTO v_project_id
                        FROM kanban_boards kb
                        JOIN kanban_projects kp ON kp.id = kb.project_id
                        WHERE kb.id = NEW.board_id;

                        -- Handle soft delete
                        IF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL THEN
                                -- Task restored
                                UPDATE kanban_projects
                                SET task_count = task_count + 1,
                                    completed_task_count = completed_task_count + (CASE WHEN NEW.status = 'completed' THEN 1 ELSE 0 END),
                                    updated_at = NOW()
                                WHERE id = v_project_id;
                            ELSE
                                -- Task deleted
                                UPDATE kanban_projects
                                SET task_count = GREATEST(0, task_count - 1),
                                    completed_task_count = GREATEST(0, completed_task_count - (CASE WHEN OLD.status = 'completed' THEN 1 ELSE 0 END)),
                                    updated_at = NOW()
                                WHERE id = v_project_id;
                            END IF;
                        -- Handle status change
                        ELSIF OLD.status IS DISTINCT FROM NEW.status AND NEW.deleted_at IS NULL THEN
                            IF NEW.status = 'completed' AND OLD.status != 'completed' THEN
                                UPDATE kanban_projects
                                SET completed_task_count = completed_task_count + 1,
                                    updated_at = NOW()
                                WHERE id = v_project_id;
                            ELSIF OLD.status = 'completed' AND NEW.status != 'completed' THEN
                                UPDATE kanban_projects
                                SET completed_task_count = GREATEST(0, completed_task_count - 1),
                                    updated_at = NOW()
                                WHERE id = v_project_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_tasks_project_count_trigger ON kanban_tasks
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_tasks_project_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_tasks
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_project_task_count()
            ]])
        end)
    end,

    -- ========================================
    -- [31] Create triggers for comment count
    -- ========================================
    [31] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_task_comment_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL THEN
                            UPDATE kanban_tasks
                            SET comment_count = comment_count + 1,
                                updated_at = NOW()
                            WHERE id = NEW.task_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL THEN
                            UPDATE kanban_tasks
                            SET comment_count = GREATEST(0, comment_count - 1),
                                updated_at = NOW()
                            WHERE id = OLD.task_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        IF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL THEN
                                UPDATE kanban_tasks
                                SET comment_count = comment_count + 1,
                                    updated_at = NOW()
                                WHERE id = NEW.task_id;
                            ELSE
                                UPDATE kanban_tasks
                                SET comment_count = GREATEST(0, comment_count - 1),
                                    updated_at = NOW()
                                WHERE id = NEW.task_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_comments_count_trigger ON kanban_task_comments
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_comments_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_task_comments
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_task_comment_count()
            ]])
        end)
    end,

    -- ========================================
    -- [32] Create triggers for checklist counts
    -- ========================================
    [32] = function()
        -- Update checklist item counts
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_checklist_item_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL THEN
                            UPDATE kanban_task_checklists
                            SET item_count = item_count + 1,
                                completed_item_count = completed_item_count + (CASE WHEN NEW.is_completed THEN 1 ELSE 0 END),
                                updated_at = NOW()
                            WHERE id = NEW.checklist_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL THEN
                            UPDATE kanban_task_checklists
                            SET item_count = GREATEST(0, item_count - 1),
                                completed_item_count = GREATEST(0, completed_item_count - (CASE WHEN OLD.is_completed THEN 1 ELSE 0 END)),
                                updated_at = NOW()
                            WHERE id = OLD.checklist_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        -- Handle soft delete
                        IF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL THEN
                                UPDATE kanban_task_checklists
                                SET item_count = item_count + 1,
                                    completed_item_count = completed_item_count + (CASE WHEN NEW.is_completed THEN 1 ELSE 0 END),
                                    updated_at = NOW()
                                WHERE id = NEW.checklist_id;
                            ELSE
                                UPDATE kanban_task_checklists
                                SET item_count = GREATEST(0, item_count - 1),
                                    completed_item_count = GREATEST(0, completed_item_count - (CASE WHEN OLD.is_completed THEN 1 ELSE 0 END)),
                                    updated_at = NOW()
                                WHERE id = NEW.checklist_id;
                            END IF;
                        -- Handle completion toggle
                        ELSIF OLD.is_completed != NEW.is_completed AND NEW.deleted_at IS NULL THEN
                            UPDATE kanban_task_checklists
                            SET completed_item_count = completed_item_count + (CASE WHEN NEW.is_completed THEN 1 ELSE -1 END),
                                updated_at = NOW()
                            WHERE id = NEW.checklist_id;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_checklist_items_count_trigger ON kanban_checklist_items
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_checklist_items_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_checklist_items
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_checklist_item_count()
            ]])
        end)
    end,

    -- ========================================
    -- [33] Create full-text search for tasks
    -- ========================================
    [33] = function()
        if column_exists("kanban_tasks", "search_vector") then return end

        pcall(function()
            schema.add_column("kanban_tasks", "search_vector", "tsvector")
        end)

        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_task_search_vector()
                RETURNS TRIGGER AS $$
                BEGIN
                    NEW.search_vector := to_tsvector('english',
                        COALESCE(NEW.title, '') || ' ' ||
                        COALESCE(NEW.description, '') || ' ' ||
                        COALESCE(NEW.task_number::text, '')
                    );
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_tasks_search_trigger ON kanban_tasks
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_tasks_search_trigger
                BEFORE INSERT OR UPDATE OF title, description ON kanban_tasks
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_task_search_vector()
            ]])
        end)

        -- Create GIN index for search
        if not index_exists("idx_kanban_tasks_search") then
            pcall(function()
                db.query([[
                    CREATE INDEX idx_kanban_tasks_search ON kanban_tasks USING GIN(search_vector)
                    WHERE deleted_at IS NULL
                ]])
            end)
        end

        -- Update existing rows
        pcall(function()
            db.query([[
                UPDATE kanban_tasks SET search_vector = to_tsvector('english',
                    COALESCE(title, '') || ' ' ||
                    COALESCE(description, '') || ' ' ||
                    COALESCE(task_number::text, '')
                )
            ]])
        end)
    end,

    -- ========================================
    -- [34] Add kanban permissions to modules
    -- ========================================
    [34] = function()
        -- Check if kanban module exists
        local result = db.query([[
            SELECT id FROM modules WHERE machine_name = 'kanban'
        ]])

        if not result or #result == 0 then
            -- Generate UUID without ngx dependency (for migration context)
            local function generate_uuid()
                local random = math.random
                local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
                math.randomseed(os.time() + os.clock() * 1000000)
                return string.gsub(template, '[xy]', function(c)
                    local v = (c == 'x') and random(0, 15) or random(8, 11)
                    return string.format('%x', v)
                end)
            end

            db.query([[
                INSERT INTO modules (uuid, machine_name, name, description, priority, created_at, updated_at)
                VALUES (
                    ?,
                    'kanban',
                    'Kanban Projects',
                    'Project management with Kanban boards, tasks, budget tracking, and team collaboration',
                    '100',
                    NOW(),
                    NOW()
                )
            ]], generate_uuid())
        end
    end,

    -- ========================================
    -- [35] Create assignee count trigger
    -- ========================================
    [35] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_task_assignee_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL THEN
                            UPDATE kanban_tasks
                            SET assignee_count = assignee_count + 1,
                                updated_at = NOW()
                            WHERE id = NEW.task_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL THEN
                            UPDATE kanban_tasks
                            SET assignee_count = GREATEST(0, assignee_count - 1),
                                updated_at = NOW()
                            WHERE id = OLD.task_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        IF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL THEN
                                UPDATE kanban_tasks
                                SET assignee_count = assignee_count + 1,
                                    updated_at = NOW()
                                WHERE id = NEW.task_id;
                            ELSE
                                UPDATE kanban_tasks
                                SET assignee_count = GREATEST(0, assignee_count - 1),
                                    updated_at = NOW()
                                WHERE id = NEW.task_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_task_assignees_count_trigger ON kanban_task_assignees
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_task_assignees_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_task_assignees
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_task_assignee_count()
            ]])
        end)
    end,

    -- ========================================
    -- [36] Create member count trigger for projects
    -- ========================================
    [36] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_project_member_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL AND NEW.left_at IS NULL THEN
                            UPDATE kanban_projects
                            SET member_count = member_count + 1,
                                updated_at = NOW()
                            WHERE id = NEW.project_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL AND OLD.left_at IS NULL THEN
                            UPDATE kanban_projects
                            SET member_count = GREATEST(1, member_count - 1),
                                updated_at = NOW()
                            WHERE id = OLD.project_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        -- Handle member leaving/rejoining
                        IF (OLD.deleted_at IS NULL AND OLD.left_at IS NULL) !=
                           (NEW.deleted_at IS NULL AND NEW.left_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL AND NEW.left_at IS NULL THEN
                                UPDATE kanban_projects
                                SET member_count = member_count + 1,
                                    updated_at = NOW()
                                WHERE id = NEW.project_id;
                            ELSE
                                UPDATE kanban_projects
                                SET member_count = GREATEST(1, member_count - 1),
                                    updated_at = NOW()
                                WHERE id = NEW.project_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_project_members_count_trigger ON kanban_project_members
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_project_members_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_project_members
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_project_member_count()
            ]])
        end)
    end,

    -- ========================================
    -- [37] Create attachment count trigger
    -- ========================================
    [37] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_task_attachment_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL THEN
                            UPDATE kanban_tasks
                            SET attachment_count = attachment_count + 1,
                                updated_at = NOW()
                            WHERE id = NEW.task_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL THEN
                            UPDATE kanban_tasks
                            SET attachment_count = GREATEST(0, attachment_count - 1),
                                updated_at = NOW()
                            WHERE id = OLD.task_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        IF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL THEN
                                UPDATE kanban_tasks
                                SET attachment_count = attachment_count + 1,
                                    updated_at = NOW()
                                WHERE id = NEW.task_id;
                            ELSE
                                UPDATE kanban_tasks
                                SET attachment_count = GREATEST(0, attachment_count - 1),
                                    updated_at = NOW()
                                WHERE id = NEW.task_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_task_attachments_count_trigger ON kanban_task_attachments
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_task_attachments_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_task_attachments
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_task_attachment_count()
            ]])
        end)
    end,

    -- ========================================
    -- [38] Create label usage count trigger
    -- ========================================
    [38] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_label_usage_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL THEN
                            UPDATE kanban_task_labels
                            SET usage_count = usage_count + 1
                            WHERE id = NEW.label_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL THEN
                            UPDATE kanban_task_labels
                            SET usage_count = GREATEST(0, usage_count - 1)
                            WHERE id = OLD.label_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        IF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL THEN
                                UPDATE kanban_task_labels
                                SET usage_count = usage_count + 1
                                WHERE id = NEW.label_id;
                            ELSE
                                UPDATE kanban_task_labels
                                SET usage_count = GREATEST(0, usage_count - 1)
                                WHERE id = NEW.label_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_task_label_links_usage_trigger ON kanban_task_label_links
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_task_label_links_usage_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_task_label_links
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_label_usage_count()
            ]])
        end)
    end,

    -- ========================================
    -- [39] Create board count triggers
    -- ========================================
    [39] = function()
        -- Column count on boards
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_board_column_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL THEN
                            UPDATE kanban_boards
                            SET column_count = column_count + 1,
                                updated_at = NOW()
                            WHERE id = NEW.board_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL THEN
                            UPDATE kanban_boards
                            SET column_count = GREATEST(0, column_count - 1),
                                updated_at = NOW()
                            WHERE id = OLD.board_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        IF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) THEN
                            IF NEW.deleted_at IS NULL THEN
                                UPDATE kanban_boards
                                SET column_count = column_count + 1,
                                    updated_at = NOW()
                                WHERE id = NEW.board_id;
                            ELSE
                                UPDATE kanban_boards
                                SET column_count = GREATEST(0, column_count - 1),
                                    updated_at = NOW()
                                WHERE id = NEW.board_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_columns_board_count_trigger ON kanban_columns
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_columns_board_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_columns
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_board_column_count()
            ]])
        end)

        -- Task count on boards
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_board_task_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL AND NEW.archived_at IS NULL THEN
                            UPDATE kanban_boards
                            SET task_count = task_count + 1,
                                updated_at = NOW()
                            WHERE id = NEW.board_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL AND OLD.archived_at IS NULL THEN
                            UPDATE kanban_boards
                            SET task_count = GREATEST(0, task_count - 1),
                                updated_at = NOW()
                            WHERE id = OLD.board_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        -- Handle board change
                        IF OLD.board_id IS DISTINCT FROM NEW.board_id THEN
                            IF OLD.deleted_at IS NULL AND OLD.archived_at IS NULL THEN
                                UPDATE kanban_boards
                                SET task_count = GREATEST(0, task_count - 1),
                                    updated_at = NOW()
                                WHERE id = OLD.board_id;
                            END IF;
                            IF NEW.deleted_at IS NULL AND NEW.archived_at IS NULL THEN
                                UPDATE kanban_boards
                                SET task_count = task_count + 1,
                                    updated_at = NOW()
                                WHERE id = NEW.board_id;
                            END IF;
                        -- Handle soft delete/archive
                        ELSIF ((OLD.deleted_at IS NULL AND OLD.archived_at IS NULL) !=
                               (NEW.deleted_at IS NULL AND NEW.archived_at IS NULL)) THEN
                            IF NEW.deleted_at IS NULL AND NEW.archived_at IS NULL THEN
                                UPDATE kanban_boards
                                SET task_count = task_count + 1,
                                    updated_at = NOW()
                                WHERE id = NEW.board_id;
                            ELSE
                                UPDATE kanban_boards
                                SET task_count = GREATEST(0, task_count - 1),
                                    updated_at = NOW()
                                WHERE id = NEW.board_id;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_tasks_board_count_trigger ON kanban_tasks
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_tasks_board_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_tasks
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_board_task_count()
            ]])
        end)
    end,

    -- ========================================
    -- [40] Create reply count trigger for comments
    -- ========================================
    [40] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_kanban_comment_reply_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        IF NEW.deleted_at IS NULL AND NEW.parent_comment_id IS NOT NULL THEN
                            UPDATE kanban_task_comments
                            SET reply_count = reply_count + 1
                            WHERE id = NEW.parent_comment_id;
                        END IF;
                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        IF OLD.deleted_at IS NULL AND OLD.parent_comment_id IS NOT NULL THEN
                            UPDATE kanban_task_comments
                            SET reply_count = GREATEST(0, reply_count - 1)
                            WHERE id = OLD.parent_comment_id;
                        END IF;
                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        IF NEW.parent_comment_id IS NOT NULL THEN
                            IF (OLD.deleted_at IS NULL) != (NEW.deleted_at IS NULL) THEN
                                IF NEW.deleted_at IS NULL THEN
                                    UPDATE kanban_task_comments
                                    SET reply_count = reply_count + 1
                                    WHERE id = NEW.parent_comment_id;
                                ELSE
                                    UPDATE kanban_task_comments
                                    SET reply_count = GREATEST(0, reply_count - 1)
                                    WHERE id = NEW.parent_comment_id;
                                END IF;
                            END IF;
                        END IF;
                        RETURN NEW;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS kanban_comments_reply_count_trigger ON kanban_task_comments
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER kanban_comments_reply_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON kanban_task_comments
                FOR EACH ROW
                EXECUTE FUNCTION update_kanban_comment_reply_count()
            ]])
        end)
    end
}
