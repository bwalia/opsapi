--[[
    Academy Entitlement Queries
    ===========================
    The single, server-authoritative answer to "can user U access course C?".

    Access (per-creator / Skool model) is granted when ANY holds:
      - the course is free
      - U owns the course (instructor)
      - U has a one-time purchase/enrollment for the course
      - U has an ACTIVE subscription to the course's community (namespace)
]]

local EnrollmentQueries = require "queries.EnrollmentQueries"
local db = require("lapis.db")

local EntitlementQueries = {}

local ACTIVE_STATUSES = "('active', 'trialing')"

--- Active community subscription row for a user in a namespace, or nil.
function EntitlementQueries.activeSubscription(user_uuid, namespace_id)
    if not user_uuid or not namespace_id then return nil end
    local rows = db.query([[
        SELECT * FROM academy_subscriptions
        WHERE user_uuid = ? AND namespace_id = ?
          AND status IN ]] .. ACTIVE_STATUSES .. [[
          AND (current_period_end IS NULL OR current_period_end > NOW())
        ORDER BY created_at DESC
        LIMIT 1
    ]], user_uuid, namespace_id)
    return rows and rows[1] or nil
end

function EntitlementQueries.hasActiveSubscription(user_uuid, namespace_id)
    return EntitlementQueries.activeSubscription(user_uuid, namespace_id) ~= nil
end

--- Can the user access this course? `course` is a full academy_courses row.
function EntitlementQueries.hasCourseAccess(user_uuid, course)
    if not course then return false end
    -- Free courses are open to everyone (even anonymous).
    if course.is_free == true or course.is_free == "t" then return true end
    if not user_uuid then return false end
    -- Instructor / owner.
    if course.owner_user_uuid and course.owner_user_uuid == user_uuid then return true end
    -- One-time purchase / enrollment (à la carte access to a single course).
    if EnrollmentQueries.isEnrolled(course.id, user_uuid) then return true end
    -- Active community subscription whose plan tier covers this course's tier.
    -- Tolerant of the tier columns not existing yet: a nil `plan_tier`/`tier`
    -- reads as 1, so a pre-migration database behaves exactly like the old
    -- "any active subscription unlocks everything" rule (all courses are tier 1).
    local sub = EntitlementQueries.activeSubscription(user_uuid, course.namespace_id)
    if sub then
        local plan_tier = tonumber(sub.plan_tier) or 1
        local course_tier = tonumber(course.tier) or 1
        if plan_tier >= course_tier then return true end
    end
    return false
end

return EntitlementQueries
