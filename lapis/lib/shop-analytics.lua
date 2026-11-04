-- luacheck: max line length 140
--[[
    Shop Analytics — pure helpers (no database)
    ============================================
    Date windows, comparison periods, chart buckets and rate maths for
    queries/ShopAnalyticsQueries.lua. Kept free of lapis.db so
    lapis/spec/shop-analytics_spec.lua can test every rule without Postgres.

    Dates are UK calendar days (Europe/London). A window is inclusive of both
    ends: from=2026-10-01, to=2026-10-31 is 31 days. The previous period is the
    same number of days immediately before it.
]]

local A = {}

A.TIMEZONE = "Europe/London"
A.DEFAULT_DAYS = 30
A.MAX_DAYS = 731 -- two years: enough for year-on-year, bounded for cost

-- Orders that took money and still hold it (shop-system.lua status set).
A.PAID_STATUSES = { "paid", "processing", "shipped", "delivered" }
-- Paid at some point, money since returned in full.
A.REFUNDED_STATUS = "refunded"

-- A cart is abandoned when it has items, was never paid for, and nobody has
-- touched it for this long (agreed definition: 24 hours).
A.ABANDON_HOURS = 24

-- Add-to-basket events are pruned after this many days (ShopInsightsQueries).
A.CART_EVENT_RETENTION_DAYS = 30

local function is_leap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end
local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- Parse "YYYY-MM-DD" into y, m, d. nil for anything else, including 2026-02-30.
function A.parse_date(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 then return nil end
    local max = MONTH_DAYS[m] + ((m == 2 and is_leap(y)) and 1 or 0)
    if d > max then return nil end
    return y, m, d
end

-- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm): exact,
-- no os.time, so no host time zone or DST can shift a day.
local function to_days(y, m, d)
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

function A.day_number(s)
    local y, m, d = A.parse_date(s)
    if not y then return nil end
    return to_days(y, m, d)
end

--- "YYYY-MM-DD" plus n days.
function A.add_days(s, n)
    local z = A.day_number(s)
    if not z then return nil end
    return from_days(z + n)
end

--- Inclusive day count from a to b (same day = 1).
function A.days_inclusive(a, b)
    local za, zb = A.day_number(a), A.day_number(b)
    if not za or not zb then return nil end
    return zb - za + 1
end

--- Chart bucket for a window length: daily up to a quarter, weekly up to a
-- year, monthly beyond. Keeps a chart between ~7 and ~100 points.
function A.bucket_for(days)
    if days <= 92 then return "day" end
    if days <= 366 then return "week" end
    return "month"
end

local BUCKETS = { day = true, week = true, month = true }

--- Resolve the reporting window from request params.
-- params: { from?, to?, days?, bucket? } (strings, as they arrive in a query string)
-- today:  "YYYY-MM-DD", today's UK date (from the database clock)
-- Returns window or nil, error message.
function A.window(params, today)
    params = params or {}
    if not A.parse_date(today) then return nil, "today must be YYYY-MM-DD" end
    local from, to = params.from, params.to
    if from == "" then from = nil end
    if to == "" then to = nil end
    if from ~= nil and not A.parse_date(from) then return nil, "from must be a date (YYYY-MM-DD)" end
    if to ~= nil and not A.parse_date(to) then return nil, "to must be a date (YYYY-MM-DD)" end

    to = to or today
    if A.day_number(to) > A.day_number(today) then to = today end
    if not from then
        local days = tonumber(params.days)
        if days then days = math.floor(days) end
        if not days or days < 1 then days = A.DEFAULT_DAYS end
        if days > A.MAX_DAYS then days = A.MAX_DAYS end
        from = A.add_days(to, -(days - 1))
    end
    local days = A.days_inclusive(from, to)
    if days < 1 then return nil, "from must be on or before to" end
    if days > A.MAX_DAYS then return nil, ("the window can be at most %d days"):format(A.MAX_DAYS) end

    local bucket = params.bucket
    if not BUCKETS[bucket] then bucket = A.bucket_for(days) end

    local prev_to = A.add_days(from, -1)
    return {
        from = from,
        to = to,
        to_exclusive = A.add_days(to, 1),
        days = days,
        bucket = bucket,
        timezone = A.TIMEZONE,
        includes_today = to == today,
        previous = {
            from = A.add_days(prev_to, -(days - 1)),
            to = prev_to,
            to_exclusive = from,
            days = days,
        },
    }
end

--- n / d rounded to 4 decimal places; nil when there is nothing to divide by
-- (the UI shows "—", never a misleading 0%).
function A.ratio(n, d)
    n, d = tonumber(n), tonumber(d)
    if not n or not d or d <= 0 then return nil end
    return math.floor(n / d * 10000 + 0.5) / 10000
end

--- Relative change from prev to cur (0.25 = +25%). nil when prev is 0 or missing.
function A.change(cur, prev)
    cur, prev = tonumber(cur), tonumber(prev)
    if not cur or not prev or prev == 0 then return nil end
    return math.floor((cur - prev) / math.abs(prev) * 10000 + 0.5) / 10000
end

--- Average in whole minor units (pence), rounded half up. nil when count is 0.
function A.average_minor(total, count)
    total, count = tonumber(total), tonumber(count)
    if not total or not count or count <= 0 then return nil end
    return math.floor(total / count + 0.5)
end

--- Number from a pgmoon value (bigint can arrive as a string). Default 0.
function A.num(v, default)
    local n = tonumber(v)
    if n == nil then return default == nil and 0 or default end
    return n
end

--- SQL list literal of fixed, trusted status strings: ('a','b').
function A.sql_list(values)
    local out = {}
    for _, v in ipairs(values) do
        assert(v:match("^[%w_]+$"), "status values must be plain words")
        out[#out + 1] = "'" .. v .. "'"
    end
    return "(" .. table.concat(out, ",") .. ")"
end

--- Tool names from the transcript suffix the shop writes after an assistant
-- reply: "...\n\n[tools: search_catalog, add_to_cart]". Mirrors the SQL used
-- for the tool breakdown; kept here so the parsing rule is tested.
function A.tools_from_content(content)
    if type(content) ~= "string" then return {} end
    local list = content:match("%[tools: ([^%]]+)%]%s*$")
    local out = {}
    if not list then return out end
    for name in list:gmatch("[^,]+") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then out[#out + 1] = name end
    end
    return out
end

--- Did the assistant actually answer? The shop writes "(no reply)" when the
-- model returned nothing (timeout, provider error), optionally followed by the
-- tools suffix.
function A.is_ai_reply(content)
    if type(content) ~= "string" then return false end
    local text = content:gsub("%[tools: [^%]]*%]%s*$", ""):match("^%s*(.-)%s*$")
    return text ~= "" and text:sub(1, 10) ~= "(no reply)"
end

--- A chat counts as completed when the AI replied AND it led somewhere:
-- contact details saved, a quote, an add-to-cart or an order (agreed definition).
function A.chat_completed(s)
    if not s.ai_replied then return false end
    return (s.contact_saved or s.quote or s.added_to_cart or s.order) and true or false
end

return A
