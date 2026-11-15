-- luacheck: max line length 140
--[[
    Delivery change requests: the rules (pure Lua, no DB, no ngx)
    ==============================================================
    A signed-in customer asks to change where and when an order is delivered. Nothing changes on the
    order until staff approve it (queries/ShopDeliveryChangeQueries.lua does the storage and the alerts).
    Unit-tested in spec/shop-delivery-change_spec.lua.

      clean_line(v, max)         one line of text: control and bidi characters removed, spaces collapsed,
                                 invalid UTF-8 dropped, capped at max characters; nil when blank
      clean_note(v, max)         the same but keeps line breaks (at most one blank line in a row)
      normalise_postcode(s)      "sw1a1aa" → "SW1A 1AA"; nil unless it looks like a UK postcode
      uk_country(v)              "GB" for blank / GB / UK / United Kingdom / England …; nil otherwise
      clean_address(a)           (address) | (nil, { field, message })
      check_date(s, today)       (YYYY-MM-DD) | (nil, message): a weekday from the next working day
                                 after today up to MAX_DAYS_AHEAD days ahead
      date_range(today)          earliest, latest (YYYY-MM-DD) a customer may ask for
      validate(body, today)      (request) | (nil, { field, message })
      same_address(a, b)         true when the two addresses are the same, ignoring case and spacing
      order_open(status)         may a customer still ask to change this order's delivery?
      describe_address(a)        one line for staff alerts and notes
      window_label(w), date_label(s)
]]

local M = {}

M.MAX_DAYS_AHEAD = 90
M.MAX_PER_DAY = 5 -- requests per order in any 24 hours (cancelled ones count too)
M.NOTE_MAX = 1000

--- Time windows a customer can ask for. Staff confirm what the courier can actually do.
M.WINDOWS = { all_day = "Any time", am = "Morning", pm = "Afternoon" }
M.WINDOW_ORDER = { "all_day", "am", "pm" }

--- Order statuses where the customer may still ask (not yet shipped, not closed).
M.OPEN_STATUSES = { pending_payment = true, paid = true, processing = true }

M.STATUSES = { pending = true, approved = true, declined = true, cancelled = true }

M.ADDRESS_KEYS = { "name", "company", "line1", "line2", "city", "county", "postcode", "country", "phone", "email" }
local FIELD_MAX = { name = 120, company = 120, line1 = 120, line2 = 120, city = 80, county = 80, phone = 32, email = 254 }
local REQUIRED = { name = "Enter the name of the person receiving the delivery", line1 = "Enter the first line of the address",
                   city = "Enter the town or city", postcode = "Enter the postcode" }

function M.order_open(status)
    return M.OPEN_STATUSES[status] == true
end

-- ---------------------------------------------------------------------------
-- text
-- ---------------------------------------------------------------------------

--- Valid UTF-8 characters of s, in order (invalid bytes dropped).
local function utf8_chars(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        local len = (c < 0x80 and 1) or (c >= 0xC2 and c <= 0xDF and 2) or (c >= 0xE0 and c <= 0xEF and 3)
            or (c >= 0xF0 and c <= 0xF4 and 4) or 0
        local ok = len > 0 and i + len - 1 <= n
        if ok then
            for j = i + 1, i + len - 1 do
                local b = s:byte(j)
                if b < 0x80 or b > 0xBF then ok = false break end
            end
        end
        if ok then
            out[#out + 1] = s:sub(i, i + len - 1)
            i = i + len
        else
            i = i + 1
        end
    end
    return out
end

--- Characters a customer never needs in an address or a note: C0/C1 controls (except \n where kept),
-- DEL, and the Unicode bidi overrides/isolates (U+202A–U+202E, U+2066–U+2069) used to disguise text.
local function bad_char(ch, keep_newline)
    if #ch == 1 then
        local b = ch:byte()
        if b == 10 and keep_newline then return false end
        return b < 32 or b == 127
    end
    if #ch == 2 then
        local b2 = ch:byte(2)
        return ch:byte(1) == 0xC2 and b2 >= 0x80 and b2 <= 0x9F
    end
    if #ch == 3 and ch:byte(1) == 0xE2 then
        local b2, b3 = ch:byte(2), ch:byte(3)
        if b2 == 0x80 and b3 >= 0xAA and b3 <= 0xAE then return true end
        if b2 == 0x81 and b3 >= 0xA6 and b3 <= 0xA9 then return true end
    end
    return false
end

local function clean(v, max, keep_newline)
    if type(v) == "number" then v = tostring(v) end
    if type(v) ~= "string" then return nil end
    local kept = {}
    for _, ch in ipairs(utf8_chars(v)) do
        if ch == "\t" or ch == "\r" then
            kept[#kept + 1] = keep_newline and ch == "\r" and "" or " "
        elseif bad_char(ch, keep_newline) then
            kept[#kept + 1] = keep_newline and "" or " "
        else
            kept[#kept + 1] = ch
        end
    end
    local s = table.concat(kept)
    if keep_newline then
        s = s:gsub("[ ]+", " "):gsub(" ?\n ?", "\n"):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    else
        s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    end
    if s == "" then return nil end
    local chars = utf8_chars(s)
    if #chars > max then
        s = table.concat(chars, "", 1, max):gsub("%s+$", "")
    end
    return s
end

function M.clean_line(v, max)
    return clean(v, max or 200, false)
end

function M.clean_note(v, max)
    return clean(v, max or M.NOTE_MAX, true)
end

-- ---------------------------------------------------------------------------
-- address
-- ---------------------------------------------------------------------------

--- UK postcode, normalised with its single space, or nil. Outward code A9, A99, AA9, AA99, A9A or AA9A;
-- inward code 9AA. GIR 0AA is the one historic exception.
function M.normalise_postcode(s)
    if type(s) ~= "string" then return nil end
    local c = s:upper():gsub("%s+", "")
    if c == "GIR0AA" then return "GIR 0AA" end
    if #c < 5 or #c > 7 then return nil end
    local out, inw = c:sub(1, -4), c:sub(-3)
    if not inw:match("^%d[A-Z][A-Z]$") then return nil end
    for _, p in ipairs({ "^[A-Z]%d$", "^[A-Z]%d%d$", "^[A-Z][A-Z]%d$", "^[A-Z][A-Z]%d%d$", "^[A-Z]%d[A-Z]$",
                         "^[A-Z][A-Z]%d[A-Z]$" }) do
        if out:match(p) then return out .. " " .. inw end
    end
    return nil
end

local UK_NAMES = {
    gb = true, uk = true, gbr = true, ["united kingdom"] = true, ["great britain"] = true, britain = true,
    england = true, scotland = true, wales = true, ["northern ireland"] = true,
    ["united kingdom of great britain and northern ireland"] = true,
}

--- "GB" when v names the UK (or is blank: the shop delivers within the UK), else nil.
function M.uk_country(v)
    local s = M.clean_line(v, 80)
    if not s then return "GB" end
    s = s:lower():gsub("%.", ""):gsub("^the ", "")
    return UK_NAMES[s] and "GB" or nil
end

local function valid_phone(p)
    if not p:match("^[%d%s%+%(%)%-%.]+$") then return false end
    local digits = select(2, p:gsub("%d", ""))
    return digits >= 7 and digits <= 15
end

--- (clean address) | (nil, { field, message }). Unknown keys are dropped; country is always "GB".
function M.clean_address(a)
    if type(a) ~= "table" then return nil, { field = "address", message = "Enter the delivery address" } end
    local out = {}
    for k, max in pairs(FIELD_MAX) do out[k] = M.clean_line(a[k], max) end
    for _, k in ipairs({ "name", "line1", "city" }) do
        if not out[k] then return nil, { field = k, message = REQUIRED[k] } end
    end
    local raw_pc = M.clean_line(a.postcode, 16)
    if not raw_pc then return nil, { field = "postcode", message = REQUIRED.postcode } end
    out.postcode = M.normalise_postcode(raw_pc)
    if not out.postcode then return nil, { field = "postcode", message = "Enter a valid UK postcode, e.g. SW1A 1AA" } end
    out.country = M.uk_country(a.country)
    if not out.country then
        return nil, { field = "country", message = "We can only change deliveries to UK addresses online. Please contact us." }
    end
    if out.phone and not valid_phone(out.phone) then
        return nil, { field = "phone", message = "Enter a valid phone number, or leave it blank" }
    end
    if out.email and not out.email:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
        return nil, { field = "email", message = "Enter a valid email address, or leave it blank" }
    end
    return out
end

local function norm(v)
    return (type(v) == "string" and v or ""):lower():gsub("%s+", "")
end

--- Same delivery address? Compares the address lines, postcode and recipient (not phone or email).
function M.same_address(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for _, k in ipairs({ "name", "company", "line1", "line2", "city", "county", "postcode" }) do
        if norm(a[k]) ~= norm(b[k]) then return false end
    end
    return true
end

--- Non-blank strings of parts joined by sep. parts may have holes (nil fields), so no ipairs.
local function join_nonempty(parts, sep)
    local out = {}
    local n = 0
    for k in pairs(parts) do
        if type(k) == "number" and k > n then n = k end
    end
    for i = 1, n do
        local p = parts[i]
        if type(p) == "string" and p:match("%S") then out[#out + 1] = p end
    end
    return table.concat(out, sep)
end

function M.describe_address(a)
    if type(a) ~= "table" then return "not set" end
    local s = join_nonempty({ a.name, a.company, a.line1, a.line2, a.city, a.county, a.postcode,
                              a.country ~= "GB" and a.country or nil }, ", ")
    if type(a.phone) == "string" and a.phone ~= "" then s = s .. " (tel " .. a.phone .. ")" end
    return s ~= "" and s or "not set"
end

-- ---------------------------------------------------------------------------
-- dates (civil-calendar arithmetic, no time zones: "today" comes from the database in Europe/London)
-- ---------------------------------------------------------------------------

local function days_from_civil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function civil_from_days(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return m <= 2 and y + 1 or y, m, d
end

local DIM = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- Day number (days since 1970-01-01) of a real YYYY-MM-DD date, else nil.
function M.parse_date(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or m < 1 or m > 12 or d < 1 then return nil end
    local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
    local max = (m == 2 and leap) and 29 or DIM[m]
    if d > max then return nil end
    return days_from_civil(y, m, d)
end

function M.format_date(days)
    local y, m, d = civil_from_days(days)
    return string.format("%04d-%02d-%02d", y, m, d)
end

--- 1 = Monday … 7 = Sunday (1970-01-01 was a Thursday).
function M.weekday(days)
    return (days + 3) % 7 + 1
end

local function next_working_day(days)
    repeat days = days + 1 until M.weekday(days) <= 5
    return days
end

--- Earliest and latest dates (YYYY-MM-DD) a customer may ask for, given today's date.
function M.date_range(today)
    local t = M.parse_date(today)
    if not t then return nil, nil end
    local latest = t + M.MAX_DAYS_AHEAD
    while M.weekday(latest) > 5 do latest = latest - 1 end
    return M.format_date(next_working_day(t)), M.format_date(latest)
end

function M.check_date(s, today)
    local d = M.parse_date(s)
    if not d then return nil, "Choose a valid date" end
    local t = M.parse_date(today)
    if not t then return nil, "Choose a valid date" end
    if M.weekday(d) > 5 then return nil, "We deliver on weekdays (Monday to Friday) only" end
    if d < next_working_day(t) then return nil, "Choose a date from the next working day onwards" end
    if d > t + M.MAX_DAYS_AHEAD then
        return nil, "Choose a date within the next " .. M.MAX_DAYS_AHEAD .. " days"
    end
    return M.format_date(d)
end

local DAY = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local MON = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- "Tue 18 Nov 2026", or "not set".
function M.date_label(s)
    local d = M.parse_date(s)
    if not d then return "not set" end
    local y, m, dd = civil_from_days(d)
    return DAY[M.weekday(d)] .. " " .. dd .. " " .. MON[m] .. " " .. y
end

function M.window_label(w)
    return M.WINDOWS[w] or "not set"
end

-- ---------------------------------------------------------------------------
-- the whole request
-- ---------------------------------------------------------------------------

--- body: { address = {…}, date? = "YYYY-MM-DD", window? = all_day|am|pm, note? }
-- → ({ address, date|nil, window|nil, note|nil }) | (nil, { field, message })
function M.validate(body, today)
    if type(body) ~= "table" then return nil, { field = "body", message = "Invalid request" } end
    local address, aerr = M.clean_address(body.address)
    if not address then return nil, aerr end
    local date
    local raw_date = body.date
    if raw_date ~= nil and raw_date ~= "" and type(raw_date) ~= "userdata" then
        local derr
        date, derr = M.check_date(raw_date, today)
        if not date then return nil, { field = "date", message = derr } end
    end
    local window
    local raw_window = body.window
    if raw_window ~= nil and raw_window ~= "" and type(raw_window) ~= "userdata" then
        if type(raw_window) ~= "string" or not M.WINDOWS[raw_window] then
            return nil, { field = "window", message = "Choose morning, afternoon or any time" }
        end
        window = raw_window
    end
    if date and not window then window = "all_day" end
    local note
    if body.note ~= nil and type(body.note) ~= "userdata" then
        if type(body.note) == "string" and #body.note > M.NOTE_MAX * 4 then
            return nil, { field = "note", message = "Keep the note under " .. M.NOTE_MAX .. " characters" }
        end
        note = M.clean_note(body.note, M.NOTE_MAX)
    end
    return { address = address, date = date, window = window, note = note }
end

--- Does the request change anything compared with what the order says now?
function M.changes_anything(req, current)
    current = current or {}
    if not M.same_address(req.address, current.address) then return true end
    if req.date and req.date ~= current.date then return true end
    if req.window and req.window ~= current.window then return true end
    return false
end

return M
