--[[
    WSL Proxy Server (vhost) Renderer
    =================================

    Turns an opsapi `domains` row into a WSL Proxy server-config file matching
    the shape consumed by diy-tax-return-uk's
    .github/wslproxy/data/servers/<env>/host:<domain>.json and the
    wslproxy-register-domains.yml workflow.

    The committed convention (verified against existing files):
      - `config` is a base64-encoded nginx server block
      - `config_status` is false (staged; the register workflow flips it live)
      - `rules` references a rule id in data/rules/<env>/
      - `id` and filename are `host:<server_name>`
]]

local cjson = require("cjson")

local WslproxyServer = {}

-- Base64-encode a plaintext nginx config (matches the committed import format).
local function b64(s)
    if ngx and ngx.encode_base64 then return ngx.encode_base64(s) end
    -- Fallback (non-nginx contexts) — should not be hit in the worker.
    local mime_ok, mime = pcall(require, "mime")
    if mime_ok then return (mime.b64(s)) end
    return s
end

-- Render the nginx server block for a domain (mirrors the existing template).
local function nginx_config(domain)
    local name = domain.domain_name
    local root = domain.wslproxy_root or "/var/www/html"
    local lines = {
        "server {",
        "      listen 80;  # Listen on port (HTTP)",
        "      server_name " .. name .. ";  # Your domain name",
        "      root " .. root .. ";  # Document root directory",
        "      index index.html;  # Default index files",
        "      access_log logs/" .. name .. ".access.log;  # Access log file location",
        "      error_log logs/" .. name .. ".error.log;  # Error log file location",
        "",
        "",
        "",
        "  }",
        "",
        "  ",
    }
    return table.concat(lines, "\n")
end

local function bool(v, default)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    if v == "true" or v == "t" or v == 1 or v == "1" then return true end
    if v == "false" or v == "f" or v == 0 or v == "0" then return false end
    return default
end

--- Build the listens array from a comma-separated port list ("80,443").
local function build_listens(listen_ports)
    local out = {}
    for p in tostring(listen_ports or "80"):gmatch("[^,%s]+") do
        table.insert(out, { listen = p })
    end
    if #out == 0 then out = { { listen = "80" } } end
    return out
end

--- Render a domain row to a WSL Proxy server config table.
-- @param domain table domains row (with wslproxy fields)
-- @return table { filename, env, id, content } where content is the Lua table
function WslproxyServer.render(domain)
    local name = domain.domain_name
    local env = domain.environment or "prod"
    local id = "host:" .. name

    local config = {
        id = id,
        server_name = name,
        proxy_server_name = name,
        profile_id = env,
        rules = domain.wslproxy_rule_id or "",
        config_status = false, -- staged; register workflow activates
        ssl_enabled = bool(domain.ssl_enabled, true),
        ssl_email = domain.ssl_email or "",
        ssl_auto_renew = bool(domain.ssl_auto_renew, true),
        ssl_force_https = bool(domain.ssl_force_https, true),
        ssl_staging = bool(domain.ssl_staging, false),
        cache_enabled = false,
        index = "index.html",
        root = domain.wslproxy_root or "/var/www/html",
        access_log = "logs/" .. name .. ".access.log",
        error_log = "logs/" .. name .. ".error.log",
        -- Empty Lua tables encode as {} objects (matching the committed files).
        custom_headers = {},
        match_cases = {},
        listens = build_listens(domain.listen_ports),
        config = b64(nginx_config(domain)),
    }

    return {
        filename = "host:" .. name .. ".json",
        env = env,
        id = id,
        content = config,
    }
end

-- opsapi's cjson encodes empty Lua tables as `[]`. The committed wslproxy files
-- use `{}` for custom_headers / match_cases — force those two back to objects.
-- Deterministic: only these two keys are ever empty tables in the payload.
function WslproxyServer.encode(content)
    local s = cjson.encode(content)
    s = s:gsub('"custom_headers":%[%]', '"custom_headers":{}')
    s = s:gsub('"match_cases":%[%]', '"match_cases":{}')
    return s
end

--- Convenience: render to a compact JSON string (wslproxy-faithful).
function WslproxyServer.render_json(domain)
    local rendered = WslproxyServer.render(domain)
    return WslproxyServer.encode(rendered.content), rendered.filename, rendered.env
end

--- Repo path (relative) for a rendered server file under a data root.
-- @param env string environment/profile
-- @param filename string host:<domain>.json
-- @param base string|nil data root (default .github/wslproxy/data)
function WslproxyServer.repo_path(env, filename, base)
    base = base or ".github/wslproxy/data"
    return base .. "/servers/" .. env .. "/" .. filename
end

--- Path of the opsapi-managed-domains manifest. Deliberately OUTSIDE
--- servers/<env>/ (which the register workflow globs as *.json) so it is never
--- treated as a vhost. The DNS reconcile reads this to scope reconciliation to
--- opsapi-managed domains only (never the hand-authored ones).
function WslproxyServer.manifest_path(env)
    return ".github/wslproxy/opsapi/domains-" .. env .. ".json"
end

--- Build the full set of files to commit for a namespace's domains in one env:
--- one server file per domain PLUS the opsapi-managed manifest.
-- @param domains table list of domain rows
-- @param env string environment
-- @param data_base string|nil server data root
-- @return { files = {{path,content}...}, rendered = {{path,server_name,content}...}, count }
function WslproxyServer.build_sync_files(domains, env, data_base)
    local files, rendered, manifest = {}, {}, {}
    for _, d in ipairs(domains or {}) do
        if (d.environment or "prod") == env then
            local r = WslproxyServer.render(d)
            local path = WslproxyServer.repo_path(env, r.filename, data_base)
            local content = WslproxyServer.encode(r.content)
            table.insert(files, { path = path, content = content })
            table.insert(rendered, { path = path, server_name = d.domain_name, content = content })
            table.insert(manifest, { server_name = d.domain_name, target = d.proxy_target or "" })
        end
    end
    if #files > 0 then
        local mpath = WslproxyServer.manifest_path(env)
        local mcontent = cjson.encode({
            environment = env,
            generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            count = #manifest,
            domains = manifest,
        })
        table.insert(files, { path = mpath, content = mcontent })
        table.insert(rendered, { path = mpath, server_name = "(opsapi manifest)", content = mcontent })
    end
    return { files = files, rendered = rendered, count = #manifest }
end

return WslproxyServer
