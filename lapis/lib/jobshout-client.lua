--[[
    JobShout client (core): a workspace's JobShout link is a namespace_ai_providers
    row with provider_type = 'jobshout', base_url = the API root (…/api/v1),
    username = a JobShout service user's email, secret = its password (sealed).

    JobShout has no API keys (gap map §6): we sign in, keep the 15-minute access
    token in the shared cache for 13 minutes, and sign in again when it expires
    or a call answers 401. Refresh tokens rotate, so we don't keep them.

      JobShout.ping(ns, row)                         sign in + list agents
      JobShout.agents(ns, row)                       GET /agents
      JobShout.launch(ns, row, { agent_id, project_id, values })   POST /tasks/launch (any 2xx)
      JobShout.run(ns, row, run_id)                  GET /task-runs/{id}
      JobShout.approvals(ns, row, status)            GET /approvals?status=
      JobShout.decide(ns, row, approval_id, decision, reason)   POST /approvals/{id}/decide
    Each returns data or nil, err, http_status.
]]

local http = require("resty.http")
local cjson = require("cjson.safe")

local JobShout = {}

local TOKEN_TTL = 13 * 60

local function cache() return ngx.shared and ngx.shared.cache end

local function base(row)
    return (row.base_url or ""):gsub("/+$", "")
end

local function request(row, method, path, body, token)
    local Providers = require("lib.ai-providers")
    local ok, err = Providers.url_ok(base(row))
    if not ok then return nil, err end
    local httpc = http.new()
    httpc:set_timeout(20000)
    local headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" }
    if token then headers["Authorization"] = "Bearer " .. token end
    local res, rerr = httpc:request_uri(base(row) .. path, {
        method = method, headers = headers, body = body and cjson.encode(body) or nil,
        ssl_verify = os.getenv("JOBSHOUT_TLS_VERIFY") ~= "false",
    })
    if not res then return nil, "JobShout unreachable: " .. tostring(rerr) end
    local data = cjson.decode(res.body or "")
    if res.status >= 300 then
        local msg = type(data) == "table" and data.error or res.body
        return nil, "JobShout HTTP " .. res.status .. ": " .. tostring(msg):sub(1, 200), res.status
    end
    return data == nil and {} or data, nil, res.status
end

local function token(ns, row, fresh)
    local c, key = cache(), "jobshout:token:" .. tostring(row.uuid)
    if c and not fresh then
        local t = c:get(key)
        if t then return t end
    end
    local password = require("lib.ai-providers").secret(row)
    if not password then return nil, "JobShout password is not set" end
    local data, err, status = request(row, "POST", "/auth/login", { email = row.username, password = password })
    if not data then return nil, err, status end
    local t = data.access_token or (type(data.tokens) == "table" and data.tokens.access_token)
    if not t then return nil, "JobShout login returned no access token" end
    if c then c:set(key, t, TOKEN_TTL) end
    return t
end

local function call(ns, row, method, path, body)
    local t, err, status = token(ns, row)
    if not t then return nil, err, status end
    local data, cerr, cstatus = request(row, method, path, body, t)
    if not data and cstatus == 401 then
        t, err, status = token(ns, row, true)
        if not t then return nil, err, status end
        data, cerr, cstatus = request(row, method, path, body, t)
    end
    return data, cerr, cstatus
end

function JobShout.agents(ns, row)
    local data, err, status = call(ns, row, "GET", "/agents")
    if not data then return nil, err, status end
    return type(data.data) == "table" and data.data or data
end

function JobShout.ping(ns, row)
    local agents, err = JobShout.agents(ns, row)
    if not agents then return nil, err end
    return { ok = true, agents = #agents }
end

function JobShout.launch(ns, row, req)
    return call(ns, row, "POST", "/tasks/launch", req)
end

function JobShout.run(ns, row, run_id)
    return call(ns, row, "GET", "/task-runs/" .. ngx.escape_uri(run_id))
end

function JobShout.approvals(ns, row, status)
    local data, err, code = call(ns, row, "GET", "/approvals" .. (status and ("?status=" .. ngx.escape_uri(status)) or ""))
    if not data then return nil, err, code end
    return type(data.data) == "table" and data.data or data
end

function JobShout.decide(ns, row, approval_id, decision, reason)
    return call(ns, row, "POST", "/approvals/" .. ngx.escape_uri(approval_id) .. "/decide",
        { decision = decision, reason = reason })
end

return JobShout
