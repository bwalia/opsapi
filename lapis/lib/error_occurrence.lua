--[[
    Error-occurrence audit writer (Lua mirror of
    backend/app/errors/occurrences.py).

    Inserts one row per caught error into the same `error_occurrences`
    table the Python side writes to, so admins see Python and Lapis
    events in one unified view in /admin/errors.

    Sensitive fields are redacted here just like on the Python side:
    Authorization, Cookie, X-API-Key headers; password / token / NINO
    body fields. Never raises — a failed audit insert must not take
    down the request.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local Occurrence = {}

-- Headers we never want to persist in request_context. Match case-insensitively.
local SENSITIVE_HEADERS = {
    authorization = true,
    cookie = true,
    ["set-cookie"] = true,
    ["x-api-key"] = true,
    ["x-auth-token"] = true,
    ["x-access-token"] = true,
    ["proxy-authorization"] = true,
}

-- Body / query fields we never want to persist either. Matched on lowercased key.
local SENSITIVE_FIELDS = {
    password = true,
    new_password = true,
    current_password = true,
    token = true,
    access_token = true,
    refresh_token = true,
    client_secret = true,
    api_key = true,
    secret = true,
    nino = true,
    national_insurance_number = true,
}

local MAX_FIELD_LEN = 4096


local function truncate(value)
    if type(value) == "string" and #value > MAX_FIELD_LEN then
        return value:sub(1, MAX_FIELD_LEN) .. "…[truncated]"
    end
    return value
end


local function sanitise(tbl)
    if type(tbl) ~= "table" then return tbl end
    local out = {}
    for k, v in pairs(tbl) do
        local lkey = tostring(k):lower()
        if SENSITIVE_HEADERS[lkey] or SENSITIVE_FIELDS[lkey] then
            out[k] = "<redacted>"
        elseif type(v) == "table" then
            out[k] = sanitise(v)
        else
            out[k] = truncate(v)
        end
    end
    return out
end


--- Extract sanitised headers + query + path from a Lapis request.
local function build_request_context(self)
    if not self then return nil end

    local ctx = {}

    if self.req and self.req.headers then
        ctx.headers = sanitise(self.req.headers)
    end

    if self.params then
        -- Copy scalars only from params; nested uploads etc. are noisy.
        local query = {}
        for k, v in pairs(self.params) do
            if type(v) ~= "table" then
                query[k] = v
            end
        end
        if next(query) then
            ctx.query = sanitise(query)
        end
    end

    return next(ctx) and ctx or nil
end


local function client_ip(self)
    if not self or not self.req or not self.req.headers then
        return nil
    end
    local xff = self.req.headers["x-forwarded-for"] or self.req.headers["X-Forwarded-For"]
    if xff then
        local first = xff:match("^([^,]+)")
        if first then return first:match("^%s*(.-)%s*$") end
    end
    return ngx.var.remote_addr
end


--- Write one audit row. Never raises.
-- @param args table with keys:
--   code             string  catalog code (required)
--   catalog_uuid     string  uuid from message_catalog.uuid, or nil
--   correlation_id   string  per-request UUID (required)
--   http_status      number
--   raw_error        string  internal exception message
--   stack_trace      string  optional Lua traceback
--   endpoint         string  request path e.g. /auth/login
--   http_method      string
--   user_uuid        string  authenticated user UUID, or nil
--   tenant_namespace string
--   request_context  table   sanitised headers / query (auto-built if nil)
--   app_context      table   developer-attached extra context
--   user_agent       string
--   ip_address       string
--   self             table   Lapis request (used to auto-fill the above)
function Occurrence.record(args)
    local ok, err = pcall(function()
        local self = args.self

        local row = {
            uuid = require("helper.global").generateUUID(),
            code = args.code or "SYSTEM_500",
            catalog_uuid = args.catalog_uuid,
            correlation_id = args.correlation_id or require("helper.global").generateUUID(),
            raw_error = truncate(args.raw_error),
            stack_trace = truncate(args.stack_trace),
            endpoint = args.endpoint or (self and self.req and self.req.parsed_url and self.req.parsed_url.path),
            http_method = args.http_method or (self and self.req and self.req.method),
            http_status = tonumber(args.http_status),
            user_uuid = args.user_uuid,
            tenant_namespace = args.tenant_namespace,
            request_context = args.request_context or build_request_context(self),
            app_context = args.app_context,
            user_agent = args.user_agent or (self and self.req and self.req.headers
                and (self.req.headers["user-agent"] or self.req.headers["User-Agent"])),
            ip_address = args.ip_address or client_ip(self),
        }

        -- JSONB columns — use Lapis' db.interpolate_query so the cast is
        -- rendered exactly like every other JSONB insert in the codebase
        -- (see queries/AuditEventQueries.lua for the canonical pattern).
        if row.request_context then
            row.request_context = db.raw(db.interpolate_query("?::jsonb", cjson.encode(row.request_context)))
        end
        if row.app_context then
            row.app_context = db.raw(db.interpolate_query("?::jsonb", cjson.encode(row.app_context)))
        end

        -- Drop nil values before insert. Lapis will still try to insert
        -- them as ``NULL`` but that can confuse the INET column's implicit
        -- cast when ip_address is nil and the row has other fields set.
        local clean = {}
        for k, v in pairs(row) do
            if v ~= nil then clean[k] = v end
        end

        db.insert("error_occurrences", clean)
    end)

    if not ok then
        -- Logging a warning is as loud as we ever get. Failing audit must
        -- not surface to the user.
        ngx.log(ngx.WARN, "error_occurrence: insert failed: ", tostring(err))
    end
end


return Occurrence
