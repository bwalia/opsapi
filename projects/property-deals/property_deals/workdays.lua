-- Working-day maths with each workspace's holiday calendar (property_deals_holidays)
-- and time zone. Dates are 'YYYY-MM-DD' strings; instants are converted by Postgres
-- (it has the time-zone database, Lua doesn't).
local db = require("lapis.db")

local W = {}

-- 'YYYY-MM-DD' <-> days since 1970-01-01 (proleptic Gregorian, H. Hinnant's
-- algorithm): pure arithmetic, independent of the server's time zone.
local function to_days(date)
    local y, m, d = tostring(date):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    assert(y, "bad date " .. tostring(date))
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function from_days(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return string.format("%04d-%02d-%02d", y, m, d)
end

local function weekday(n) -- 1 = Monday ... 7 = Sunday (1970-01-01 was a Thursday)
    return (n + 3) % 7 + 1
end

W._to_days, W._from_days, W._weekday = to_days, from_days, weekday

--- A calendar for one workspace: { tz, holidays = set of dates }.
function W.calendar(ns, settings)
    settings = settings or {}
    local jurisdiction = settings.jurisdiction or "england-and-wales"
    local set = {}
    for _, h in ipairs(db.query([[
        SELECT holiday_date::text AS d FROM property_deals_holidays WHERE namespace_id = ? AND jurisdiction = ?
    ]], ns, jurisdiction)) do
        set[h.d] = true
    end
    return { tz = settings.timezone or "Europe/London", holidays = set, due_time = settings.due_time or "17:00" }
end

function W.is_working_day(cal, date)
    local n = to_days(date)
    return weekday(n) <= 5 and not cal.holidays[from_days(n)]
end

--- `n` working days after `date` (before it when n < 0). n = 0 gives `date`
-- itself when it is a working day, else the previous working day (a deadline
-- that falls on a weekend has to be met before it).
function W.add(cal, date, n)
    local d = to_days(date)
    if n == 0 then
        while not W.is_working_day(cal, from_days(d)) do d = d - 1 end
        return from_days(d)
    end
    local step = n > 0 and 1 or -1
    local left = math.abs(n)
    while left > 0 do
        d = d + step
        if W.is_working_day(cal, from_days(d)) then left = left - 1 end
    end
    return from_days(d)
end

--- Working days from `a` to `b`: how many working days come after a, up to and
-- including b. Negative when b is before a.
function W.between(cal, a, b)
    local da, dbb = to_days(a), to_days(b)
    if da == dbb then return 0 end
    local step = dbb > da and 1 or -1
    local count = 0
    local d = da
    while d ~= dbb do
        d = d + step
        if W.is_working_day(cal, from_days(d)) then count = count + step end
    end
    return count
end

--- Calendar days from a to b (b - a).
function W.days(a, b)
    return to_days(b) - to_days(a)
end

--- Today's date in the workspace's time zone.
function W.today(cal)
    return db.query("SELECT (NOW() AT TIME ZONE ?)::date::text AS d", cal.tz)[1].d
end

--- The local date of an instant (ISO timestamp string from the database).
function W.local_date(cal, ts)
    return db.query("SELECT (?::timestamptz AT TIME ZONE ?)::date::text AS d", ts, cal.tz)[1].d
end

--- UTC instant (ISO string) for a local date + 'HH:MM' in the workspace's zone.
function W.at(cal, date, hhmm)
    return db.query([[
        SELECT to_char((?::date + ?::time) AT TIME ZONE ? AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t
    ]], date, hhmm or cal.due_time, cal.tz)[1].t
end

--- Instant `ts` moved by n working days, keeping its local time of day.
function W.add_to_instant(cal, ts, n)
    local row = db.query([[
        SELECT (?::timestamptz AT TIME ZONE ?)::date::text AS d,
               to_char(?::timestamptz AT TIME ZONE ?, 'HH24:MI:SS') AS t
    ]], ts, cal.tz, ts, cal.tz)[1]
    return W.at(cal, W.add(cal, row.d, n), row.t)
end

--- ISO instant plus minutes.
function W.plus_minutes(ts, minutes)
    return db.query([[
        SELECT to_char((?::timestamptz + make_interval(mins => ?)) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t
    ]], ts, math.floor(minutes))[1].t
end

function W.now()
    return db.query([[SELECT to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t]])[1].t
end

return W
