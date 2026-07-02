--[[
    Academy (LMS) API Routes
    ========================

    Multi-tenant courses + lessons with rich WYSIWYG content. Admin endpoints are
    namespace-scoped and RBAC-gated (module "courses"); public endpoints expose
    published content for a namespace to the learner-facing site.

    Admin (auth + namespace + RBAC module "courses"):
      GET    /api/v2/academy/courses
      POST   /api/v2/academy/courses
      GET    /api/v2/academy/courses/:uuid
      PUT    /api/v2/academy/courses/:uuid
      DELETE /api/v2/academy/courses/:uuid
      GET    /api/v2/academy/courses/:uuid/lessons
      POST   /api/v2/academy/courses/:uuid/lessons
      GET    /api/v2/academy/lessons/:uuid
      PUT    /api/v2/academy/lessons/:uuid
      DELETE /api/v2/academy/lessons/:uuid

    Public (no auth; namespace by slug):
      GET    /api/v2/public/academy/:namespace/courses?free=true
      GET    /api/v2/public/academy/:namespace/courses/:slug
]]

local cJson = require("cjson")
local CourseQueries = require "queries.CourseQueries"
local LessonQueries = require "queries.LessonQueries"
local EnrollmentQueries = require "queries.EnrollmentQueries"
local EntitlementQueries = require "queries.EntitlementQueries"
local NamespaceQueries = require "queries.NamespaceQueries"
local NamespaceRoleQueries = require "queries.NamespaceRoleQueries"
local NamespaceMemberQueries = require "queries.NamespaceMemberQueries"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local LEVELS = { beginner = true, intermediate = true, advanced = true }
local COURSE_STATUS = { draft = true, published = true, archived = true }
local LESSON_STATUS = { draft = true, published = true }

-- The single academy tenant. Instructors are a ROLE inside this one namespace —
-- we never let them create their own namespace (all academy content lives here).
local ACADEMY_NS_SLUG = os.getenv("BACKEND_ACADEMY_NAMESPACE") or "academy"

-- Permissions granted to the on-demand "instructor" role. Ownership scoping in
-- the handlers further restricts instructors to the courses they own; this RBAC
-- grant only opens the "courses" module, it does not let them touch other
-- instructors' content.
local INSTRUCTOR_PERMISSIONS = { courses = { "create", "read", "update", "delete" } }

return function(app)
    -- Parse a JSON or form-encoded body into a table.
    -- Large bodies (e.g. a lesson's rich content_html) exceed
    -- client_body_buffer_size, so nginx spills them to a temp file. In that case
    -- get_post_args()/get_body_data() return nothing from memory, so we fall back
    -- to reading the body file and parsing it ourselves (JSON, then urlencoded).
    local function parse_body()
        ngx.req.read_body()

        -- Fast path: small form body kept in memory.
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then return post_args end

        -- Body may be in memory (small JSON) or spilled to a temp file (large).
        local body = ngx.req.get_body_data()
        if not body or body == "" then
            local path = ngx.req.get_body_file()
            if path then
                local f = io.open(path, "rb")
                if f then
                    body = f:read("*a")
                    f:close()
                end
            end
        end
        if not body or body == "" then return {} end

        -- JSON first, then urlencoded form fallback.
        local ok, decoded = pcall(cJson.decode, body)
        if ok and type(decoded) == "table" then return decoded end

        local args = ngx.decode_args(body)
        if type(args) == "table" then return args end
        return {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    -- Coerce loose truthy values (forms send strings).
    local function to_bool(v, default)
        if v == nil then return default end
        if type(v) == "boolean" then return v end
        if type(v) == "number" then return v ~= 0 end
        local s = tostring(v):lower()
        return s == "true" or s == "1" or s == "yes"
    end

    -- Shape a lesson row for public output.
    local function public_lesson(row)
        return {
            id = row.uuid,
            title = row.title,
            description = row.description,
            position = row.position,
            duration_seconds = row.duration_seconds,
            is_preview = row.is_preview,
            content_html = row.content_html,
            created_at = row.created_at,
        }
    end

    -- Shape a course row for public output. `instructor_info` (optional) is the
    -- resolved owner identity { id, name, username }; when present it is the
    -- authoritative instructor. We fall back to the free-text `instructor` field
    -- (legacy / admin-entered), then to "Instructor", so the byline is never blank.
    local function public_course(row, lessons, instructor_info)
        local display = (instructor_info and instructor_info.name)
            or (row.instructor ~= nil and row.instructor ~= "" and row.instructor)
            or "Instructor"
        return {
            id = row.uuid,
            slug = row.slug,
            title = row.title,
            description = row.description,
            instructor = display,
            instructor_name = instructor_info and instructor_info.name or nil,
            instructor_username = instructor_info and instructor_info.username or nil,
            instructor_id = (instructor_info and instructor_info.id) or row.owner_user_uuid,
            thumbnail_url = row.thumbnail_url,
            category = row.category,
            level = row.level,
            is_free = row.is_free,
            price = row.price,
            currency = row.currency,
            rating = row.rating and tonumber(row.rating) or 0,
            rating_count = row.rating_count,
            duration_minutes = row.duration_minutes,
            lesson_count = row.lesson_count,
            created_at = row.created_at,
            updated_at = row.updated_at,
            lessons = lessons or {},
        }
    end

    ---------------------------------------------------------------------------
    -- OWNERSHIP MODEL (single academy namespace, instructor = RBAC role)
    --   * namespace owner / platform admin → manage ALL courses
    --   * instructor (courses role)          → manage only courses they own
    ---------------------------------------------------------------------------

    local function can_manage_all(self)
        return self.is_platform_admin == true or self.is_namespace_owner == true
    end

    -- Owner filter to hand CourseQueries.list: nil for admins/owners (see all),
    -- else the caller's uuid so instructors see only their own courses.
    local function owner_scope(self)
        if can_manage_all(self) then return nil end
        return (self.current_user and self.current_user.uuid) or "__none__"
    end

    -- Guard a specific course: true if the caller may manage it.
    local function ensure_owns(self, course)
        if can_manage_all(self) then return true end
        local uid = self.current_user and self.current_user.uuid
        return course ~= nil and course.owner_user_uuid ~= nil
            and uid ~= nil and course.owner_user_uuid == uid
    end

    -- Find (or lazily create) the "instructor" role in the academy namespace.
    -- Created on-demand because the academy namespace itself is provisioned by
    -- setup-namespace AFTER migrations run, so it can't be seeded in a migration.
    local function ensure_instructor_role(namespace_id)
        local existing = NamespaceRoleQueries.findByName(namespace_id, "instructor")
        if existing then return existing end
        local ok, role_or_err = pcall(NamespaceRoleQueries.create, {
            namespace_id = namespace_id,
            role_name = "instructor",
            display_name = "Instructor",
            description = "Create and manage their own academy courses and lessons",
            permissions = INSTRUCTOR_PERMISSIONS,
            is_system = false,
            is_default = false,
            priority = 50,
        })
        if ok then return role_or_err end
        -- Lost a create race (unique role_name) — re-read.
        return NamespaceRoleQueries.findByName(namespace_id, "instructor")
    end

    ---------------------------------------------------------------------------
    -- ADMIN: COURSES
    ---------------------------------------------------------------------------

    app:get("/api/v2/academy/courses", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "read", function(self)
            local result = CourseQueries.list(self.namespace.id, {
                page = self.params.page,
                perPage = self.params.perPage,
                status = self.params.status,
                category = self.params.category,
                level = self.params.level,
                search = self.params.search,
                owner_user_uuid = owner_scope(self),
            })
            return {
                status = 200,
                json = {
                    success = true,
                    data = result.data,
                    pagination = { page = result.page, perPage = result.perPage, total = result.total },
                }
            }
        end)))

    app:post("/api/v2/academy/courses", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "create", function(self)
            local body = parse_body()
            if not body.title or body.title == "" then
                return api_response(400, nil, "title is required")
            end
            local level = body.level or "beginner"
            if not LEVELS[level] then
                return api_response(400, nil, "Invalid level (beginner|intermediate|advanced)")
            end
            local status = body.status or "draft"
            if not COURSE_STATUS[status] then
                return api_response(400, nil, "Invalid status (draft|published|archived)")
            end

            local ok, course_or_err = pcall(CourseQueries.create, self.namespace.id, {
                title = body.title,
                slug = body.slug,
                description = body.description,
                instructor = body.instructor,
                thumbnail_url = body.thumbnail_url,
                category = body.category or "general",
                level = level,
                is_free = to_bool(body.is_free, true),
                price = tonumber(body.price) or 0,
                currency = body.currency or "USD",
                status = status,
                owner_user_uuid = self.current_user.uuid,
            })
            if not ok then
                ngx.log(ngx.ERR, "[academy] create course failed: ", tostring(course_or_err))
                return api_response(409, nil, "Could not create course (slug may already exist)")
            end
            return api_response(201, course_or_err)
        end)))

    app:get("/api/v2/academy/courses/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "read", function(self)
            local course = CourseQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not course then return api_response(404, nil, "Course not found") end
            if not ensure_owns(self, course) then
                return api_response(403, nil, "You can only view your own courses")
            end
            local lessons = LessonQueries.listByCourse(course.id, { published_only = false })
            local data = { course = course, lessons = lessons }
            return api_response(200, data)
        end)))

    app:put("/api/v2/academy/courses/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "update", function(self)
            local body = parse_body()
            if body.level and not LEVELS[body.level] then
                return api_response(400, nil, "Invalid level")
            end
            if body.status and not COURSE_STATUS[body.status] then
                return api_response(400, nil, "Invalid status")
            end

            local fields = {}
            for _, k in ipairs({ "title", "slug", "description", "instructor", "thumbnail_url",
                "category", "level", "status", "currency" }) do
                if body[k] ~= nil then fields[k] = body[k] end
            end
            if body.is_free ~= nil then fields.is_free = to_bool(body.is_free, true) end
            if body.price ~= nil then fields.price = tonumber(body.price) or 0 end

            if not can_manage_all(self) then
                local existing = CourseQueries.getByUuid(self.namespace.id, self.params.uuid)
                if not existing then return api_response(404, nil, "Course not found") end
                if not ensure_owns(self, existing) then
                    return api_response(403, nil, "You can only manage your own courses")
                end
            end

            local updated = CourseQueries.update(self.namespace.id, self.params.uuid, fields)
            if not updated then return api_response(404, nil, "Course not found") end
            return api_response(200, updated)
        end)))

    app:delete("/api/v2/academy/courses/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "delete", function(self)
            if not can_manage_all(self) then
                local existing = CourseQueries.getByUuid(self.namespace.id, self.params.uuid)
                if not existing then return api_response(404, nil, "Course not found") end
                if not ensure_owns(self, existing) then
                    return api_response(403, nil, "You can only delete your own courses")
                end
            end
            local ok = CourseQueries.softDelete(self.namespace.id, self.params.uuid)
            if not ok then return api_response(404, nil, "Course not found") end
            return api_response(200, { deleted = true })
        end)))

    ---------------------------------------------------------------------------
    -- ADMIN: LESSONS
    ---------------------------------------------------------------------------

    app:get("/api/v2/academy/courses/:uuid/lessons", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "read", function(self)
            local course = CourseQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not course then return api_response(404, nil, "Course not found") end
            if not ensure_owns(self, course) then
                return api_response(403, nil, "You can only view lessons in your own courses")
            end
            return api_response(200, LessonQueries.listByCourse(course.id, { published_only = false }))
        end)))

    app:post("/api/v2/academy/courses/:uuid/lessons", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "create", function(self)
            local course = CourseQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not course then return api_response(404, nil, "Course not found") end
            if not ensure_owns(self, course) then
                return api_response(403, nil, "You can only add lessons to your own courses")
            end

            local body = parse_body()
            if not body.title or body.title == "" then
                return api_response(400, nil, "title is required")
            end
            local status = body.status or "draft"
            if not LESSON_STATUS[status] then
                return api_response(400, nil, "Invalid status (draft|published)")
            end

            local lesson = LessonQueries.create(self.namespace.id, course.id, {
                title = body.title,
                description = body.description,
                position = body.position and tonumber(body.position) or nil,
                duration_seconds = tonumber(body.duration_seconds) or 0,
                is_preview = to_bool(body.is_preview, false),
                s3_key = body.s3_key,
                content_html = body.content_html,
                content_json = body.content_json,
                status = status,
            })
            CourseQueries.recalcStats(course.id)
            return api_response(201, lesson)
        end)))

    app:get("/api/v2/academy/lessons/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "read", function(self)
            local lesson = LessonQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not lesson then return api_response(404, nil, "Lesson not found") end
            if not can_manage_all(self) then
                local course = CourseQueries.findById(self.namespace.id, lesson.course_id)
                if not ensure_owns(self, course) then
                    return api_response(403, nil, "You can only view lessons in your own courses")
                end
            end
            return api_response(200, lesson)
        end)))

    app:put("/api/v2/academy/lessons/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "update", function(self)
            local body = parse_body()
            if body.status and not LESSON_STATUS[body.status] then
                return api_response(400, nil, "Invalid status")
            end
            local fields = {}
            for _, k in ipairs({ "title", "description", "s3_key", "content_html",
                "content_json", "status" }) do
                if body[k] ~= nil then fields[k] = body[k] end
            end
            if body.position ~= nil then fields.position = tonumber(body.position) end
            if body.duration_seconds ~= nil then fields.duration_seconds = tonumber(body.duration_seconds) or 0 end
            if body.is_preview ~= nil then fields.is_preview = to_bool(body.is_preview, false) end

            if not can_manage_all(self) then
                local existing = LessonQueries.getByUuid(self.namespace.id, self.params.uuid)
                if not existing then return api_response(404, nil, "Lesson not found") end
                local course = CourseQueries.findById(self.namespace.id, existing.course_id)
                if not ensure_owns(self, course) then
                    return api_response(403, nil, "You can only manage lessons in your own courses")
                end
            end

            local lesson = LessonQueries.update(self.namespace.id, self.params.uuid, fields)
            if not lesson then return api_response(404, nil, "Lesson not found") end
            CourseQueries.recalcStats(lesson.course_id)
            return api_response(200, lesson)
        end)))

    app:delete("/api/v2/academy/lessons/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "delete", function(self)
            if not can_manage_all(self) then
                local existing = LessonQueries.getByUuid(self.namespace.id, self.params.uuid)
                if not existing then return api_response(404, nil, "Lesson not found") end
                local course = CourseQueries.findById(self.namespace.id, existing.course_id)
                if not ensure_owns(self, course) then
                    return api_response(403, nil, "You can only delete lessons in your own courses")
                end
            end
            local lesson = LessonQueries.softDelete(self.namespace.id, self.params.uuid)
            if not lesson then return api_response(404, nil, "Lesson not found") end
            CourseQueries.recalcStats(lesson.course_id)
            return api_response(200, { deleted = true })
        end)))

    ---------------------------------------------------------------------------
    -- INSTRUCTOR: self-service registration (auth only, no RBAC yet)
    --   Instructors are a role INSIDE the single academy namespace; they never
    --   create their own namespace. Any authenticated user may become one.
    ---------------------------------------------------------------------------

    -- GET current user's instructor standing in the academy namespace.
    app:get("/api/v2/academy/instructor/status", AuthMiddleware.requireAuth(function(self)
        local ns = NamespaceQueries.findBySlug(ACADEMY_NS_SLUG)
        if not ns then return api_response(503, nil, "Academy is not configured") end

        local uid = self.current_user and self.current_user.uuid
        local membership = uid and NamespaceMemberQueries.findByUserAndNamespace(uid, ns.id) or nil

        local is_owner, is_instructor = false, false
        if membership then
            local raw = membership.is_owner
            is_owner = raw == true or raw == "t" or raw == 1
            for _, r in ipairs(NamespaceMemberQueries.getRoles(membership.id) or {}) do
                if r.role_name == "instructor" then is_instructor = true break end
            end
        end

        return api_response(200, {
            is_instructor = is_instructor or is_owner,
            is_owner = is_owner,
            namespace = { id = ns.id, uuid = ns.uuid, slug = ns.slug, name = ns.name },
        })
    end))

    -- POST become an instructor: ensure the role exists, add membership, assign role.
    app:post("/api/v2/academy/instructor/register", AuthMiddleware.requireAuth(function(self)
        local ns = NamespaceQueries.findBySlug(ACADEMY_NS_SLUG)
        if not ns then return api_response(503, nil, "Academy is not configured") end

        local uid = self.current_user and self.current_user.uuid
        if not uid then return api_response(401, nil, "Authentication required") end

        local ok, err = pcall(function()
            local role = ensure_instructor_role(ns.id)
            if not role then error("could not provision instructor role") end

            local membership = NamespaceMemberQueries.findByUserAndNamespace(uid, ns.id)
            if not membership then
                NamespaceMemberQueries.create({
                    namespace_id = ns.id,
                    user_id = uid,
                    status = "active",
                    role_ids = { role.id },
                })
            else
                NamespaceMemberQueries.assignRole(membership.id, role.id)
            end
        end)
        if not ok then
            ngx.log(ngx.ERR, "[academy] instructor register failed: ", tostring(err))
            return api_response(500, nil, "Could not complete instructor registration")
        end

        return api_response(201, {
            is_instructor = true,
            namespace = { id = ns.id, uuid = ns.uuid, slug = ns.slug, name = ns.name },
        })
    end))

    ---------------------------------------------------------------------------
    -- PUBLIC: learner-facing reads (no auth; namespace by slug)
    ---------------------------------------------------------------------------

    local function resolve_namespace(self)
        local ns = NamespaceQueries.findBySlug(self.params.namespace)
        return ns
    end

    app:get("/api/v2/public/academy/:namespace/courses", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end

        local free = self.params.free == "true" or self.params.free == "1"
        local courses = CourseQueries.listPublished(ns.id, {
            free = free or nil,
            category = self.params.category,
        })

        local ids, owner_uuids = {}, {}
        for _, c in ipairs(courses) do
            table.insert(ids, c.id)
            if c.owner_user_uuid then table.insert(owner_uuids, c.owner_user_uuid) end
        end
        local lessons_by_course = LessonQueries.listByCourseIds(ids, { published_only = true })
        local instructors = CourseQueries.instructorsByUuids(owner_uuids)

        local out = {}
        for _, c in ipairs(courses) do
            local ls = {}
            for _, l in ipairs(lessons_by_course[c.id] or {}) do
                table.insert(ls, public_lesson(l))
            end
            table.insert(out, public_course(c, ls, instructors[c.owner_user_uuid]))
        end
        return { status = 200, json = { courses = out, count = #out } }
    end)

    app:get("/api/v2/public/academy/:namespace/courses/:slug", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end

        local course = CourseQueries.getBySlug(ns.id, self.params.slug)
        if not course or course.status ~= "published" then
            return api_response(404, nil, "Course not found")
        end
        local lessons = LessonQueries.listByCourse(course.id, { published_only = true })
        local ls = {}
        for _, l in ipairs(lessons) do table.insert(ls, public_lesson(l)) end
        local instructors = CourseQueries.instructorsByUuids({ course.owner_user_uuid })
        return { status = 200, json = public_course(course, ls, instructors[course.owner_user_uuid]) }
    end)

    ---------------------------------------------------------------------------
    -- LEARNER: enrollment (auth required; namespace by slug). Responses use the
    -- flat shapes the learner site expects (not the {success,data} envelope).
    ---------------------------------------------------------------------------

    -- Enroll the current user in a published course.
    app:post("/api/v2/public/academy/:namespace/courses/:slug/enroll",
        AuthMiddleware.requireAuth(function(self)
            local ns = resolve_namespace(self)
            if not ns then return api_response(404, nil, "Namespace not found") end
            if not self.current_user or not self.current_user.uuid then
                return api_response(401, nil, "Authentication required")
            end
            local course = CourseQueries.getBySlug(ns.id, self.params.slug)
            if not course or course.status ~= "published" then
                return api_response(404, nil, "Course not found")
            end
            local ok = pcall(EnrollmentQueries.enroll, ns.id, course.id, self.current_user.uuid)
            if not ok then
                ngx.log(ngx.ERR, "[academy] enroll failed for course ", course.uuid)
                return { status = 500, json = { enrolled = false, error = "Could not enroll" } }
            end
            return {
                status = 201,
                json = { enrolled = true, course_id = course.uuid, message = "Enrolled successfully" },
            }
        end))

    -- Whether the current user is enrolled in a course.
    app:get("/api/v2/public/academy/:namespace/courses/:slug/enrollment",
        AuthMiddleware.requireAuth(function(self)
            local ns = resolve_namespace(self)
            if not ns then return api_response(404, nil, "Namespace not found") end
            local course = CourseQueries.getBySlug(ns.id, self.params.slug)
            if not course then return { status = 200, json = { enrolled = false } } end
            local uuid = self.current_user and self.current_user.uuid
            -- "enrolled" here means "has access" — free, owned, purchased, or an
            -- active community subscription all count.
            local has_access = EntitlementQueries.hasCourseAccess(uuid, course)
            return { status = 200, json = { enrolled = has_access or false, course_id = course.uuid } }
        end))

    -- Courses the current user is enrolled in (with published lessons).
    app:get("/api/v2/public/academy/:namespace/enrollments/me",
        AuthMiddleware.requireAuth(function(self)
            local ns = resolve_namespace(self)
            if not ns then return api_response(404, nil, "Namespace not found") end
            local uuid = self.current_user and self.current_user.uuid
            local courses = uuid and EnrollmentQueries.listCoursesForUser(ns.id, uuid) or {}

            local ids = {}
            for _, c in ipairs(courses) do table.insert(ids, c.id) end
            local lessons_by_course = LessonQueries.listByCourseIds(ids, { published_only = true })

            local out = {}
            for _, c in ipairs(courses) do
                local ls = {}
                for _, l in ipairs(lessons_by_course[c.id] or {}) do
                    table.insert(ls, public_lesson(l))
                end
                table.insert(out, public_course(c, ls))
            end
            return { status = 200, json = { courses = out, count = #out } }
        end))
end
