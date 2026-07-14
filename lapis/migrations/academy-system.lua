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

    -- ========================================================================
    -- [5] academy_instructor_profiles — public teacher profile (per user)
    --     Bio, headline, avatar + JSON lists (achievements, education, skills,
    --     socials). Keyed by user_uuid; editable by the instructor, shown to
    --     learners on the instructor's public profile page.
    -- ========================================================================
    [5] = function()
        if table_exists("academy_instructor_profiles") then return end
        schema.create_table("academy_instructor_profiles", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer({ null = true }) },
            { "headline", types.varchar({ null = true }) },
            { "bio", types.text({ null = true }) },
            { "avatar_url", types.varchar({ null = true }) },
            { "location", types.varchar({ null = true }) },
            { "website", types.varchar({ null = true }) },
            { "socials", types.text({ null = true }) },      -- JSON object
            { "achievements", types.text({ null = true }) }, -- JSON array
            { "education", types.text({ null = true }) },     -- JSON array
            { "skills", types.text({ null = true }) },        -- JSON array
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        if not index_exists("idx_academy_instructor_profiles_user") then
            db.query("CREATE UNIQUE INDEX idx_academy_instructor_profiles_user ON academy_instructor_profiles (user_uuid)")
        end
    end,

    -- ========================================================================
    -- [6] Seed the "academy" tenant namespace
    --
    -- The learner site addresses one fixed tenant by slug (BACKEND_ACADEMY_NAMESPACE,
    -- default "academy"): every public route is /public/academy/ACADEMY/... . On a
    -- fresh database only the "system" namespace exists, so without this the site's
    -- resolve_namespace finds nothing and every catalogue request 500s.
    --
    -- Mirrors the system-namespace seed (namespace-system.lua [22]/[23]): namespace
    -- row + roles + the admin user as owner. The role permissions bake in the
    -- academy RBAC module ("courses") directly, because 806_grant_academy_permissions
    -- runs BEFORE this namespace exists and so can't grant to it.
    --
    -- Idempotent (guarded on the slug) and ACADEMY-feature-gated, so it never runs
    -- in a non-academy deployment.
    -- ========================================================================
    [6] = function()
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()
        local slug = os.getenv("BACKEND_ACADEMY_NAMESPACE") or "academy"

        if #db.select("* FROM namespaces WHERE slug = ?", slug) > 0 then return end

        db.insert("namespaces", {
            uuid = MigrationUtils.generateUUID(),
            name = "Academy",
            slug = slug,
            description = "Academy LMS tenant (courses, lessons, instructors)",
            status = "active",
            plan = "enterprise",
            settings = "{}",
            max_users = 1000000,
            max_stores = 1000000,
            created_at = ts,
            updated_at = ts,
        })
        local namespace_id = db.select("* FROM namespaces WHERE slug = ?", slug)[1].id

        -- owner/admin can manage courses; member is the default for a signed-up
        -- learner. "courses" is the academy RBAC module the route handlers check.
        local roles = {
            {
                role_name = "owner", display_name = "Owner",
                description = "Full control over the academy namespace",
                permissions = '{"dashboard":["create","read","update","delete","manage"],"users":["create","read","update","delete","manage"],"roles":["create","read","update","delete","manage"],"settings":["create","read","update","delete","manage"],"namespace":["create","read","update","delete","manage"],"courses":["create","read","update","delete","manage"],"reports":["create","read","update","delete","manage"]}',
                is_system = true, is_default = false, priority = 100,
            },
            {
                role_name = "admin", display_name = "Administrator",
                description = "Administrative access except namespace deletion",
                permissions = '{"dashboard":["create","read","update","delete","manage"],"users":["create","read","update","delete"],"roles":["create","read","update","delete"],"settings":["create","read","update","delete"],"namespace":["read","update"],"courses":["create","read","update","delete","manage"],"reports":["read","manage"]}',
                is_system = true, is_default = false, priority = 90,
            },
            {
                role_name = "member", display_name = "Member",
                description = "Standard learner",
                permissions = '{"dashboard":["read"],"courses":["read"]}',
                is_system = true, is_default = true, priority = 20,
            },
        }
        for _, r in ipairs(roles) do
            db.insert("namespace_roles", {
                uuid = MigrationUtils.generateUUID(),
                namespace_id = namespace_id,
                role_name = r.role_name,
                display_name = r.display_name,
                description = r.description,
                permissions = r.permissions,
                is_system = r.is_system,
                is_default = r.is_default,
                priority = r.priority,
                created_at = ts,
                updated_at = ts,
            })
        end

        -- Make the platform admin the owner, so the namespace is manageable from
        -- the dashboard out of the box.
        local admin = db.select("* FROM users WHERE username = ?", "administrative")
        if #admin > 0 then
            local user_id = admin[1].id
            local member_uuid = MigrationUtils.generateUUID()
            db.insert("namespace_members", {
                uuid = member_uuid,
                namespace_id = namespace_id,
                user_id = user_id,
                status = "active",
                is_owner = true,
                joined_at = ts,
                created_at = ts,
                updated_at = ts,
            })
            local member = db.select("* FROM namespace_members WHERE uuid = ?", member_uuid)
            local owner_role = db.select("* FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", namespace_id, "owner")
            if #member > 0 and #owner_role > 0 then
                db.insert("namespace_user_roles", {
                    uuid = MigrationUtils.generateUUID(),
                    namespace_member_id = member[1].id,
                    namespace_role_id = owner_role[1].id,
                    created_at = ts,
                    updated_at = ts,
                })
            end
            db.update("namespaces", { owner_user_id = user_id }, { id = namespace_id })
        end

        -- Show the Academy item in this namespace's dashboard sidebar. The menu row
        -- (key "academy") is seeded by 805; 807 only enabled it for namespaces that
        -- existed then, so enable it here for the one we just created.
        if table_exists("namespace_menu_config") then
            local menu = db.select("* FROM menu_items WHERE key = ?", "academy")
            if #menu > 0 then
                db.insert("namespace_menu_config", {
                    uuid = MigrationUtils.generateUUID(),
                    namespace_id = namespace_id,
                    menu_item_id = menu[1].id,
                    is_enabled = true,
                    created_at = ts,
                    updated_at = ts,
                })
            end
        end
    end,
}
