--[[
    Small helpers shared by the lead pipeline modules (lib/crm/*).

    Errors: service functions return `nil, err` where
        err = { status = 4xx, code = "LEAD_...", message = "plain words", fields = { field = "message" }? }
    Routes turn that into the response (lib/crm/api.lua). Anything raised is
    unexpected and is logged by the route without echoing it.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local U = {}

function U.fail(status, code, message, fields)
    return nil, { status = status, code = code, message = message, fields = fields }
end

--- BEGIN/COMMIT around fn(). fn returns (result, err); a returned err or a
-- raised error rolls back. A raised error is re-raised after the rollback.
function U.tx(fn)
    db.query("BEGIN")
    local ok, res, err = pcall(fn)
    if not ok then
        pcall(db.query, "ROLLBACK")
        error(res, 0)
    end
    if err ~= nil then
        pcall(db.query, "ROLLBACK")
        return nil, err
    end
    db.query("COMMIT")
    return res
end

function U.one(sql, ...)
    return db.query(sql, ...)[1]
end

function U.null(v) return v == nil or v == db.NULL or v == cjson.null end

function U.nz(v)
    if U.null(v) then return nil end
    if type(v) == "string" then
        v = v:match("^%s*(.-)%s*$")
        if v == "" then return nil end
    end
    return v
end

function U.json(v, fallback)
    if type(v) == "table" then return v end
    if U.null(v) or v == "" then return fallback end
    local ok, t = pcall(cjson.decode, v)
    if ok and t ~= nil then return t end
    return fallback
end

--- JSON text for a value. An empty table that isn't marked as an array is an
-- object ("{}"): this codebase's cjson otherwise writes "[]".
function U.enc(v)
    if v == nil or (type(v) == "table" and next(v) == nil and getmetatable(v) ~= cjson.array_mt) then return "{}" end
    return cjson.encode(v)
end

--- SQL for "this jsonb column as an object" (a non-object, e.g. [] written by
-- older code, counts as {}), for `col || patch` merges.
function U.obj_sql(col)
    return "(CASE WHEN jsonb_typeof(" .. col .. ") = 'object' THEN " .. col .. " ELSE '{}'::jsonb END)"
end

function U.array(t)
    return setmetatable(t or {}, cjson.array_mt)
end

function U.is_uuid(v)
    return type(v) == "string" and v:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

--- Trim and cap a client string; nil when empty or not a string.
function U.text(v, max)
    if type(v) ~= "string" then return nil end
    v = v:match("^%s*(.-)%s*$")
    if v == "" then return nil end
    if max and #v > max then v = v:sub(1, max) end
    return v
end

--- An ISO date/time a client sent, checked by Postgres; returned as a UTC
-- ISO string ("2026-11-05T14:30:00Z"). nil when missing or invalid.
function U.timestamp(v)
    if type(v) ~= "string" or #v > 40 or not v:match("^%d%d%d%d%-%d%d%-%d%d") then return nil end
    local ok, rows = pcall(db.query,
        [[SELECT to_char(?::timestamptz AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t]], v)
    if not ok or not rows[1] then return nil end
    return rows[1].t
end

--- "YYYY-MM-DD" checked by Postgres, or nil.
function U.date(v)
    if type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d$") then return nil end
    local ok, rows = pcall(db.query, "SELECT ?::date::text AS d", v)
    if not ok or not rows[1] then return nil end
    return rows[1].d
end

--- A non-negative money amount (max 13 digits before the point), or nil.
function U.money(v)
    local n = tonumber(v)
    if not n or n ~= n or n < 0 or n >= 1e13 then return nil end
    return math.floor(n * 100 + 0.5) / 100
end

function U.has_table(name)
    return db.query("SELECT to_regclass(?) IS NOT NULL AS ok", name)[1].ok
end

-- The CRM tables (contacts, deals, activities) exist only where the CRM
-- feature is deployed; the lead pipeline works without them, minus calls,
-- meetings and conversion. Cached per worker.
local crm_cache
function U.crm()
    if crm_cache == nil then
        crm_cache = U.has_table("crm_activities") and U.has_table("crm_deals") and U.has_table("crm_contacts")
    end
    return crm_cache
end

-- crm_activities.activity_date is a timestamp WITHOUT time zone holding UTC:
-- convert explicitly in both directions, never through the session zone.
U.ACTIVITY_AT = "(a.activity_date AT TIME ZONE 'UTC')"
U.TO_ACTIVITY_DATE = "(?::timestamptz AT TIME ZONE 'UTC')"

function U.full_name(first, last)
    local n = ((U.nz(first) or "") .. " " .. (U.nz(last) or "")):match("^%s*(.-)%s*$")
    return n ~= "" and n or nil
end

return U
