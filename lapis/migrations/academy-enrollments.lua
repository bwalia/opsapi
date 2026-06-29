--[[
    Academy Enrollments Migration
    =============================

    Tracks which learner (by JWT user uuid) is enrolled in which academy course.
    Namespace-scoped. One active enrollment per (course, user).
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
    -- [1] Create academy_enrollments
    -- ========================================================================
    [1] = function()
        if table_exists("academy_enrollments") then return end

        schema.create_table("academy_enrollments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "course_id", types.integer },
            { "user_uuid", types.varchar },
            { "status", types.varchar({ default = "active" }) }, -- active|cancelled
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE academy_enrollments
                ADD CONSTRAINT academy_enrollments_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE academy_enrollments
                ADD CONSTRAINT academy_enrollments_course_fk
                FOREIGN KEY (course_id) REFERENCES academy_courses(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE academy_enrollments
                ADD CONSTRAINT academy_enrollments_status_check
                CHECK (status IN ('active', 'cancelled'))
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX academy_enrollments_course_user_unique
                ON academy_enrollments (course_id, user_uuid)
            ]])
        end)
    end,

    -- ========================================================================
    -- [2] academy_enrollments indexes
    -- ========================================================================
    [2] = function()
        if not index_exists("idx_academy_enrollments_uuid") then
            db.query("CREATE UNIQUE INDEX idx_academy_enrollments_uuid ON academy_enrollments (uuid)")
        end
        if not index_exists("idx_academy_enrollments_user") then
            db.query([[
                CREATE INDEX idx_academy_enrollments_user
                ON academy_enrollments (user_uuid, namespace_id)
            ]])
        end
    end,
}
