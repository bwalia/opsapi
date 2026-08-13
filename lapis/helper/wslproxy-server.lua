--[[
    WSL Proxy Renderer (template-driven)
    ====================================

    Turns opsapi `domains` rows into WSL Proxy config files matching the shape
    consumed by the wslproxy-register-domains.yml workflow and the edge control
    plane, for BOTH objects a working host needs:

      * server (vhost)  -> data/servers/<env>/host:<domain>.json
      * rule            -> data/rules/<env>/<rule_id>.json   (the backend)

    Previously only servers were rendered — the `rules` field just referenced a
    rule id that had to be hand-authored, so a synced domain never actually
    routed. This module now renders the rule too.

    SCALABILITY: the JSON shapes are TEMPLATES (plain strings with {{...}}
    placeholders), not hand-built Lua tables. Defaults live here; a namespace
    can override them from Sync Settings (dashboard). When wslproxy adds a
    field, edit the template DATA — no code change, no redeploy. Because we fill
    templates by string substitution (never a cjson decode->encode round-trip),
    the exact JSON shape is preserved — including `{}` vs `[]` for empty
    values — so the old `match_cases:[]`->`{}` fix-up hack is gone.

    Servers are rendered as STUBS (config_status:false, no nginx `config`
    block): the register workflow (ACTIVATE_CONFIG=true) compiles the config
    edge-side, exactly like the working beacon/*.workstation.co.uk hosts. That
    keeps opsapi's schema surface to the handful of fields it actually owns.
]]

local cjson = require("cjson")

local WslproxyServer = {}

-- ── Default templates ─────────────────────────────────────────────────────
-- String placeholders ("{{x}}") sit INSIDE the template's quotes and receive a
-- JSON-escaped string. Raw placeholders (arrays/booleans) sit OUTSIDE quotes
-- and receive a ready-made JSON fragment ({{listens_json}}, {{ssl_enabled}}…).

-- Default WSL Proxy SERVER (vhost) format. Placeholders are filled per-domain by
-- render_server(); everything else is a sensible static default. Runtime-only
-- fields the edge fills itself (nginx_status*, created_at) are neutral here so a
-- re-sync doesn't churn the file.
WslproxyServer.DEFAULT_SERVER_TEMPLATE = [[{
  "id": "host:{{server_name}}",
  "server_name": "{{server_name}}",
  "proxy_server_name": null,
  "root": "{{root}}",
  "index": "index.html",
  "access_log": "logs/access.log",
  "error_log": "logs/error.log",
  "proxy_pass": "http://localhost",
  "profile_id": "{{profile_id}}",
  "rules": "{{rules}}",
  "listens": {{listens_json}},
  "ssl_enabled": {{ssl_enabled}},
  "ssl_email": "{{ssl_email}}",
  "ssl_force_https": {{ssl_force_https}},
  "ssl_staging": {{ssl_staging}},
  "ssl_auto_renew": {{ssl_auto_renew}},
  "dns_record_type": "CNAME",
  "dns_cname_target": "pop1.diytaxreturn.co.uk",
  "waf_enabled": false,
  "cache_enabled": false,
  "varnish_enabled": false,
  "rate_limit_enabled": false,
  "cache_bypass_auth": false,
  "cache_docker_blobs": false,
  "cache_docker_blobs_ttl": "2592000",
  "cache_docker_manifests": false,
  "cache_docker_manifests_ttl": "3600",
  "cache_docker_serve_stale": false,
  "cache_docker_stale_ttl": "31536000",
  "proxy_timeouts": { "connect_timeout": "600", "send_timeout": "600", "read_timeout": "600" },
  "nginx_status_check": "",
  "nginx_status": "",
  "match_cases": {},
  "custom_headers": {},
  "config": "{{config}}",
  "config_status": false,
  "created_at": 0
}]]

-- Default WSL Proxy RULE format. The backend goes in redirect_uri (backends is
-- an empty object in this schema); servers_json is the list of server ids.
WslproxyServer.DEFAULT_RULE_TEMPLATE = [[{
  "id": "{{rule_id}}",
  "name": "{{rule_id}}",
  "profile_id": "{{profile_id}}",
  "priority": 1,
  "version": 1,
  "_schema_version": 2,
  "match": {
    "rules": {
      "path": "{{rule_path}}",
      "path_key": "starts_with",
      "jwt_token_validation": "equals",
      "client_ip_key": "equals",
      "country_key": "equals"
    },
    "response": {
      "message": "",
      "backends": {},
      "strip_path": false,
      "auto_redirect_https": false,
      "redirect_uri": "{{backend}}",
      "code": 305,
      "is_consul": false,
      "allow": true,
      "routing": { "mode": "least_conn" }
    }
  },
  "servers": {{servers_json}},
  "created_at": 0
}]]

-- ── small helpers ─────────────────────────────────────────────────────────

local function trim(s)
    if s == nil then return "" end
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Escape a value for insertion into a JSON string literal (the template
-- supplies the surrounding quotes).
local function json_escape(s)
    s = tostring(s == nil and "" or s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
    s = s:gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return s
end

local function bool(v, default)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    if v == "true" or v == "t" or v == 1 or v == "1" then return true end
    if v == "false" or v == "f" or v == 0 or v == "0" then return false end
    return default
end

local function bool_json(v, default)
    return bool(v, default) and "true" or "false"
end

-- opsapi-<domain-with-dashes>, a safe per-domain default rule id that will not
-- collide with hand-authored infra rules (e.g. opsapi-prod-default).
local function default_rule_id(domain_name)
    local slug = tostring(domain_name or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if slug == "" then slug = "domain" end
    return "opsapi-" .. slug
end

-- Build the listens JSON array from a comma-separated port list ("80,443").
local function listens_json(listen_ports)
    local out = {}
    for p in tostring(listen_ports or "80"):gmatch("[^,%s]+") do
        table.insert(out, { listen = p })
    end
    if #out == 0 then out = { { listen = "80" } } end
    return cjson.encode(out)
end

-- Fill {{placeholders}} from a precomputed var map (each value is already the
-- final JSON representation: escaped string body, or a raw JSON fragment).
-- Function replacement avoids Lua's % handling in gsub replacements. Any
-- placeholder without a var is left intact so validate() flags the mismatch.
local function fill(tpl, vars)
    return (tpl:gsub("{{([%w_]+)}}", function(key)
        local v = vars[key]
        if v == nil then return "{{" .. key .. "}}" end
        return v
    end))
end

-- Parse the filled template; returns (ok, err). Catches template/var mistakes
-- before anything is committed.
local function validate_json(s)
    local ok, decoded = pcall(cjson.decode, s)
    if not ok then return false, tostring(decoded) end
    if type(decoded) ~= "table" then return false, "not a JSON object" end
    return true
end

-- ── effective per-domain values ───────────────────────────────────────────

-- Rule id a domain's server references: explicit column > settings default >
-- a per-domain default (opsapi-<domain>). Per-domain default keeps each domain
-- self-contained and never clobbers a shared hand-authored rule.
function WslproxyServer.effective_rule_id(domain, opts)
    local rid = trim(domain.wslproxy_rule_id)
    if rid ~= "" then return rid end
    rid = trim(opts and opts.default_rule_id)
    if rid ~= "" then return rid end
    return default_rule_id(domain.domain_name)
end

-- Backend a rule points at: the domain's proxy_target > settings default.
local function effective_backend(domain, opts)
    local b = trim(domain.proxy_target)
    if b ~= "" then return b end
    return trim(opts and opts.default_backend)
end

-- ── renderers ──────────────────────────────────────────────────────────────

--- Render one domain row to a WSL Proxy server (vhost) JSON string.
-- @return string json, string filename, string env, string|nil err
function WslproxyServer.render_server(domain, env, opts)
    opts = opts or {}
    local name = domain.domain_name
    -- Template precedence: the domain's own chosen server template (resolved by
    -- the injected opts.resolve_template) > a sync-level server_template > the
    -- built-in default.
    local per_domain = opts.resolve_template and trim(domain.server_template_uuid or "") ~= ""
        and opts.resolve_template(domain.server_template_uuid, "domain_wslproxy") or nil
    local tpl = per_domain
        or (opts.server_template and trim(opts.server_template) ~= "" and opts.server_template)
        or WslproxyServer.DEFAULT_SERVER_TEMPLATE
    local vars = {
        server_name    = json_escape(name),
        root           = json_escape(domain.wslproxy_root or "/var/www/html"),
        profile_id     = json_escape(env),
        rules          = json_escape(WslproxyServer.effective_rule_id(domain, opts)),
        ssl_email      = json_escape(domain.ssl_email or ""),
        listens_json   = listens_json(domain.listen_ports),
        ssl_enabled     = bool_json(domain.ssl_enabled, true),
        ssl_force_https = bool_json(domain.ssl_force_https, true),
        ssl_staging     = bool_json(domain.ssl_staging, false),
        ssl_auto_renew  = bool_json(domain.ssl_auto_renew, true),
        -- Per-domain nginx config blob (base64); empty when the domain has none.
        config          = json_escape(domain.config or ""),
    }
    local json = fill(tpl, vars)
    local ok, err = validate_json(json)
    if not ok then return nil, "host:" .. name .. ".json", env, "invalid server JSON: " .. err end
    return json, "host:" .. name .. ".json", env
end

--- Render one rule JSON string.
-- @param rule_id string
-- @param backend string  backend address (host:port)
-- @param servers table   list of server ids ("host:<domain>") referencing it
-- @return string json, string filename, string|nil err
function WslproxyServer.render_rule(rule_id, backend, servers, env, opts, rule_path, rule_template_uuid)
    opts = opts or {}
    -- Precedence: the owning domain's chosen rule template > a sync-level
    -- rule_template > the built-in default.
    local per_domain = opts.resolve_template and trim(rule_template_uuid or "") ~= ""
        and opts.resolve_template(rule_template_uuid, "domain_rule") or nil
    local tpl = per_domain
        or (opts.rule_template and trim(opts.rule_template) ~= "" and opts.rule_template)
        or WslproxyServer.DEFAULT_RULE_TEMPLATE
    local path = trim(rule_path)
    if path == "" then path = "/" end
    local vars = {
        rule_id      = json_escape(rule_id),
        profile_id   = json_escape(env),
        backend      = json_escape(backend),
        rule_path    = json_escape(path),
        servers_json = cjson.encode(servers or {}),
    }
    local json = fill(tpl, vars)
    local ok, err = validate_json(json)
    if not ok then return nil, rule_id .. ".json", "invalid rule JSON: " .. err end
    return json, rule_id .. ".json"
end

-- ── repo paths ──────────────────────────────────────────────────────────────

function WslproxyServer.repo_path(env, filename, base)
    base = base or ".github/wslproxy/data"
    return base .. "/servers/" .. env .. "/" .. filename
end

function WslproxyServer.rule_repo_path(env, filename, base)
    base = base or ".github/wslproxy/data"
    return base .. "/rules/" .. env .. "/" .. filename
end

--- Path of the opsapi-managed-domains manifest. Deliberately OUTSIDE
--- servers/<env>/ (globbed as vhosts) so it is never treated as one.
function WslproxyServer.manifest_path(env)
    return ".github/wslproxy/opsapi/domains-" .. env .. ".json"
end

-- ── the sync builder ──────────────────────────────────────────────────────

--- Build every file to commit for a namespace's domains in one env: a server
--- stub per domain, a rule per distinct rule id (with a resolvable backend),
--- plus the opsapi-managed manifest.
-- @param domains table   list of domain rows
-- @param env string      environment/profile
-- @param data_base string|nil  data root (default .github/wslproxy/data)
-- @param opts table|nil  { server_template, rule_template, default_rule_id,
--                          default_backend, sync_rules (default true),
--                          resolve_template(uuid, type),
--                          -- Attached shared rules (a domain with wslproxy_rule_id):
--                          fetch_rule(rule_id) -> content, err       (canonical JSON from WSL Proxy)
--                          rule_exists_in_repo(path) -> bool, err     (skip if already committed) }
-- @return { files={{path,content}...}, rendered={{path,server_name,content}...},
--           count, rules_count, warnings={...}, skipped={{rule_id,path,reason}...} }
function WslproxyServer.build_sync_files(domains, env, data_base, opts)
    opts = opts or {}
    local sync_rules = opts.sync_rules ~= false -- default ON
    local files, rendered, manifest, warnings, skipped = {}, {}, {}, {}, {}
    -- rule_id -> { backend, servers = {server-id...}, attached }
    local rules = {}
    local rule_order = {}

    for _, d in ipairs(domains or {}) do
        if (d.environment or "prod") == env then
            local json, filename, _, serr = WslproxyServer.render_server(d, env, opts)
            if not json then
                table.insert(warnings, serr or ("could not render " .. tostring(d.domain_name)))
            else
                local path = WslproxyServer.repo_path(env, filename, data_base)
                table.insert(files, { path = path, content = json })
                table.insert(rendered, { path = path, server_name = d.domain_name, content = json })
                table.insert(manifest, { server_name = d.domain_name, target = d.proxy_target or "" })

                -- Accumulate the rule this server references. A domain with an
                -- explicit wslproxy_rule_id has ATTACHED a shared WSL Proxy rule
                -- (chosen from the live API) — that rule is fetched + reused, not
                -- generated. Any contributing domain marking it attached wins.
                local rid = WslproxyServer.effective_rule_id(d, opts)
                local attached = trim(d.wslproxy_rule_id) ~= ""
                if not rules[rid] then
                    rules[rid] = { backend = effective_backend(d, opts), servers = {},
                        path = trim(d.rule_path), rule_template_uuid = trim(d.rule_template_uuid or ""),
                        attached = attached }
                    table.insert(rule_order, rid)
                else
                    if attached then rules[rid].attached = true end
                    if trim(rules[rid].backend) == "" then
                        rules[rid].backend = effective_backend(d, opts)
                    end
                    if trim(rules[rid].path) == "" then
                        rules[rid].path = trim(d.rule_path)
                    end
                end
                table.insert(rules[rid].servers, "host:" .. d.domain_name)
            end
        end
    end

    local rules_count = 0
    if sync_rules then
        for _, rid in ipairs(rule_order) do
            local r = rules[rid]
            local rule_file_path = WslproxyServer.rule_repo_path(env, rid .. ".json", data_base)

            if r.attached and opts.fetch_rule then
                -- Attached shared rule: never generate it. Skip if it is already
                -- committed (don't overwrite a rule that may be owned elsewhere);
                -- otherwise fetch the canonical JSON from WSL Proxy and push it so
                -- the server's dependency exists.
                local present = false
                if opts.rule_exists_in_repo then
                    local exists, exerr = opts.rule_exists_in_repo(rule_file_path)
                    if exists == true then
                        present = true
                    elseif exists == nil and exerr then
                        -- Couldn't confirm: fall through and push the canonical
                        -- rule (safe — it IS the source of truth), but flag it.
                        table.insert(warnings, "rule '" .. rid .. "' existence check failed ("
                            .. tostring(exerr) .. "); pushing the WSL Proxy copy")
                    end
                end
                if present then
                    table.insert(skipped, { rule_id = rid, path = rule_file_path, reason = "already in repo" })
                else
                    local content, ferr = opts.fetch_rule(rid)
                    if content and content ~= "" then
                        table.insert(files, { path = rule_file_path, content = content })
                        table.insert(rendered, { path = rule_file_path,
                            server_name = "(rule from wslproxy) " .. rid, content = content })
                        rules_count = rules_count + 1
                    else
                        table.insert(warnings, "attached rule '" .. rid
                            .. "' could not be fetched from WSL Proxy (" .. tostring(ferr)
                            .. "); its server(s) will not route until it is present")
                    end
                end
            elseif trim(r.backend) == "" then
                table.insert(warnings, "rule '" .. rid .. "' skipped: no proxy_target/default_backend "
                    .. "— set one to generate its backend")
            else
                local json, filename, rerr = WslproxyServer.render_rule(rid, r.backend, r.servers, env, opts, r.path, r.rule_template_uuid)
                if not json then
                    table.insert(warnings, rerr or ("could not render rule " .. rid))
                else
                    local path = WslproxyServer.rule_repo_path(env, filename, data_base)
                    table.insert(files, { path = path, content = json })
                    table.insert(rendered, { path = path, server_name = "(rule) " .. rid, content = json })
                    rules_count = rules_count + 1
                end
            end
        end
    end

    if #manifest > 0 then
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

    return {
        files = files,
        rendered = rendered,
        count = #manifest,
        rules_count = rules_count,
        warnings = warnings,
        skipped = skipped, -- attached rules already present in the repo (not re-pushed)
    }
end

return WslproxyServer
