--[[
    Academy Lesson Queries
    ======================
    Namespace-scoped CRUD for academy_lessons (children of academy_courses).
]]

local AcademyLessonModel = require "models.AcademyLessonModel"
local Global = require "helper.global"
local db = require("lapis.db")

local LessonQueries = {}

local function findScoped(namespace_id, uuid)
    local lesson = AcademyLessonModel:find({ uuid = uuid, namespace_id = namespace_id })
    if not lesson or lesson.deleted_at then return nil end
    return lesson
end
LessonQueries.findScoped = findScoped

--- Next free position within a course (1-based).
local function nextPosition(course_id)
    local rows = db.query(
        "SELECT COALESCE(MAX(position), 0) + 1 AS pos FROM academy_lessons WHERE course_id = ? AND deleted_at IS NULL",
        course_id)
    return rows and rows[1] and tonumber(rows[1].pos) or 1
end

--- Create a lesson under a course.
function LessonQueries.create(namespace_id, course_id, params)
    params.uuid = params.uuid or Global.generateUUID()
    params.namespace_id = namespace_id
    params.course_id = course_id
    if params.position == nil then
        params.position = nextPosition(course_id)
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")
    return AcademyLessonModel:create(params, { returning = "*" })
end

--- List lessons in a course (ordered). `published_only` for public reads.
function LessonQueries.listByCourse(course_id, opts)
    opts = opts or {}
    local where = { "course_id = ?", "deleted_at IS NULL" }
    local values = { course_id }
    if opts.published_only then
        table.insert(where, "status = 'published'")
    end
    local rows = db.query(
        "SELECT * FROM academy_lessons WHERE " .. table.concat(where, " AND ") ..
        " ORDER BY position ASC",
        table.unpack(values))
    return rows or {}
end

--- Map of course_id -> lessons[], for a set of course ids (public composition).
function LessonQueries.listByCourseIds(course_ids, opts)
    opts = opts or {}
    local grouped = {}
    for _, id in ipairs(course_ids) do grouped[id] = {} end
    if #course_ids == 0 then return grouped end

    local placeholders = {}
    for i = 1, #course_ids do placeholders[i] = "?" end
    local where = "course_id IN (" .. table.concat(placeholders, ", ") .. ") AND deleted_at IS NULL"
    if opts.published_only then where = where .. " AND status = 'published'" end

    local rows = db.query(
        "SELECT * FROM academy_lessons WHERE " .. where .. " ORDER BY course_id, position ASC",
        table.unpack(course_ids)) or {}
    for _, row in ipairs(rows) do
        local bucket = grouped[row.course_id]
        if bucket then table.insert(bucket, row) end
    end
    return grouped
end

function LessonQueries.getByUuid(namespace_id, uuid)
    return findScoped(namespace_id, uuid)
end

function LessonQueries.update(namespace_id, uuid, params)
    local lesson = findScoped(namespace_id, uuid)
    if not lesson then return nil end
    params.namespace_id = nil
    params.id = nil
    params.uuid = nil
    params.course_id = nil   -- lessons don't move between courses here
    params.updated_at = db.raw("NOW()")
    lesson:update(params)
    return lesson
end

function LessonQueries.softDelete(namespace_id, uuid)
    local lesson = findScoped(namespace_id, uuid)
    if not lesson then return nil end
    lesson:update({ deleted_at = db.raw("NOW()"), updated_at = db.raw("NOW()") })
    return lesson
end

return LessonQueries
