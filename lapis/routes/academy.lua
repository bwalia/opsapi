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
local NamespaceQueries = require "queries.NamespaceQueries"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local LEVELS = { beginner = true, intermediate = true, advanced = true }
local COURSE_STATUS = { draft = true, published = true, archived = true }
local LESSON_STATUS = { draft = true, published = true }

return function(app)
    -- Parse a JSON or form-encoded body into a table.
    local function parse_body()
        ngx.req.read_body()
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then return post_args end
        local ok, result = pcall(function()
            local body = ngx.req.get_body_data()
            if not body or body == "" then return {} end
            return cJson.decode(body)
        end)
        if ok and type(result) == "table" then return result end
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

    -- Shape a course row for public output.
    local function public_course(row, lessons)
        return {
            id = row.uuid,
            slug = row.slug,
            title = row.title,
            description = row.description,
            instructor = row.instructor,
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

            local updated = CourseQueries.update(self.namespace.id, self.params.uuid, fields)
            if not updated then return api_response(404, nil, "Course not found") end
            return api_response(200, updated)
        end)))

    app:delete("/api/v2/academy/courses/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "delete", function(self)
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
            return api_response(200, LessonQueries.listByCourse(course.id, { published_only = false }))
        end)))

    app:post("/api/v2/academy/courses/:uuid/lessons", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "create", function(self)
            local course = CourseQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not course then return api_response(404, nil, "Course not found") end

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

            local lesson = LessonQueries.update(self.namespace.id, self.params.uuid, fields)
            if not lesson then return api_response(404, nil, "Lesson not found") end
            CourseQueries.recalcStats(lesson.course_id)
            return api_response(200, lesson)
        end)))

    app:delete("/api/v2/academy/lessons/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "delete", function(self)
            local lesson = LessonQueries.softDelete(self.namespace.id, self.params.uuid)
            if not lesson then return api_response(404, nil, "Lesson not found") end
            CourseQueries.recalcStats(lesson.course_id)
            return api_response(200, { deleted = true })
        end)))

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
        return { status = 200, json = public_course(course, ls) }
    end)
end
