--[[
    Academy Lesson Progress Migration
    =================================

    Tracks which lessons a learner has completed, keyed by the learner's JWT
    user uuid. Namespace-scoped.

    A row means "this lesson is completed". Un-completing a lesson deletes the
    row, so the table only ever holds completions — `updated_at` doubles as the
    learner's last activity on the course.
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
    -- [1] Create academy_lesson_progress
    -- ========================================================================
    [1] = function()
        if table_exists("academy_lesson_progress") then return end

        schema.create_table("academy_lesson_progress", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "course_id", types.integer },
            { "lesson_id", types.integer },
            { "user_uuid", types.varchar },
            { "completed_at", types.time({ default = db.raw("NOW()") }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE academy_lesson_progress
                ADD CONSTRAINT academy_lesson_progress_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE academy_lesson_progress
                ADD CONSTRAINT academy_lesson_progress_course_fk
                FOREIGN KEY (course_id) REFERENCES academy_courses(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE academy_lesson_progress
                ADD CONSTRAINT academy_lesson_progress_lesson_fk
                FOREIGN KEY (lesson_id) REFERENCES academy_lessons(id) ON DELETE CASCADE
            ]])
        end)

        -- One completion row per (lesson, learner).
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX academy_lesson_progress_lesson_user_unique
                ON academy_lesson_progress (lesson_id, user_uuid)
            ]])
        end)
    end,

    -- ========================================================================
    -- [2] academy_lesson_progress indexes
    -- ========================================================================
    [2] = function()
        if not index_exists("idx_academy_lesson_progress_uuid") then
            db.query("CREATE UNIQUE INDEX idx_academy_lesson_progress_uuid ON academy_lesson_progress (uuid)")
        end
        -- Dashboard reads progress per learner, grouped by course.
        if not index_exists("idx_academy_lesson_progress_user_course") then
            db.query([[
                CREATE INDEX idx_academy_lesson_progress_user_course
                ON academy_lesson_progress (user_uuid, namespace_id, course_id)
            ]])
        end
    end,
}
