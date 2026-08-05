--[[
    Academy Lesson Progress Queries
    ===============================
    Which lessons a learner has completed, keyed by the learner's JWT user uuid.

    A row in academy_lesson_progress means "completed". Un-completing deletes the
    row, so counting rows is the progress count and MAX(updated_at) is the
    learner's last activity on a course.
]]

local Global = require "helper.global"
local db = require("lapis.db")

local ProgressQueries = {}

--- Mark a lesson complete (idempotent). Returns true.
function ProgressQueries.complete(namespace_id, course_id, lesson_id, user_uuid)
    if not user_uuid then return false end
    db.query([[
        INSERT INTO academy_lesson_progress
            (uuid, namespace_id, course_id, lesson_id, user_uuid, completed_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, NOW(), NOW(), NOW())
        ON CONFLICT (lesson_id, user_uuid)
        DO UPDATE SET updated_at = NOW()
    ]], Global.generateUUID(), namespace_id, course_id, lesson_id, user_uuid)
    return true
end

--- Un-mark a lesson (idempotent). Returns true.
function ProgressQueries.uncomplete(lesson_id, user_uuid)
    if not user_uuid then return false end
    db.query("DELETE FROM academy_lesson_progress WHERE lesson_id = ? AND user_uuid = ?",
        lesson_id, user_uuid)
    return true
end

--- Completed lesson ids for one course, as a lookup set keyed by lesson id.
function ProgressQueries.completedLessonIds(course_id, user_uuid)
    if not user_uuid then return {} end
    local rows = db.query(
        "SELECT lesson_id FROM academy_lesson_progress WHERE course_id = ? AND user_uuid = ?",
        course_id, user_uuid)
    local set = {}
    for _, r in ipairs(rows or {}) do set[r.lesson_id] = true end
    return set
end

--- Per-course progress for a learner: completed count + last activity.
--- Returns a table keyed by course_id -> { completed = n, last_activity_at = ts }.
function ProgressQueries.summaryByCourse(namespace_id, user_uuid)
    if not user_uuid then return {} end
    local rows = db.query([[
        SELECT course_id, COUNT(*) AS completed, MAX(updated_at) AS last_activity_at
        FROM academy_lesson_progress
        WHERE user_uuid = ? AND namespace_id = ?
        GROUP BY course_id
    ]], user_uuid, namespace_id)
    local out = {}
    for _, r in ipairs(rows or {}) do
        out[r.course_id] = {
            completed = tonumber(r.completed) or 0,
            last_activity_at = r.last_activity_at,
        }
    end
    return out
end

--- Courses a learner has touched (has >=1 completed lesson), newest activity first.
function ProgressQueries.coursesWithProgress(namespace_id, user_uuid)
    if not user_uuid then return {} end
    local rows = db.query([[
        SELECT c.* FROM academy_courses c
        JOIN (
            SELECT course_id, MAX(updated_at) AS last_activity_at
            FROM academy_lesson_progress
            WHERE user_uuid = ? AND namespace_id = ?
            GROUP BY course_id
        ) p ON p.course_id = c.id
        WHERE c.deleted_at IS NULL
        ORDER BY p.last_activity_at DESC
    ]], user_uuid, namespace_id)
    return rows or {}
end

--- Headline learning stats for the dashboard.
--- minutes_completed sums the duration of the lessons actually completed.
function ProgressQueries.statsForUser(namespace_id, user_uuid)
    local empty = { lessons_completed = 0, minutes_completed = 0, courses_started = 0 }
    if not user_uuid then return empty end
    local rows = db.query([[
        SELECT
            COUNT(*)                              AS lessons_completed,
            COUNT(DISTINCT p.course_id)           AS courses_started,
            COALESCE(SUM(l.duration_seconds), 0)  AS seconds_completed
        FROM academy_lesson_progress p
        JOIN academy_lessons l ON l.id = p.lesson_id
        WHERE p.user_uuid = ? AND p.namespace_id = ?
    ]], user_uuid, namespace_id)
    local r = rows and rows[1]
    if not r then return empty end
    return {
        lessons_completed = tonumber(r.lessons_completed) or 0,
        courses_started = tonumber(r.courses_started) or 0,
        minutes_completed = math.floor((tonumber(r.seconds_completed) or 0) / 60),
    }
end

return ProgressQueries
