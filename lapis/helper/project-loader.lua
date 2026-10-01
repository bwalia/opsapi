--[[
  Plugin (project) loader
  =======================

  A plugin is a folder under $OPSAPI_PROJECTS_DIR (default /app/projects):

    <plugin>/project.lua        manifest: code, name, version, sdk_version, modules
    <plugin>/api/*.lua          route files: `return function(app) ... end`
    <plugin>/migrations/*.lua   run by helper.project-migrator on `lapis migrate`
    <plugin>/events/*.lua       event handlers (helper.plugin-events)
    <plugin>/jobs/*.lua         scheduled jobs (helper.plugin-jobs)
    <plugin>/ui/                custom dashboard pages (manifest `pages`), served
                                at /plugin-ui/<code>/... and shown in a sandboxed
                                frame by the dashboard

  app.lua calls init() + loadRoutes() after every core route is registered.
  A plugin's routes are mounted under its api_prefix (/api/v2/<code-with-
  hyphens>), may not replace a route that already exists (core or another
  plugin), and its before_filters only run for its own prefix. Failures are
  recorded rather than swallowed: /ready answers 503 while any plugin failed
  to load (a broken plugin fails the rollout instead of silently 404-ing),
  and GET /api/v2/plugins lists them.

  Developer guide: PLUGINS.md. Stable helpers for plugin code: helper.plugin-sdk.
]]

local ProjectLoader = {}

-- Version of the helper.plugin-sdk API. Manifests declare the version they
-- target (sdk_version, default 1); a plugin written for a newer SDK than this
-- OpsAPI provides is refused instead of failing at request time.
ProjectLoader.SDK_VERSION = 1

local _registered = {}
local _registered_list = {}
local _failures = {}

local function logger(level)
    return function(...)
        if ngx and ngx.log then
            ngx.log(ngx[level], ...)
        else
            local parts = { ... }
            for i = 1, select("#", ...) do parts[i] = tostring(parts[i]) end
            print(table.concat(parts))
        end
    end
end
local notice, log_err = logger("NOTICE"), logger("ERR")

--- Sorted entries of a directory ({} if it doesn't exist). lfs isn't in the
-- image, so this falls back to ls; paths come from operator config, never
-- from requests.
function ProjectLoader.listDir(path)
    local out = {}
    local ok, lfs = pcall(require, "lfs")
    if ok then
        if lfs.attributes(path, "mode") ~= "directory" then return out end
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then out[#out + 1] = entry end
        end
    else
        local handle = io.popen("ls -1 '" .. (path:gsub("'", "'\\''")) .. "' 2>/dev/null")
        if handle then
            for line in handle:lines() do out[#out + 1] = line end
            handle:close()
        end
    end
    table.sort(out)
    return out
end

--- A file path under a plugin's ui/ folder, relative to it, or nil when it
-- could escape the folder (.., absolute, hidden files, odd characters).
function ProjectLoader.safeUiPath(rel)
    if type(rel) ~= "string" or rel == "" or #rel > 200 or not rel:match("^[%w_%-%./]+$") then return nil end
    for segment in rel:gmatch("[^/]+") do
        if segment:sub(1, 1) == "." then return nil end -- "..", ".env", ".git"
    end
    if rel:sub(1, 1) == "/" or rel:find("//", 1, true) or rel:sub(-1) == "/" then return nil end
    return rel
end

local function is_file(path)
    local f = io.open(path, "r")
    if f then f:close() end
    return f ~= nil
end

--- A plugin may not take a built-in feature's code: its RBAC modules and
-- feature flag would silently replace core's.
function ProjectLoader.isReservedCode(code)
    -- Event subscribers are "<code>.<file>"; "webhook.<uuid>" are workspace webhooks.
    if code == "webhook" or code == "core" then return true end
    local ok, ProjectConfig = pcall(require, "helper.project-config")
    if not ok then return false end
    return ProjectConfig.PROJECT_FEATURES[code] ~= nil
        or ProjectConfig.FEATURES[code:upper()] ~= nil
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

--- Plugin folders (those with a project.lua) under projects_root, by name.
-- @return table List of { dir_name, path, manifest_path }
function ProjectLoader.discover(projects_root)
    local found = {}
    for _, entry in ipairs(ProjectLoader.listDir(projects_root)) do
        local path = projects_root .. "/" .. entry
        if entry:sub(1, 1) ~= "." and is_file(path .. "/project.lua") then
            found[#found + 1] = { dir_name = entry, path = path, manifest_path = path .. "/project.lua" }
        end
    end
    return found
end

--- Load and validate a project.lua manifest.
-- @return table|nil manifest, string|nil error
function ProjectLoader.loadManifest(manifest_path, project_path)
    local chunk, err = loadfile(manifest_path)
    if not chunk then
        return nil, "Failed to load " .. manifest_path .. ": " .. tostring(err)
    end

    local ok, manifest = pcall(chunk)
    if not ok then
        return nil, "Failed to execute " .. manifest_path .. ": " .. tostring(manifest)
    end
    if type(manifest) ~= "table" then
        return nil, manifest_path .. " must return a table"
    end
    if type(manifest.code) ~= "string" then
        return nil, manifest_path .. " missing required field: code"
    end
    if type(manifest.name) ~= "string" then
        return nil, manifest_path .. " missing required field: name"
    end

    manifest.code = manifest.code:lower():gsub("-", "_")
    if not manifest.code:match("^[a-z][a-z0-9_]*$") then
        return nil, manifest_path .. ": code must start with a letter and use only letters, digits and _"
    end

    manifest.sdk_version = tonumber(manifest.sdk_version) or 1
    if manifest.sdk_version > ProjectLoader.SDK_VERSION then
        return nil, ("%s targets plugin SDK v%d but this OpsAPI provides v%d — upgrade OpsAPI"):format(
            manifest_path, manifest.sdk_version, ProjectLoader.SDK_VERSION)
    end

    manifest.modules = manifest.modules or {}
    local declared = {}
    for _, m in ipairs(manifest.modules) do
        if type(m) ~= "table" or type(m.machine_name) ~= "string"
            or not m.machine_name:match("^[a-z][a-z0-9_]*$") then
            return nil, manifest_path .. ": every modules entry needs a machine_name (lowercase letters, digits, _)"
        end
        declared[m.machine_name] = true
    end

    -- Custom dashboard pages: HTML (any framework) under ui/, shown by the
    -- dashboard in a sandboxed frame at /dashboard/plugins/<plugin>/<key>;
    -- they reach the API through the frame bridge (PLUGINS.md §6.2).
    --   { key = "overview", label = "Overview", entry = "ui/overview.html",
    --     module = "helpdesk_tickets",    -- needs <module>.read to open it
    --     api = { "/api/v2/customers" } } -- other APIs it may call (its own always)
    local pages = {}
    for _, pg in ipairs(manifest.pages or {}) do
        if type(pg) ~= "table" or type(pg.key) ~= "string" or not pg.key:match("^[a-z][a-z0-9_%-]*$")
            or type(pg.label) ~= "string" then
            return nil, manifest_path .. ": every pages entry needs a key (lowercase, - or _) and a label"
        end
        if pages[pg.key] then
            return nil, manifest_path .. ": page key '" .. pg.key .. "' is used twice"
        end
        if not ProjectLoader.safeUiPath(type(pg.entry) == "string" and pg.entry:match("^ui/(.+)$") or nil)
            or not pg.entry:match("%.html?$") then
            return nil, manifest_path .. ": page '" .. pg.key .. "' needs entry = \"ui/<file>.html\""
        end
        if not declared[pg.module] then
            return nil, manifest_path .. ": page '" .. pg.key .. "' needs module = one of the plugin's modules"
        end
        local api = {}
        for _, prefix in ipairs(pg.api or {}) do
            if type(prefix) ~= "string" or not prefix:match("^/api/[%w_%-/]*[%w_%-]$") then
                return nil, manifest_path .. ": page '" .. pg.key .. "': api entries look like \"/api/v2/customers\""
            end
            api[#api + 1] = prefix
        end
        pages[pg.key] = {
            key = pg.key, label = pg.label, entry = pg.entry, module = pg.module, api = api,
            description = type(pg.description) == "string" and pg.description or nil,
        }
    end
    manifest.pages = pages

    -- Dashboard sidebar entries, each opening the generated page of one
    -- sdk.crud resource or one custom page (/dashboard/plugins/<plugin>/<key>).
    manifest.menu = manifest.menu or {}
    for _, e in ipairs(manifest.menu) do
        local target = type(e) == "table" and (e.page or e.resource)
        if type(e) ~= "table" or type(e.label) ~= "string" or (e.page and e.resource)
            or type(target) ~= "string" or not target:match("^[%w_%-]+$") then
            return nil, manifest_path .. ": every menu entry needs a label and either a resource "
                .. "(the sdk.crud path without /) or a page (a pages key)"
        end
        if e.page and not pages[e.page] then
            return nil, manifest_path .. ": menu entry '" .. e.label .. "' links to page '" .. e.page
                .. "', which isn't in pages"
        end
        if not declared[e.module] then
            return nil, manifest_path .. ": menu entry '" .. e.label .. "' needs module = one of the plugin's modules"
        end
    end

    -- Tables whose changes this plugin publishes as events:
    --   ticket = "helpdesk_tickets"   → helpdesk.ticket.created / updated / deleted
    --   ticket = { table = "helpdesk_tickets", verbs = { closed = { status = "closed" } } }
    --                                 → the same, plus helpdesk.ticket.closed when
    --                                   a ticket becomes closed (helper.plugin-events)
    -- Normalised to { name = { table = ..., verbs = ... } }.
    local publishes = {}
    for name, spec in pairs(manifest.publishes or {}) do
        if type(spec) == "string" then spec = { table = spec } end
        if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_]*$") or type(spec) ~= "table"
            or type(spec.table) ~= "string" or not spec.table:match("^[a-z_][a-z0-9_]*$") then
            return nil, manifest_path .. ": publishes entries look like ticket = \"helpdesk_tickets\" or "
                .. "ticket = { table = \"helpdesk_tickets\", verbs = { closed = { status = \"closed\" } } }"
        end
        local verbs_err = require("helper.plugin-events").checkVerbs(spec.verbs)
        if verbs_err then
            return nil, manifest_path .. ": publishes." .. name .. ": " .. verbs_err
        end
        publishes[name] = { table = spec.table, verbs = spec.verbs or {} }
    end
    manifest.publishes = publishes

    -- Per-workspace on/off and settings (helper.plugin-workspaces).
    if manifest.default_enabled ~= nil and type(manifest.default_enabled) ~= "boolean" then
        return nil, manifest_path .. ": default_enabled must be true or false"
    end
    local settings_err = require("helper.plugin-workspaces").checkSettings(manifest.settings)
    if settings_err then
        return nil, manifest_path .. ": " .. settings_err
    end
    manifest.settings = manifest.settings or {}

    manifest.path = project_path
    manifest.manifest_path = manifest_path
    manifest.version = manifest.version or "0.1.0"
    manifest.enabled = manifest.enabled ~= false
    manifest.depends = manifest.depends or { "core" }
    manifest.feature = manifest.feature or manifest.code
    manifest.dashboard = manifest.dashboard or {}
    manifest.theme = manifest.theme or "default"
    manifest.api_prefix = manifest.api_prefix or ("/api/v2/" .. manifest.code:gsub("_", "-"))
    if type(manifest.api_prefix) ~= "string" or not manifest.api_prefix:match("^/api/[%w_/%-]*[%w_%-]$") then
        return nil, manifest_path .. ": api_prefix must look like /api/v2/<name>"
    end
    manifest.routes = {}
    manifest.errors = {}
    manifest.resources = {} -- filled by sdk.crud: key -> dashboard page schema

    return manifest, nil
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

--- Register a manifest into ProjectConfig (feature flag + RBAC modules).
-- @return boolean ok, string|nil error
function ProjectLoader.register(manifest)
    if _registered[manifest.code] then
        return true
    end
    if ProjectLoader.isReservedCode(manifest.code) then
        return false, "code '" .. manifest.code .. "' is reserved by a built-in OpsAPI module"
    end

    local ok_pc, ProjectConfig = pcall(require, "helper.project-config")
    if ok_pc and ProjectConfig.registerFeature then
        local feature_list = {}
        for _, dep in ipairs(manifest.depends) do
            table.insert(feature_list, dep)
        end
        table.insert(feature_list, manifest.feature)
        ProjectConfig.registerFeature(manifest.code, feature_list, manifest.modules)
    end

    _registered[manifest.code] = manifest
    table.insert(_registered_list, manifest)
    return true
end

-- ---------------------------------------------------------------------------
-- Route Loading
-- ---------------------------------------------------------------------------

local VERBS = { "get", "post", "put", "delete", "match" }

--- An app proxy that mounts every route under `prefix`, refuses to replace
-- existing routes, records what it registered (manifest.routes — used by
-- /api/v2/plugins and the OpenAPI spec) and injects self.project.
function ProjectLoader.createPrefixedApp(app, prefix, manifest)
    local proxy = setmetatable({ plugin = manifest }, { __index = app })

    for _, verb in ipairs(VERBS) do
        proxy[verb] = function(_, a, b, c)
            local name, path, handler
            if c ~= nil then
                name, path, handler = a, b, c
            else
                path, handler = a, b
            end
            local full_path = prefix .. path
            local method = verb == "match" and "ANY" or verb:upper()

            -- Lapis merges verbs per path, so registering an existing
            -- path+verb silently REPLACES that handler — a plugin could
            -- hijack a core route. Refuse instead.
            local existing = (rawget(app, "responders") or {})[full_path]
            if rawget(app, full_path) ~= nil
                and (method == "ANY" or not existing or existing.respond_to[method]) then
                error(method .. " " .. full_path .. " is already registered", 0)
            end

            if type(handler) == "function" then
                local fn = handler
                handler = function(self)
                    self.project = manifest
                    self.project_code = manifest.code
                    return fn(self)
                end
            end

            table.insert(manifest.routes, { method = method, path = full_path })
            if name then
                return app[verb](app, name, full_path, handler)
            end
            return app[verb](app, full_path, handler)
        end
    end

    -- A plugin's before_filter only runs for its own routes, not core's.
    proxy.before_filter = function(_, fn)
        app:before_filter(function(self)
            local uri = ngx.var.uri or ""
            if uri == prefix or uri:sub(1, #prefix + 1) == prefix .. "/" then
                return fn(self)
            end
        end)
    end

    return proxy
end

--- Load every api/*.lua route file of a plugin. Errors are recorded on
-- manifest.errors (and reported by failures()), never raised.
function ProjectLoader.loadRoutes(app, manifest)
    if not manifest.enabled then
        return
    end

    -- The prefix must be the plugin's own: otherwise its before_filters would
    -- run on (and its routes interleave with) core's or another plugin's.
    local prefix = manifest.api_prefix
    for _, key in ipairs(rawget(app, "ordered_routes") or {}) do
        local path = type(key) == "table" and select(2, next(key)) or key
        if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then
            table.insert(manifest.errors, "api_prefix " .. prefix .. " is already used by " .. path)
            log_err("[Plugin:", manifest.code, "] api_prefix ", prefix, " is already used by ", path)
            return
        end
    end

    local api_dir = manifest.path .. "/api"
    local proxy = ProjectLoader.createPrefixedApp(app, prefix, manifest)

    for _, file in ipairs(ProjectLoader.listDir(api_dir)) do
        if file:match("%.lua$") then
            local chunk, err = loadfile(api_dir .. "/" .. file)
            local ok, mod = chunk ~= nil, err
            if chunk then ok, mod = pcall(chunk) end
            if ok and type(mod) ~= "function" then
                ok, mod = false, "must return function(app)"
            end
            if ok then ok, mod = pcall(mod, proxy) end
            if not ok then
                table.insert(manifest.errors, file .. ": " .. tostring(mod))
                log_err("[Plugin:", manifest.code, "] ", file, ": ", tostring(mod))
            end
        end
    end

    for _, e in ipairs(manifest.menu) do
        if e.resource and not manifest.resources[e.resource] then
            log_err("[Plugin:", manifest.code, "] menu entry '", e.label, "' links to resource '", e.resource,
                "', but no sdk.crud registers it — the page will say it isn't available")
        end
    end
    for key, pg in pairs(manifest.pages) do
        if manifest.resources[key] then
            table.insert(manifest.errors, "page '" .. key .. "' has the same key as an sdk.crud resource")
        end
        if not is_file(manifest.path .. "/" .. pg.entry) then
            log_err("[Plugin:", manifest.code, "] page '", key, "': ", pg.entry, " doesn't exist")
        end
    end

    notice("[Plugin:", manifest.code, "] ", #manifest.routes, " route(s) under ", manifest.api_prefix)
end

-- ---------------------------------------------------------------------------
-- Main Entry Point
-- ---------------------------------------------------------------------------

--- Discover, validate and register every plugin under projects_root.
-- @return table List of registered manifests
function ProjectLoader.init(projects_root)
    for _, entry in ipairs(ProjectLoader.discover(projects_root)) do
        local manifest, err = ProjectLoader.loadManifest(entry.manifest_path, entry.path)
        if manifest and manifest.enabled then
            local ok, reg_err = ProjectLoader.register(manifest)
            if ok then
                notice("[Plugin] registered ", manifest.code, " (", manifest.name, ") v", manifest.version)
            end
            err = reg_err
        elseif manifest then
            notice("[Plugin] skipped (enabled = false): ", entry.dir_name)
        end
        if err then
            table.insert(_failures, { code = manifest and manifest.code or entry.dir_name, errors = { err } })
            log_err("[Plugin] ", entry.dir_name, ": ", err)
        end
    end
    return _registered_list
end

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------

function ProjectLoader.getRegistered()
    return _registered_list
end

function ProjectLoader.getByCode(code)
    if code then
        code = code:lower():gsub("-", "_")
    end
    return _registered[code]
end

function ProjectLoader.getCount()
    return #_registered_list
end

--- Plugins that failed to load (bad manifest, reserved code, route errors,
-- events/*.lua or jobs/*.lua errors).
-- @return table List of { code, errors = { message, ... } }
function ProjectLoader.failures()
    local out = {}
    for _, f in ipairs(_failures) do
        out[#out + 1] = f
    end
    for _, f in ipairs(require("helper.plugin-events").failures()) do
        out[#out + 1] = f
    end
    for _, f in ipairs(require("helper.plugin-jobs").failures()) do
        out[#out + 1] = f
    end
    for _, m in ipairs(_registered_list) do
        if #m.errors > 0 then
            out[#out + 1] = { code = m.code, errors = m.errors }
        end
    end
    return out
end

--- Reset registry (tests)
function ProjectLoader.reset()
    _registered = {}
    _registered_list = {}
    _failures = {}
end

return ProjectLoader
