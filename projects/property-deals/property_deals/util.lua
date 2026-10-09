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

--- Run fn inside a transaction. Re-raises after rolling back.
function U.tx(fn)
    db.query("BEGIN")
    local ok, a, b, c = pcall(fn)
    if ok then
        db.query("COMMIT")
        return a, b, c
    end
    db.query("ROLLBACK")
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
            return { status = res.status, json = { success = false, error = res.message, details = res.details } }
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

return U
