--[[
    HTTP helpers for the lead pipeline routes (routes/crm-leads.lua,
    routes/crm-partners.lua). The house response shape:

        { success = true, data = ..., meta = ... }
        { success = false, error = "plain words", code = "LEAD_...", fields = { field = "message" } }

    Unexpected errors go through lib/errors (logged with a correlation id,
    never echoed back).
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local Api = {}

local BAD_JSON = {}

--- The JSON body as a table ({} when empty); BAD_JSON when it isn't JSON.
function Api.body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw or raw == "" then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then raw = f:read("*a"); f:close() end
        end
    end
    if not raw or raw == "" then return {} end
    local ok, data = pcall(cjson.decode, raw)
    if not ok or type(data) ~= "table" then return BAD_JSON end
    return data
end

function Api.ok(data, status, meta)
    return { status = status or 200, json = { success = true, data = data == nil and cjson.null or data, meta = meta } }
end

function Api.fail(err)
    err = type(err) == "table" and err or { status = 500, message = tostring(err) }
    return { status = err.status or 400, json = { success = false, error = err.message or "Request failed",
        code = err.code, fields = err.fields } }
end

function Api.denied(message)
    return Api.fail({ status = 403, code = "FORBIDDEN", message = message or "You don't have access to this lead" })
end

function Api.not_found(message)
    return Api.fail({ status = 404, code = "NOT_FOUND", message = message or "Lead not found" })
end

--- Wrap a handler: auth + namespace + permission (module.action), the JSON
-- body parsed into self.body (400 when it isn't JSON), and any raised error
-- turned into a safe 500.
function Api.handler(module, action, fn)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission(module, action, function(self)
        local body = Api.body()
        if body == BAD_JSON then
            return Api.fail({ status = 400, code = "BAD_JSON", message = "The request body isn't valid JSON" })
        end
        self.body = body
        local ok, res = pcall(fn, self)
        if ok then return res end
        return require("lib.errors").fromException(self, res)
    end))
end

--- Same, for public (no login) endpoints.
function Api.public(fn)
    return function(self)
        local body = Api.body()
        if body == BAD_JSON then
            return Api.fail({ status = 400, code = "BAD_JSON", message = "The request body isn't valid JSON" })
        end
        self.body = body
        local ok, res = pcall(fn, self)
        if ok then return res end
        return require("lib.errors").fromException(self, res)
    end
end

--- Return the service result as a response: (value) -> 200/201, (nil, err) -> err.
function Api.result(value, err, status)
    if value == nil then return Api.fail(err) end
    return Api.ok(value, status)
end

return Api
