--[[
    Instructor Queries
    ==================
    Public teacher directory + per-instructor profile (bio, achievements,
    education, skills, socials). An "instructor" for the public directory is any
    user who owns at least one PUBLISHED course in the namespace. Profiles are
    editable by the instructor and shown to learners.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require "helper.global"
local ProfileModel = require "models.AcademyInstructorProfileModel"

local InstructorQueries = {}

-- JSON columns stored as text.
local JSON_ARRAY_FIELDS = { "achievements", "education", "skills" }
local JSON_OBJECT_FIELDS = { "socials" }

local function decode_json(value, fallback)
    if value == nil or value == "" then return fallback end
    local ok, parsed = pcall(cjson.decode, value)
    if ok then return parsed end
    return fallback
end

--- Turn a raw profile row into a parsed, public-safe object. Missing profile
--- rows still yield sensible empty defaults so callers never nil-check.
local function shape_profile(row)
    row = row or {}
    return {
        headline = row.headline,
        bio = row.bio,
        avatar_url = row.avatar_url,
        location = row.location,
        website = row.website,
        socials = decode_json(row.socials, cjson.empty_array_mt and {} or {}),
        achievements = decode_json(row.achievements, {}),
        education = decode_json(row.education, {}),
        skills = decode_json(row.skills, {}),
    }
end
InstructorQueries.shapeProfile = shape_profile

--- Instructor display name from a user row.
local function display_name(u)
    local name = ((u.first_name or "") .. " " .. (u.last_name or ""))
        :gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = u.username or u.email or "Instructor" end
    return name
end
InstructorQueries.displayName = display_name

--- The instructor's own profile (for the dashboard editor). Always returns an
--- object, even before they've saved anything.
function InstructorQueries.getProfile(user_uuid)
    local row = ProfileModel:find({ user_uuid = user_uuid })
    local shaped = shape_profile(row)
    shaped.exists = row ~= nil
    return shaped
end

--- Create or update the instructor's profile.
function InstructorQueries.upsertProfile(user_uuid, namespace_id, input)
    local fields = {
        headline = input.headline,
        bio = input.bio,
        avatar_url = input.avatar_url,
        location = input.location,
        website = input.website,
    }
    for _, k in ipairs(JSON_OBJECT_FIELDS) do
        if input[k] ~= nil then
            fields[k] = type(input[k]) == "string" and input[k] or cjson.encode(input[k])
        end
    end
    for _, k in ipairs(JSON_ARRAY_FIELDS) do
        if input[k] ~= nil then
            fields[k] = type(input[k]) == "string" and input[k] or cjson.encode(input[k])
        end
    end

    local existing = ProfileModel:find({ user_uuid = user_uuid })
    if existing then
        fields.updated_at = db.raw("NOW()")
        existing:update(fields)
        return existing
    end
    fields.uuid = Global.generateUUID()
    fields.user_uuid = user_uuid
    fields.namespace_id = namespace_id
    fields.created_at = db.raw("NOW()")
    fields.updated_at = db.raw("NOW()")
    return ProfileModel:create(fields, { returning = "*" })
end

--- Public directory: every user who owns >=1 course in the namespace (any
--- status, so newly-onboarded instructors with only a draft still appear), with
--- basic profile bits + PUBLISHED-course stats. Empty accounts (no courses)
--- are excluded so the directory stays clean.
function InstructorQueries.listInstructors(namespace_id)
    local rows = db.query([[
        SELECT u.uuid AS user_uuid, u.username, u.first_name, u.last_name, u.email,
               p.headline, p.avatar_url, p.location,
               COUNT(c.id) FILTER (WHERE c.status = 'published') AS course_count,
               COALESCE(ROUND((AVG(NULLIF(c.rating, 0)) FILTER (WHERE c.status = 'published'))::numeric, 2), 0) AS avg_rating,
               COALESCE(SUM(c.rating_count) FILTER (WHERE c.status = 'published'), 0) AS total_reviews
        FROM academy_courses c
        JOIN users u ON u.uuid = c.owner_user_uuid
        LEFT JOIN academy_instructor_profiles p ON p.user_uuid = u.uuid
        WHERE c.namespace_id = ? AND c.deleted_at IS NULL
          AND c.owner_user_uuid IS NOT NULL
        GROUP BY u.uuid, u.username, u.first_name, u.last_name, u.email,
                 p.headline, p.avatar_url, p.location
        ORDER BY course_count DESC, u.first_name ASC
    ]], namespace_id) or {}

    local out = {}
    for _, r in ipairs(rows) do
        table.insert(out, {
            id = r.user_uuid,
            username = r.username,
            name = display_name(r),
            headline = r.headline,
            avatar_url = r.avatar_url,
            location = r.location,
            course_count = tonumber(r.course_count) or 0,
            rating = tonumber(r.avg_rating) or 0,
            review_count = tonumber(r.total_reviews) or 0,
        })
    end
    return out
end

--- A single instructor by username, scoped to the namespace. Returns nil unless
--- the user is a public instructor here: owns >=1 course (any status) OR has a
--- saved profile. (Their profile page lists only their PUBLISHED courses.)
function InstructorQueries.getByUsername(namespace_id, username)
    local users = db.query(
        "SELECT uuid, username, first_name, last_name, email FROM users WHERE username = ? LIMIT 1",
        username)
    local u = users and users[1]
    if not u then return nil end

    local cnt = db.query([[
        SELECT COUNT(*) AS c FROM academy_courses
        WHERE namespace_id = ? AND owner_user_uuid = ? AND deleted_at IS NULL
    ]], namespace_id, u.uuid)
    local has_course = cnt and cnt[1] and tonumber(cnt[1].c) > 0
    local has_profile = ProfileModel:find({ user_uuid = u.uuid }) ~= nil
    if not (has_course or has_profile) then return nil end

    local profile = shape_profile(ProfileModel:find({ user_uuid = u.uuid }))
    profile.id = u.uuid
    profile.username = u.username
    profile.name = display_name(u)
    return profile
end

--- Published courses owned by an instructor (for their profile page).
function InstructorQueries.coursesForOwner(namespace_id, owner_user_uuid)
    return db.query([[
        SELECT * FROM academy_courses
        WHERE namespace_id = ? AND owner_user_uuid = ? AND status = 'published' AND deleted_at IS NULL
        ORDER BY rating DESC NULLS LAST, title ASC
    ]], namespace_id, owner_user_uuid) or {}
end

return InstructorQueries
