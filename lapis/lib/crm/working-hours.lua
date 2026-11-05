--[[
    Working-hours arithmetic for lead response times
    ================================================

    "Call within 60 minutes" means 60 working minutes: a lead at 17:20 on a
    Friday with a 09:00-17:30 Mon-Fri week is due at 09:50 on Monday.

    The arithmetic runs on local wall-clock time (pure, unit tested in
    spec/crm_working_hours_spec.lua); Postgres converts between the
    workspace's time zone and UTC (WH.due_at), so daylight saving is right.

    hours = { timezone = "Europe/London", start = "09:00", ["end"] = "17:30",
              days = { 1, 2, 3, 4, 5 } }   -- ISO days, 1 = Monday
]]

local WH = {}

WH.DEFAULT = { timezone = "Europe/London", start = "09:00", ["end"] = "17:30", days = { 1, 2, 3, 4, 5 } }

--- "HH:MM" -> minutes after midnight, or nil.
function WH.parse_hm(s)
    if type(s) ~= "string" then return nil end
    local h, m = s:match("^(%d%d?):(%d%d)$")
    h, m = tonumber(h), tonumber(m)
    if not h or h > 23 or m > 59 then return nil end
    return h * 60 + m
end

--- A validated copy of `hours` (falls back to the default per field), plus
-- start_min/end_min and a day set. Returns nil, message when it can't work.
function WH.normalise(hours)
    hours = type(hours) == "table" and hours or {}
    local start_s = hours.start or WH.DEFAULT.start
    local end_s = hours["end"] or WH.DEFAULT["end"]
    local s, e = WH.parse_hm(start_s), WH.parse_hm(end_s)
    if not s then return nil, "start must be HH:MM" end
    if not e then return nil, "end must be HH:MM" end
    if e <= s then return nil, "end must be after start" end
    local days, set = {}, {}
    local src = type(hours.days) == "table" and hours.days or WH.DEFAULT.days
    for _, d in ipairs(src) do
        d = tonumber(d)
        if d and d >= 1 and d <= 7 and d == math.floor(d) and not set[d] then
            set[d] = true
            days[#days + 1] = d
        end
    end
    if #days == 0 then return nil, "pick at least one working day" end
    table.sort(days)
    local tz = type(hours.timezone) == "string" and hours.timezone ~= "" and hours.timezone or WH.DEFAULT.timezone
    return { timezone = tz, start = start_s, ["end"] = end_s, days = days, start_min = s, end_min = e, day_set = set }
end

--- Add `minutes` working minutes to a local wall-clock moment.
-- @param dow ISO day of week of the start (1 = Monday)
-- @param minute_of_day minutes after local midnight at the start
-- @return day_offset, minute_of_day of the due moment (local wall clock)
function WH.add(h, dow, minute_of_day, minutes)
    local remaining = math.max(0, math.floor(tonumber(minutes) or 0))
    local offset, mod = 0, minute_of_day
    -- Bounded walk: at most ~2 weeks of days per 7-day schedule cycle.
    for _ = 1, 3700 do
        local d = ((dow - 1 + offset) % 7) + 1
        if h.day_set[d] then
            if mod < h.start_min then mod = h.start_min end
            if mod < h.end_min then
                local available = h.end_min - mod
                if remaining <= available then
                    return offset, mod + remaining
                end
                remaining = remaining - available
            end
        end
        offset, mod = offset + 1, 0
    end
    return offset, h.start_min
end

--- Is a local wall-clock moment inside working hours?
function WH.inside(h, dow, minute_of_day)
    return h.day_set[dow] == true and minute_of_day >= h.start_min and minute_of_day < h.end_min
end

--- The due time (an ISO string with offset, from Postgres) `minutes` working
-- minutes after now in the workspace's time zone. A bad time zone falls back
-- to UTC rather than failing the lead.
function WH.due_at(hours, minutes)
    local db = require("lapis.db")
    local h = WH.normalise(hours) or WH.normalise(WH.DEFAULT)
    local tz = h.timezone
    local ok, now = pcall(db.query, [[
        SELECT EXTRACT(ISODOW FROM NOW() AT TIME ZONE ?)::int AS dow,
               (EXTRACT(HOUR FROM NOW() AT TIME ZONE ?) * 60 + EXTRACT(MINUTE FROM NOW() AT TIME ZONE ?))::int AS mod,
               (NOW() AT TIME ZONE ?)::date AS d
    ]], tz, tz, tz, tz)
    if not ok then
        tz = "UTC"
        now = db.query([[
            SELECT EXTRACT(ISODOW FROM NOW() AT TIME ZONE 'UTC')::int AS dow,
                   (EXTRACT(HOUR FROM NOW() AT TIME ZONE 'UTC') * 60 + EXTRACT(MINUTE FROM NOW() AT TIME ZONE 'UTC'))::int AS mod,
                   (NOW() AT TIME ZONE 'UTC')::date AS d
        ]])
    end
    now = now[1]
    local offset, mod = WH.add(h, tonumber(now.dow), tonumber(now.mod), minutes)
    return db.query([[
        SELECT ((?::date + ?::int)::timestamp + make_interval(mins => ?) ) AT TIME ZONE ? AS due
    ]], now.d, offset, mod, tz)[1].due
end

return WH
