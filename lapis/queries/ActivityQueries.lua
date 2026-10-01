--[[
    Workspace activity (in-app view for workspace owners/admins)

    Everything is scoped to ONE namespace. Charts, totals and per-member counts
    come from user_activity_daily (a few rows per member per day), so they stay
    cheap however much raw activity a workspace has; only the activity log reads
    raw user_activity rows, through an index and keyset pagination.

    Deliberately not exposed here: sign-in IP addresses and login history. A
    login isn't tied to one workspace, and a member may belong to several, so
    that stays with platform admins (Grafana). Workspace admins see when members
    last signed in, and everything members did inside their workspace.
]]

local db = require("lapis.db")
local Global = require("helper.global")

local ActivityQueries = {}

local TODAY = "(NOW() AT TIME ZONE 'UTC')::date" -- rollup days are UTC days

local function iso(col)
    return ("to_char(%s AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')"):format(col)
end

local NAME = "NULLIF(trim(coalesce(u.first_name, '') || ' ' || coalesce(u.last_name, '')), '')"

--- Clamp a ?days= value to [1, retention].
function ActivityQueries.days(value, default)
    local max = require("lib.user-activity").ACTIVITY_RETENTION_DAYS
    local n = math.floor(tonumber(value) or default or 30)
    if n < 1 then return 1 end
    if n > max then return max end
    return n
end

--- Totals, a per-day series, most-used areas and most active members.
function ActivityQueries.summary(ns_id, days)
    local since = TODAY .. " - (?::int - 1)"
    local totals = db.query([[
        SELECT COUNT(DISTINCT user_uuid)::int AS active_members,
               COUNT(DISTINCT user_uuid) FILTER (WHERE day = ]] .. TODAY .. [[)::int AS active_today,
               COALESCE(SUM(changes), 0)::bigint AS changes,
               COALESCE(SUM(requests), 0)::bigint AS requests,
               COALESCE(SUM(errors), 0)::bigint AS errors
        FROM user_activity_daily WHERE namespace_id = ? AND day >= ]] .. since, ns_id, days)[1]
    totals.members = db.query([[
        SELECT COUNT(*)::int AS n FROM namespace_members WHERE namespace_id = ? AND status = 'active'
    ]], ns_id)[1].n

    local series = db.query([[
        SELECT to_char(d.day, 'YYYY-MM-DD') AS day,
               COUNT(DISTINCT a.user_uuid)::int AS active_members,
               COALESCE(SUM(a.changes), 0)::int AS changes,
               COALESCE(SUM(a.requests), 0)::int AS requests,
               COALESCE(SUM(a.errors), 0)::int AS errors
        FROM generate_series(]] .. since .. [[, ]] .. TODAY .. [[, interval '1 day') AS d(day)
        LEFT JOIN user_activity_daily a ON a.namespace_id = ? AND a.day = d.day::date
        GROUP BY d.day ORDER BY d.day
    ]], days, ns_id)

    local areas = db.query([[
        SELECT split_part(action, '.', 1) AS area,
               SUM(changes)::int AS changes, SUM(requests)::int AS requests
        FROM user_activity_daily WHERE namespace_id = ? AND day >= ]] .. since .. [[
        GROUP BY 1 ORDER BY SUM(requests) DESC, 1 LIMIT 50
    ]], ns_id, days)

    local top_members = db.query([[
        SELECT a.user_uuid, u.email, ]] .. NAME .. [[ AS name,
               SUM(a.changes)::int AS changes, SUM(a.requests)::int AS requests,
               ]] .. iso("MAX(a.last_at)") .. [[ AS last_active_at
        FROM user_activity_daily a LEFT JOIN users u ON u.uuid = a.user_uuid
        WHERE a.namespace_id = ? AND a.day >= ]] .. since .. [[
        GROUP BY a.user_uuid, u.email, u.first_name, u.last_name
        ORDER BY SUM(a.requests) DESC LIMIT 8
    ]], ns_id, days)

    return {
        days = days,
        totals = totals,
        series = series,
        areas = areas,
        top_members = top_members,
    }
end

local MEMBER_SORT = {
    last_login = "s.last_login_at DESC NULLS LAST, u.email",
    name = "lower(coalesce(" .. NAME .. ", u.email)), u.email",
}

--- Workspace members with sign-in stats and their activity in THIS workspace.
-- The page is chosen first (cheap columns only), then activity is looked up
-- for just those rows.
function ActivityQueries.members(ns_id, params)
    local page = Global.pageParam(params.page)
    local per_page = Global.perPageParam(params.per_page, 25, 100)
    local order = MEMBER_SORT[params.sort] or MEMBER_SORT.last_login

    local where, args = { "nm.namespace_id = ?" }, { ns_id }
    if type(params.search) == "string" and params.search ~= "" then
        local like = "%" .. params.search:sub(1, 100):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(u.email ILIKE ? OR u.first_name ILIKE ? OR u.last_name ILIKE ?)"
        args[#args + 1], args[#args + 2], args[#args + 3] = like, like, like
    end
    local filter = table.concat(where, " AND ")

    local total = db.query("SELECT COUNT(*)::int AS n FROM namespace_members nm JOIN users u ON u.id = nm.user_id "
        .. "WHERE " .. filter, unpack(args))[1].n

    args[#args + 1], args[#args + 2] = per_page, (page - 1) * per_page
    local rows = db.query([[
        WITH page AS (
            SELECT u.uuid AS user_uuid, u.email, ]] .. NAME .. [[ AS name, u.active, nm.status, nm.is_owner,
                   nm.namespace_id, ]] .. iso("nm.joined_at") .. [[ AS joined_at,
                   ]] .. iso("s.last_login_at") .. [[ AS last_login_at, s.last_login_method,
                   COALESCE(s.login_count, 0) AS login_count, COALESCE(s.failed_login_count, 0) AS failed_login_count,
                   ]] .. iso("s.last_seen_at") .. [[ AS last_seen_at,
                   row_number() OVER (ORDER BY ]] .. order .. [[) AS _rn
            FROM namespace_members nm
            JOIN users u ON u.id = nm.user_id
            LEFT JOIN user_login_stats s ON s.user_uuid = u.uuid
            WHERE ]] .. filter .. [[
            ORDER BY ]] .. order .. [[
            LIMIT ? OFFSET ?
        )
        SELECT p.*, ]] .. iso("act.last_at") .. [[ AS last_active_at,
               COALESCE(act.changes, 0)::int AS changes_30d, COALESCE(act.requests, 0)::int AS requests_30d
        FROM page p
        LEFT JOIN LATERAL (
            SELECT MAX(d.last_at) AS last_at,
                   SUM(d.changes) FILTER (WHERE d.day >= ]] .. TODAY .. [[ - 29) AS changes,
                   SUM(d.requests) FILTER (WHERE d.day >= ]] .. TODAY .. [[ - 29) AS requests
            FROM user_activity_daily d
            WHERE d.namespace_id = p.namespace_id AND d.user_uuid = p.user_uuid
        ) act ON true
        ORDER BY p._rn
    ]], unpack(args))
    for _, r in ipairs(rows) do r._rn, r.namespace_id = nil, nil end

    return rows, {
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.max(1, math.ceil(total / per_page)),
    }
end

local KINDS = {
    changes = "a.method NOT IN ('GET', 'HEAD')",
    errors = "a.status >= 400",
}

--- The activity log: newest first, keyset-paginated (`cursor` = the last row's
-- `cursor` from the previous page), so deep pages cost the same as the first.
function ActivityQueries.log(ns_id, params)
    local limit = Global.perPageParam(params.limit, 50, 200)
    local where = { "a.namespace_id = ?", "a.occurred_at >= NOW() - (?::int * interval '1 day')" }
    local args = { ns_id, ActivityQueries.days(params.days, 7) }

    if type(params.user_uuid) == "string" and params.user_uuid ~= "" then
        where[#where + 1] = "a.user_uuid = ?"
        args[#args + 1] = params.user_uuid
    end
    if type(params.area) == "string" and params.area:match("^[%w_%-]+$") then
        where[#where + 1] = "a.action LIKE ?"
        args[#args + 1] = params.area .. ".%"
    end
    if KINDS[params.kind] then where[#where + 1] = KINDS[params.kind] end
    if type(params.cursor) == "string" then
        local at, id = params.cursor:match("^(.+)~(%d+)$")
        if at then
            where[#where + 1] = "(a.occurred_at, a.id) < (?::timestamptz, ?::bigint)"
            args[#args + 1], args[#args + 2] = at, id
        end
    end
    args[#args + 1] = limit + 1

    local rows = db.query([[
        SELECT a.occurred_at::text || '~' || a.id AS cursor, ]] .. iso("a.occurred_at") .. [[ AS occurred_at,
               a.user_uuid, u.email, ]] .. NAME .. [[ AS name, a.via, a.method, a.route, a.action, a.entity_id,
               a.status, a.hits, a.duration_ms, a.ip, a.user_agent
        FROM user_activity a LEFT JOIN users u ON u.uuid = a.user_uuid
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY a.occurred_at DESC, a.id DESC
        LIMIT ?
    ]], unpack(args))

    local next_cursor
    if #rows > limit then
        rows[#rows] = nil
        next_cursor = rows[#rows].cursor
    end
    return rows, { next_cursor = next_cursor, limit = limit }
end

return ActivityQueries
