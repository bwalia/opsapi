--[[
    Academy (LMS) System Migrations
    ===============================

    A multi-tenant Learning Management System: courses and their lessons, with
    rich WYSIWYG content. Namespace-scoped for tenant isolation (mirrors the
    kanban/crm modules).

    Tables:
    =======
    1. academy_courses  - Courses (namespace-scoped) with catalogue metadata
    2. academy_lessons  - Lessons within a course; rich HTML content + editor JSON

    Notes:
    ======
    - All tables are namespace-scoped (FK → namespaces ON DELETE CASCADE).
    - Soft deletes (deleted_at) everywhere.
    - Unique slug per namespace; unique lesson position per course.
    - Lesson body is stored as sanitized `content_html` (rendered) plus
      `content_json` (the editor document, for re-editing).
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

local function table_exists(table_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.tables WHERE table_name = ?
        ) as exists
    ]], table_name)
    return result[1] and result[1].exists
end

local function index_exists(index_name)
    local result = db.query([[
        SELECT EXISTS (SELECT FROM pg_indexes WHERE indexname = ?) as exists
    ]], index_name)
    return result[1] and result[1].exists
end

return {
    -- ========================================================================
    -- [1] Create academy_courses
    -- ========================================================================
    [1] = function()
        if table_exists("academy_courses") then return end

        schema.create_table("academy_courses", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "title", types.varchar },
            { "slug", types.varchar },
            { "description", types.text({ null = true }) },
            { "instructor", types.varchar({ null = true }) },
            { "thumbnail_url", types.varchar({ null = true }) },
            { "category", types.varchar({ default = "general" }) },
            { "level", types.varchar({ default = "beginner" }) },
            { "is_free", types.boolean({ default = true }) },
            { "price", types.integer({ default = 0 }) },          -- minor units (cents)
            { "currency", types.varchar({ default = "USD" }) },
            { "rating", types.numeric({ default = 0 }) },
            { "rating_count", types.integer({ default = 0 }) },
            { "duration_minutes", types.integer({ default = 0 }) },
            { "lesson_count", types.integer({ default = 0 }) },
            { "status", types.varchar({ default = "draft" }) },   -- draft|published|archived
            { "owner_user_uuid", types.varchar({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE academy_courses
                ADD CONSTRAINT academy_courses_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE academy_courses
                ADD CONSTRAINT academy_courses_level_check
                CHECK (level IN ('beginner', 'intermediate', 'advanced'))
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE academy_courses
                ADD CONSTRAINT academy_courses_status_check
                CHECK (status IN ('draft', 'published', 'archived'))
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX academy_courses_namespace_slug_unique
                ON academy_courses (namespace_id, slug)
                WHERE deleted_at IS NULL
            ]])
        end)
    end,

    -- ========================================================================
    -- [2] academy_courses indexes
    -- ========================================================================
    [2] = function()
        if not index_exists("idx_academy_courses_uuid") then
            db.query("CREATE UNIQUE INDEX idx_academy_courses_uuid ON academy_courses (uuid)")
        end
        if not index_exists("idx_academy_courses_ns_status") then
            db.query([[
                CREATE INDEX idx_academy_courses_ns_status
                ON academy_courses (namespace_id, status)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_academy_courses_ns_free") then
            db.query([[
                CREATE INDEX idx_academy_courses_ns_free
                ON academy_courses (namespace_id, is_free)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_academy_courses_ns_category") then
            db.query([[
                CREATE INDEX idx_academy_courses_ns_category
                ON academy_courses (namespace_id, category)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================================================
    -- [3] Create academy_lessons
    -- ========================================================================
    [3] = function()
        if table_exists("academy_lessons") then return end

        schema.create_table("academy_lessons", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "course_id", types.integer },
            { "title", types.varchar },
            { "description", types.text({ null = true }) },
            { "position", types.integer({ default = 0 }) },
            { "duration_seconds", types.integer({ default = 0 }) },
            { "is_preview", types.boolean({ default = false }) },
            { "s3_key", types.varchar({ null = true }) },
            { "content_html", types.text({ null = true }) },   -- sanitized, rendered
            { "content_json", types.text({ null = true }) },   -- editor document (re-editing)
            { "status", types.varchar({ default = "draft" }) }, -- draft|published
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE academy_lessons
                ADD CONSTRAINT academy_lessons_course_fk
                FOREIGN KEY (course_id) REFERENCES academy_courses(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE academy_lessons
                ADD CONSTRAINT academy_lessons_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE academy_lessons
                ADD CONSTRAINT academy_lessons_status_check
                CHECK (status IN ('draft', 'published'))
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX academy_lessons_course_position_unique
                ON academy_lessons (course_id, position)
                WHERE deleted_at IS NULL
            ]])
        end)
    end,

    -- ========================================================================
    -- [4] academy_lessons indexes
    -- ========================================================================
    [4] = function()
        if not index_exists("idx_academy_lessons_uuid") then
            db.query("CREATE UNIQUE INDEX idx_academy_lessons_uuid ON academy_lessons (uuid)")
        end
        if not index_exists("idx_academy_lessons_course") then
            db.query([[
                CREATE INDEX idx_academy_lessons_course
                ON academy_lessons (course_id, position)
                WHERE deleted_at IS NULL
            ]])
        end
        if not index_exists("idx_academy_lessons_namespace") then
            db.query([[
                CREATE INDEX idx_academy_lessons_namespace
                ON academy_lessons (namespace_id)
                WHERE deleted_at IS NULL
            ]])
        end
    end,
}
