--[[
    Simpro API client
    =================

    Speaks Simpro's REST API as documented at developer.simprogroup.com:

        {base_url}/api/v1.0/companies/{companyID}/customers/
                                                /sites/
                                                /sites/{siteID}/assets/
                                                /customerAssets/{id}/serviceLevels/
                                                /customerAssets/{id}/testHistory/
                                                /jobs/
                                                /jobs/{jobID}/costCenters/
                                                /quotes/
                                                /invoices/
                                                /schedules/
                                                /employees/
                                                /licences/

    Auth is OAuth2 (client credentials or refresh token), Bearer on every call.
    Paging is `page` + `pageSize` (max 250), and a response's total is carried in
    the `Result-Total` header rather than the body.

    Three modes, set per connection:

      mock     Talks to the bundled mock build (helper/simpro-mock.lua). No
               network, no credentials — what the demo runs on.
      sandbox  A real Simpro build, reads and writes allowed.
      live     A real Simpro build. Writes are refused unless the connection has
               push_enabled, so pointing the demo at production cannot modify it
               by accident.

    Credentials never live in the connection row. `credentials_vault_key` names a
    namespace vault secret holding {client_id, client_secret, refresh_token}, so
    a database dump carries no Simpro keys.
]]

local cjson = require("cjson")
local http = require("resty.http")

local SimproClient = {}
SimproClient.__index = SimproClient

-- Simpro caps pageSize at 250. Requesting more is a 400, not a clamp.
local MAX_PAGE_SIZE = 250
local DEFAULT_TIMEOUT_MS = 20000

--- Build a client from a simpro_connections row.
-- @param connection table the row
-- @param credentials table|nil {client_id, client_secret, refresh_token, access_token}
function SimproClient.new(connection, credentials)
    return setmetatable({
        connection = connection or {},
        credentials = credentials or {},
        base_url = (connection and connection.base_url or ""):gsub("/+$", ""),
        company_id = connection and connection.company_id or "0",
        mode = connection and connection.mode or "mock",
        access_token = credentials and credentials.access_token,
    }, SimproClient)
end

function SimproClient:is_mock()
    return self.mode == "mock"
end

--- Writes are gated so a live build is read-only until explicitly opened up.
function SimproClient:can_write()
    if self.mode == "mock" or self.mode == "sandbox" then return true end
    return self.connection.push_enabled == true
end

function SimproClient:path(resource)
    return ("%s/api/v1.0/companies/%s/%s"):format(self.base_url, self.company_id,
        tostring(resource):gsub("^/+", ""))
end

--- Exchange the stored refresh token for an access token.
--- Simpro tokens are short-lived, so this is called per sync run rather than
--- cached across requests — an OpenResty worker is not a safe place to hold one.
function SimproClient:authenticate()
    if self:is_mock() then
        self.access_token = "mock-token"
        return true
    end
    if self.access_token then return true end

    local c = self.credentials
    if not (c.client_id and c.client_secret) then
        return nil, "Simpro credentials are not configured for this workspace"
    end

    local body = {
        "grant_type=" .. (c.refresh_token and "refresh_token" or "client_credentials"),
        "client_id=" .. ngx.escape_uri(c.client_id),
        "client_secret=" .. ngx.escape_uri(c.client_secret),
    }
    if c.refresh_token then
        table.insert(body, "refresh_token=" .. ngx.escape_uri(c.refresh_token))
    end

    local httpc = http.new()
    httpc:set_timeout(DEFAULT_TIMEOUT_MS)
    local res, err = httpc:request_uri(self.base_url .. "/oauth2/token", {
        method = "POST",
        body = table.concat(body, "&"),
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        ssl_verify = true,
    })

    if not res then return nil, "Simpro auth failed: " .. tostring(err) end
    if res.status ~= 200 then
        -- Never echo the body: it can contain the client secret we just sent.
        return nil, ("Simpro auth rejected (HTTP %d)"):format(res.status)
    end

    local ok, decoded = pcall(cjson.decode, res.body)
    if not ok or not decoded.access_token then
        return nil, "Simpro auth returned no access token"
    end

    self.access_token = decoded.access_token
    return true
end

--- Issue one request. Returns (body_table, meta) or (nil, err, status).
-- meta carries { status, total } so a caller can page without re-reading headers.
function SimproClient:request(method, resource, opts)
    opts = opts or {}

    if method ~= "GET" and not self:can_write() then
        return nil, ("Simpro connection is in %s mode with pushes disabled"):format(self.mode)
    end

    if self:is_mock() then
        local Mock = require("helper.simpro-mock")
        return Mock.handle(self, method, resource, opts)
    end

    local ok, err = self:authenticate()
    if not ok then return nil, err end

    local url = self:path(resource)
    if opts.query and next(opts.query) then
        local parts = {}
        for k, v in pairs(opts.query) do
            table.insert(parts, ngx.escape_uri(k) .. "=" .. ngx.escape_uri(tostring(v)))
        end
        url = url .. "?" .. table.concat(parts, "&")
    end

    local httpc = http.new()
    httpc:set_timeout(opts.timeout_ms or DEFAULT_TIMEOUT_MS)

    local res, req_err = httpc:request_uri(url, {
        method = method,
        body = opts.body and cjson.encode(opts.body) or nil,
        headers = {
            ["Authorization"] = "Bearer " .. self.access_token,
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        },
        ssl_verify = true,
    })

    if not res then return nil, "Simpro request failed: " .. tostring(req_err) end

    if res.status >= 400 then
        local message = ("Simpro %s %s returned HTTP %d"):format(method, resource, res.status)
        -- Simpro puts a human-readable reason in the body; include it, truncated,
        -- because it is the difference between a usable error and a shrug.
        if res.body and #res.body > 0 then
            message = message .. ": " .. res.body:sub(1, 400)
        end
        return nil, message, res.status
    end

    local body
    if res.body and res.body ~= "" then
        local decoded_ok, decoded = pcall(cjson.decode, res.body)
        body = decoded_ok and decoded or nil
    end

    return body or {}, {
        status = res.status,
        total = tonumber(res.headers and res.headers["Result-Total"]),
    }
end

function SimproClient:get(resource, query)
    return self:request("GET", resource, { query = query })
end

function SimproClient:post(resource, body)
    return self:request("POST", resource, { body = body })
end

function SimproClient:patch(resource, body)
    return self:request("PATCH", resource, { body = body })
end

--- Walk every page of a collection. Bounded by max_pages so a misconfigured
--- filter against a 200-site portfolio cannot spin forever inside one request.
function SimproClient:list_all(resource, query, max_pages)
    query = query or {}
    query.pageSize = math.min(tonumber(query.pageSize) or MAX_PAGE_SIZE, MAX_PAGE_SIZE)
    max_pages = max_pages or 40

    local all, page = {}, 1
    while page <= max_pages do
        query.page = page
        local rows, meta = self:get(resource, query)
        if not rows then return nil, meta end
        if type(rows) ~= "table" or #rows == 0 then break end
        for _, r in ipairs(rows) do table.insert(all, r) end
        if #rows < query.pageSize then break end
        page = page + 1
    end
    return all
end

--- Connectivity check used by the dashboard's "Test connection" button.
function SimproClient:ping()
    local info, err = self:get("")
    if not info then return nil, err end
    return {
        mode = self.mode,
        company_id = self.company_id,
        base_url = self.base_url,
        company = info.Name or info.CompanyName,
    }
end

SimproClient.MAX_PAGE_SIZE = MAX_PAGE_SIZE

return SimproClient
