-- Shared helpers for the opsapi_marketing plugin.
local cjson = require("cjson")
local db = require("lapis.db")

local U = {}

U.UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
U.CHANNELS = { email = true, sms = true }
U.CHANNEL_ENUM = { "email", "sms" } -- request validation (fields `enum`)
U.MESSAGE_TYPES = { marketing = true, transactional = true, other = true }

function U.is_uuid(v)
    return type(v) == "string" and v:match(U.UUID) ~= nil
end

function U.one(sql, ...)
    return db.query(sql, ...)[1]
end

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

function U.lower(s)
    return type(s) == "string" and s:lower():match("^%s*(.-)%s*$") or s
end

function U.norm_email(s)
    local e = U.lower(s)
    if type(e) ~= "string" or not e:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then return nil end
    return e
end

function U.e164(phone)
    if type(phone) ~= "string" then return nil end
    local p = phone:gsub("[%s%-%(%)%.]", "")
    if p:match("^00%d+$") then p = "+" .. p:sub(3) end
    if p:match("^0%d%d%d%d%d%d%d%d%d%d?$") then p = "+44" .. p:sub(2) end
    return p:match("^%+%d%d%d%d%d%d%d+$") and p or nil
end

--- Ensure this plugin's package root is on package.path (api/jobs/events loaders).
function U.ensure_path(source_pattern)
    local info = debug.getinfo(2, "S")
    local root = info and info.source and info.source:match(source_pattern)
    if root and not package.path:find(root .. "/?.lua", 1, true) then
        package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
    end
    return root
end

function U.settings(ns)
    return require("helper.plugin-sdk").settings("opsapi_marketing", ns) or {}
end

function U.plugin_on(ns)
    return require("helper.plugin-workspaces").isEnabled("opsapi_marketing", ns)
end

function U.tx(fn)
    local depth = ngx.ctx.mkt_tx or 0
    local sp = "mkt_sp" .. depth
    db.query(depth == 0 and "BEGIN" or ("SAVEPOINT " .. sp))
    ngx.ctx.mkt_tx = depth + 1
    local ok, a, b, c = pcall(fn)
    ngx.ctx.mkt_tx = depth
    if ok then
        db.query(depth == 0 and "COMMIT" or ("RELEASE SAVEPOINT " .. sp))
        return a, b, c
    end
    db.query(depth == 0 and "ROLLBACK" or ("ROLLBACK TO SAVEPOINT " .. sp))
    error(a, 0)
end

function U.now_local_hhmm(ns)
    local s = U.settings(ns)
    local tz = s.timezone or "Europe/London"
    local ok, r = pcall(U.one, "SELECT to_char(NOW() AT TIME ZONE ?, 'HH24:MI') AS t", tz)
    return ok and r and r.t or "12:00"
end

--- Quiet hours spanning midnight (e.g. 21:00–08:00). Equal from/to = disabled.
function U.in_quiet_hours(ns, from_hhmm, to_hhmm)
    if type(from_hhmm) ~= "string" or type(to_hhmm) ~= "string" then return false end
    if from_hhmm == to_hhmm then return false end
    local now = U.now_local_hhmm(ns)
    if from_hhmm < to_hhmm then
        return now >= from_hhmm and now < to_hhmm
    end
    return now >= from_hhmm or now < to_hhmm
end

return U
