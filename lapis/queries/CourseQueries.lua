--[[
    Academy Course Queries
    ======================
    Namespace-scoped CRUD + public catalogue reads for academy_courses.
]]

local AcademyCourseModel = require "models.AcademyCourseModel"
local Global = require "helper.global"
local db = require("lapis.db")

local CourseQueries = {}

local function slugify(text)
    if not text or text == "" then return "" end
    return (text:lower():gsub("%s+", "-"):gsub("[^%w%-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end
CourseQueries.slugify = slugify

--- Find a single non-deleted course scoped to a namespace.
local function findScoped(namespace_id, uuid)
    local course = AcademyCourseModel:find({ uuid = uuid, namespace_id = namespace_id })
    if not course or course.deleted_at then return nil end
    return course
end
CourseQueries.findScoped = findScoped

--- Create a course in a namespace.
function CourseQueries.create(namespace_id, params)
    params.uuid = params.uuid or Global.generateUUID()
    params.namespace_id = namespace_id
    if (not params.slug or params.slug == "") and params.title then
        params.slug = slugify(params.title)
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")
    return AcademyCourseModel:create(params, { returning = "*" })
end

--- List courses in a namespace with optional filters + pagination.
function CourseQueries.list(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 50
    local offset = (page - 1) * perPage

    local where = { "namespace_id = ?", "deleted_at IS NULL" }
    local values = { namespace_id }

    if params.status and params.status ~= "" then
        table.insert(where, "status = ?"); table.insert(values, params.status)
    end
    if params.category and params.category ~= "" then
        table.insert(where, "category = ?"); table.insert(values, params.category)
    end
    if params.level and params.level ~= "" then
        table.insert(where, "level = ?"); table.insert(values, params.level)
    end
    if params.is_free ~= nil then
        table.insert(where, "is_free = ?"); table.insert(values, params.is_free)
    end
    if params.search and params.search ~= "" then
        table.insert(where, "(title ILIKE ? OR description ILIKE ?)")
        local p = "%" .. params.search .. "%"
        table.insert(values, p); table.insert(values, p)
    end

    local where_sql = table.concat(where, " AND ")

    local list_values = {}
    for _, v in ipairs(values) do table.insert(list_values, v) end
    table.insert(list_values, perPage)
    table.insert(list_values, offset)

    local rows = db.query(
        "SELECT * FROM academy_courses WHERE " .. where_sql ..
        " ORDER BY updated_at DESC NULLS LAST LIMIT ? OFFSET ?",
        table.unpack(list_values)
    )

    local count = db.query("SELECT COUNT(*) AS total FROM academy_courses WHERE " .. where_sql,
        table.unpack(values))
    local total = count and count[1] and tonumber(count[1].total) or 0

    return { data = rows or {}, total = total, page = page, perPage = perPage }
end

function CourseQueries.getByUuid(namespace_id, uuid)
    return findScoped(namespace_id, uuid)
end

function CourseQueries.getBySlug(namespace_id, slug)
    local rows = db.query(
        "SELECT * FROM academy_courses WHERE namespace_id = ? AND slug = ? AND deleted_at IS NULL LIMIT 1",
        namespace_id, slug)
    return rows and rows[1] or nil
end

function CourseQueries.update(namespace_id, uuid, params)
    local course = findScoped(namespace_id, uuid)
    if not course then return nil end
    params.namespace_id = nil   -- never allow reassigning tenant
    params.id = nil
    params.uuid = nil
    params.updated_at = db.raw("NOW()")
    course:update(params)
    return course
end

function CourseQueries.softDelete(namespace_id, uuid)
    local course = findScoped(namespace_id, uuid)
    if not course then return nil end
    course:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return true
end

--- Recalculate lesson_count + duration_minutes from non-deleted lessons.
function CourseQueries.recalcStats(course_id)
    db.query([[
        UPDATE academy_courses c SET
            lesson_count = COALESCE(s.cnt, 0),
            duration_minutes = COALESCE(s.secs, 0) / 60,
            updated_at = NOW()
        FROM (
            SELECT COUNT(*) AS cnt, SUM(duration_seconds) AS secs
            FROM academy_lessons WHERE course_id = ? AND deleted_at IS NULL
        ) s
        WHERE c.id = ?
    ]], course_id, course_id)
end

--- Public: published courses in a namespace (optionally only free).
function CourseQueries.listPublished(namespace_id, params)
    params = params or {}
    local where = { "namespace_id = ?", "deleted_at IS NULL", "status = 'published'" }
    local values = { namespace_id }
    if params.free == true then
        table.insert(where, "is_free = TRUE")
    end
    if params.category and params.category ~= "" then
        table.insert(where, "category = ?"); table.insert(values, params.category)
    end
    local rows = db.query(
        "SELECT * FROM academy_courses WHERE " .. table.concat(where, " AND ") ..
        " ORDER BY rating DESC NULLS LAST, title ASC",
        table.unpack(values))
    return rows or {}
end

return CourseQueries
