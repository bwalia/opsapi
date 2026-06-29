--[[
    Academy Enrollment Queries
    ==========================
    Learner ↔ course enrollments, keyed by the learner's JWT user uuid.
]]

local AcademyEnrollmentModel = require "models.AcademyEnrollmentModel"
local Global = require "helper.global"
local db = require("lapis.db")

local EnrollmentQueries = {}

function EnrollmentQueries.isEnrolled(course_id, user_uuid)
    if not user_uuid then return false end
    local rows = db.query(
        "SELECT 1 FROM academy_enrollments WHERE course_id = ? AND user_uuid = ? AND status = 'active' LIMIT 1",
        course_id, user_uuid)
    return rows ~= nil and #rows > 0
end

--- Enroll a user in a course (idempotent). Returns enrollment row.
function EnrollmentQueries.enroll(namespace_id, course_id, user_uuid)
    local existing = db.query(
        "SELECT * FROM academy_enrollments WHERE course_id = ? AND user_uuid = ? LIMIT 1",
        course_id, user_uuid)
    if existing and existing[1] then
        if existing[1].status ~= "active" then
            db.query("UPDATE academy_enrollments SET status = 'active', updated_at = NOW() WHERE id = ?",
                existing[1].id)
        end
        return existing[1]
    end
    return AcademyEnrollmentModel:create({
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        course_id = course_id,
        user_uuid = user_uuid,
        status = "active",
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

--- Active, published courses a user is enrolled in (namespace-scoped).
function EnrollmentQueries.listCoursesForUser(namespace_id, user_uuid)
    if not user_uuid then return {} end
    local rows = db.query([[
        SELECT c.* FROM academy_courses c
        JOIN academy_enrollments e ON e.course_id = c.id
        WHERE e.user_uuid = ? AND e.namespace_id = ? AND e.status = 'active'
          AND c.deleted_at IS NULL
        ORDER BY e.created_at DESC
    ]], user_uuid, namespace_id)
    return rows or {}
end

return EnrollmentQueries
