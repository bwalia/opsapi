-- Small shared helpers for the property_deals plugin.
local cjson = require("cjson")
local db = require("lapis.db")

local U = {}

U.UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

function U.is_uuid(v)
    return type(v) == "string" and v:match(U.UUID) ~= nil
end

function U.one(sql, ...)
    return db.query(sql, ...)[1]
end

--- Run fn inside a transaction. Re-raises after rolling back. Nested calls use a
-- savepoint, so an inner U.tx neither commits the outer one early nor, when it
-- fails inside a pcall, leaves the outer one aborted.
function U.tx(fn)
    local depth = ngx.ctx.pd_tx or 0
    local sp = "pd_sp" .. depth
    db.query(depth == 0 and "BEGIN" or ("SAVEPOINT " .. sp))
    ngx.ctx.pd_tx = depth + 1
    local ok, a, b, c = pcall(fn)
    ngx.ctx.pd_tx = depth
    if ok then
        db.query(depth == 0 and "COMMIT" or ("RELEASE SAVEPOINT " .. sp))
        return a, b, c
    end
    db.query(depth == 0 and "ROLLBACK" or ("ROLLBACK TO SAVEPOINT " .. sp))
    error(a, 0)
end

--- jsonb values may come back as strings depending on the driver path.
function U.json(v)
    if type(v) == "string" then
        local ok, decoded = pcall(cjson.decode, v)
        if ok then return decoded end
    end
    return v
end

function U.array(t)
    return setmetatable(t or {}, cjson.array_mt)
end

--- page, per_page, offset from ?page=&per_page= (per_page 1..max, default `default`).
function U.page(params, default, max)
    local G = require("helper.global")
    local page = G.pageParam(params and params.page)
    local per_page = G.perPageParam(params and params.per_page, default, max)
    return page, per_page, (page - 1) * per_page
end

--- SQL for the distance in miles between a lat/lng column pair and a point (haversine:
-- plain SQL, no earthdistance extension needed).
function U.miles_sql(lat_col, lng_col, lat, lng)
    return string.format([[(7917.6 * asin(LEAST(1, sqrt(power(sin(radians(%s - %f) / 2), 2)
        + cos(radians(%f)) * cos(radians(%s)) * power(sin(radians(%s - %f) / 2), 2)))))]],
        lat_col, lat, lat, lat_col, lng_col, lng)
end

-- Windows-1252 bytes 0x80-0x9F (the rest of the high half is Latin-1).
local CP1252 = { [128] = 0x20AC, [130] = 0x201A, [131] = 0x0192, [132] = 0x201E, [133] = 0x2026, [134] = 0x2020,
    [135] = 0x2021, [136] = 0x02C6, [137] = 0x2030, [138] = 0x0160, [139] = 0x2039, [140] = 0x0152, [142] = 0x017D,
    [145] = 0x2018, [146] = 0x2019, [147] = 0x201C, [148] = 0x201D, [149] = 0x2022, [150] = 0x2013, [151] = 0x2014,
    [152] = 0x02DC, [153] = 0x2122, [154] = 0x0161, [155] = 0x203A, [156] = 0x0153, [158] = 0x017E, [159] = 0x0178 }

local function valid_utf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len, lo, hi = 0, 0x80, 0xBF
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3; lo = c == 0xE0 and 0xA0 or 0x80; hi = c == 0xED and 0x9F or 0xBF
        elseif c >= 0xF0 and c <= 0xF4 then len = 4; lo = c == 0xF0 and 0x90 or 0x80; hi = c == 0xF4 and 0x8F or 0xBF
        else return false end
        for k = 1, len - 1 do
            local b = s:byte(i + k)
            if not b or b < (k == 1 and lo or 0x80) or b > (k == 1 and hi or 0xBF) then return false end
        end
        i = i + len
    end
    return true
end

--- Text as valid UTF-8 without NUL bytes (Postgres refuses both). UTF-8 stays as it is; text in a
-- single-byte charset (declared, or not valid UTF-8) is read as Windows-1252, the superset of Latin-1.
function U.utf8(s, charset)
    if s == nil then return nil end
    s = tostring(s):gsub("%z", "")
    if not s:find("[\128-\255]") then return s end
    charset = tostring(charset or ""):lower()
    local single = charset:find("8859", 1, true) or charset:find("1252", 1, true) or charset:find("latin", 1, true)
    if not single and valid_utf8(s) then return s end
    return (s:gsub("[\128-\255]", function(ch)
        local cp = CP1252[ch:byte()] or ch:byte()
        if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end))
end

--- At most n bytes of a UTF-8 string, cut on a character boundary (n bytes <= n characters, so it
-- also fits VARCHAR(n)).
function U.cut(s, n)
    if s == nil or #s <= n then return s end
    local i = n
    while i > 0 and s:byte(i + 1) >= 0x80 and s:byte(i + 1) < 0xC0 do i = i - 1 end
    return s:sub(1, i)
end

--- A user-facing error carried through error(): { status, message, details }.
function U.fail(status, message, details)
    error({ pd_error = true, status = status, message = message, details = details }, 0)
end

--- Turn U.fail errors (and constraint violations) into the house error envelope.
function U.guard(fn)
    return function(self)
        local ok, res = pcall(fn, self)
        if ok then return res end
        if type(res) == "table" and res.pd_error then
            local message = res.message
            if (tonumber(res.status) or 500) >= 500 then
                -- A 5xx message may carry a provider's or the server's own text after "<what failed>: ".
                ngx.log(ngx.ERR, "[property_deals] ", tostring(message))
                message = tostring(message):match("^(.-):%s") or tostring(message)
            end
            return { status = res.status, json = { success = false, error = message, details = res.details } }
        end
        local msg = tostring(res):match(".*\n(ERROR:.*)$") or tostring(res)
        if msg:find("duplicate key value", 1, true) then
            return { status = 409, json = { success = false, error = "A record with these values already exists" } }
        end
        if msg:find("foreign key constraint", 1, true) then
            return { status = 422, json = { success = false, error = "A referenced record does not exist" } }
        end
        ngx.log(ngx.ERR, "[property_deals] ", tostring(res))
        error(res, 0)
    end
end

--- U.guard for a create route that also honours an Idempotency-Key header
-- (a client retrying after a lost response gets the first answer back).
function U.guard_create(fn)
    return U.guard(function(self)
        return require("helper.plugin-sdk").idempotent(self, function() return fn(self) end)
    end)
end

return U
