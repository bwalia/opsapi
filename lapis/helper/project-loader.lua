--[[
  Project Loader Engine

  Scans /projects/*/ directories for project.lua manifests,
  registers them into the ProjectConfig system, and loads their routes.

  Each project is a self-contained module with its own:
    - project.lua   (manifest)
    - api/*.lua      (route handlers)
    - migrations/*   (database migrations)
    - dashboards/*   (dashboard definitions)
    - themes/*       (visual themes)

  Usage:
    local ProjectLoader = require("helper.project-loader")
    local projects = ProjectLoader.init("/app/projects")
    for _, manifest in ipairs(projects) do
        ProjectLoader.loadRoutes(app, manifest)
    end
]]

local ProjectLoader = {}

-- Registry of loaded projects (keyed by project code)
local _registered = {}
local _registered_list = {}

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

--- Scan a directory for subdirectories containing project.lua
-- @param projects_root string Absolute path to /projects/ directory
-- @return table List of { code, path, manifest } entries
function ProjectLoader.discover(projects_root)
    local discovered = {}

    -- Use lfs if available, fall back to io.popen
    local ok_lfs, lfs = pcall(require, "lfs")
    if ok_lfs then
        for entry in lfs.dir(projects_root) do
            if entry ~= "." and entry ~= ".." and entry ~= ".gitkeep" then
                local full_path = projects_root .. "/" .. entry
                local attr = lfs.attributes(full_path)
                if attr and attr.mode == "directory" then
                    local manifest_path = full_path .. "/project.lua"
                    local mattr = lfs.attributes(manifest_path)
                    if mattr then
                        table.insert(discovered, {
                            dir_name = entry,
                            path = full_path,
                            manifest_path = manifest_path,
                        })
                    end
                end
            end
        end
    else
        -- Fallback: use ls
        local handle = io.popen("ls -d " .. projects_root .. "/*/project.lua 2>/dev/null")
        if handle then
            for line in handle:lines() do
                local dir_path = line:match("^(.+)/project%.lua$")
                if dir_path then
                    local dir_name = dir_path:match("([^/]+)$")
                    table.insert(discovered, {
                        dir_name = dir_name,
                        path = dir_path,
                        manifest_path = line,
                    })
                end
            end
            handle:close()
        end
    end

    -- Sort by directory name for deterministic ordering
    table.sort(discovered, function(a, b) return a.dir_name < b.dir_name end)

    return discovered
end

--- Load and validate a project.lua manifest
-- @param manifest_path string Absolute path to project.lua
-- @param project_path string Absolute path to project directory
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

    -- Validate required fields
    if not manifest.code or type(manifest.code) ~= "string" then
        return nil, manifest_path .. " missing required field: code"
    end
    if not manifest.name or type(manifest.name) ~= "string" then
        return nil, manifest_path .. " missing required field: name"
    end

    -- Normalise code (lowercase, underscores)
    manifest.code = manifest.code:lower():gsub("-", "_")

    -- Attach path info
    manifest.path = project_path
    manifest.manifest_path = manifest_path

    -- Defaults
    manifest.version = manifest.version or "0.1.0"
    manifest.enabled = manifest.enabled ~= false -- default true
    manifest.depends = manifest.depends or { "core" }
    manifest.feature = manifest.feature or manifest.code
    manifest.modules = manifest.modules or {}
    manifest.dashboard = manifest.dashboard or {}
    manifest.theme = manifest.theme or "default"

    -- Build API prefix from code (use hyphens in URLs)
    if not manifest.api_prefix then
        manifest.api_prefix = "/api/v2/" .. manifest.code:gsub("_", "-")
    end

    return manifest, nil
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

--- Register a project manifest into ProjectConfig
-- @param manifest table Validated project manifest
function ProjectLoader.register(manifest)
    if _registered[manifest.code] then
        return -- already registered
    end

    -- Register into ProjectConfig for feature-gating compatibility
    local ok_pc, ProjectConfig = pcall(require, "helper.project-config")
    if ok_pc and ProjectConfig.registerFeature then
        -- Build feature list: project's own feature + dependencies
        local feature_list = {}
        for _, dep in ipairs(manifest.depends) do
            table.insert(feature_list, dep)
        end
        -- Add the project's own feature code
        table.insert(feature_list, manifest.feature)

        ProjectConfig.registerFeature(manifest.code, feature_list, manifest.modules)
    end

    _registered[manifest.code] = manifest
    table.insert(_registered_list, manifest)
end

-- ---------------------------------------------------------------------------
-- Route Loading
-- ---------------------------------------------------------------------------

--- Create a prefixed app proxy that prepends project prefix to all routes
-- and injects project context into request handlers
-- @param app table Lapis application
-- @param prefix string URL prefix (e.g. /api/v2/hospital-patient-manager)
-- @param manifest table Project manifest
-- @return table Proxy app object
function ProjectLoader.createPrefixedApp(app, prefix, manifest)
    local proxy = {}
    local mt = {
        __index = function(_, key)
            return app[key]
        end
    }
    setmetatable(proxy, mt)

    local methods = { "get", "post", "put", "delete", "match" }

    for _, method in ipairs(methods) do
        proxy[method] = function(_, path, handler, ...)
            local full_path = prefix .. path

            -- Wrap handler to inject project context
            local original_handler = handler
            if type(handler) == "function" then
                handler = function(self)
                    self.project = manifest
                    self.project_code = manifest.code
                    return original_handler(self)
                end
            elseif type(handler) == "table" then
                -- respond_to style: { GET = fn, POST = fn }
                local wrapped = {}
                for verb, fn in pairs(handler) do
                    if type(fn) == "function" then
                        wrapped[verb] = function(self)
                            self.project = manifest
                            self.project_code = manifest.code
                            return fn(self)
                        end
                    else
                        wrapped[verb] = fn
                    end
                end
                handler = wrapped
            end

            local log = ngx and ngx.log or print
            local notice = ngx and ngx.NOTICE or nil
            if log and notice then
                log(notice, "[Project:", manifest.code, "] Registering: ", method:upper(), " ", full_path)
            end

            return app[method](app, full_path, handler, ...)
        end
    end

    return proxy
end

--- Load routes for a single project
-- @param app table Lapis application
-- @param manifest table Project manifest
function ProjectLoader.loadRoutes(app, manifest)
    if not manifest.enabled then
        return
    end

    local prefix = manifest.api_prefix
    local routes_dir = manifest.path .. "/api"

    -- Check if api/ directory exists
    local ok_lfs, lfs = pcall(require, "lfs")
    local dir_exists = false

    if ok_lfs then
        local attr = lfs.attributes(routes_dir)
        dir_exists = attr and attr.mode == "directory"
    else
        local handle = io.popen("test -d " .. routes_dir .. " && echo yes")
        if handle then
            dir_exists = handle:read("*l") == "yes"
            handle:close()
        end
    end

    if not dir_exists then
        return
    end

    local prefixed_app = ProjectLoader.createPrefixedApp(app, prefix, manifest)

    -- Scan api/ directory for .lua files
    local route_files = {}
    if ok_lfs then
        for file in lfs.dir(routes_dir) do
            if file:match("%.lua$") then
                table.insert(route_files, file)
            end
        end
    else
        local handle = io.popen("ls " .. routes_dir .. "/*.lua 2>/dev/null")
        if handle then
            for line in handle:lines() do
                local file = line:match("([^/]+)$")
                if file then
                    table.insert(route_files, file)
                end
            end
            handle:close()
        end
    end

    -- Sort for deterministic loading order
    table.sort(route_files)

    -- Load each route file
    for _, file in ipairs(route_files) do
        local file_path = routes_dir .. "/" .. file
        local chunk, err = loadfile(file_path)
        if chunk then
            local ok_exec, route_module = pcall(chunk)
            if ok_exec and type(route_module) == "function" then
                local ok_init, init_err = pcall(route_module, prefixed_app)
                if not ok_init then
                    local log = ngx and ngx.log or print
                    local err_level = ngx and ngx.ERR or nil
                    if log and err_level then
                        log(err_level, "[Project:", manifest.code, "] Failed to init route ", file, ": ", tostring(init_err))
                    else
                        print("[Project:" .. manifest.code .. "] Failed to init route " .. file .. ": " .. tostring(init_err))
                    end
                end
            elseif not ok_exec then
                local log = ngx and ngx.log or print
                local err_level = ngx and ngx.ERR or nil
                if log and err_level then
                    log(err_level, "[Project:", manifest.code, "] Failed to execute route ", file, ": ", tostring(route_module))
                else
                    print("[Project:" .. manifest.code .. "] Failed to execute route " .. file .. ": " .. tostring(route_module))
                end
            end
        else
            local log = ngx and ngx.log or print
            local err_level = ngx and ngx.ERR or nil
            if log and err_level then
                log(err_level, "[Project:", manifest.code, "] Failed to load route ", file, ": ", tostring(err))
            else
                print("[Project:" .. manifest.code .. "] Failed to load route " .. file .. ": " .. tostring(err))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Main Entry Point
-- ---------------------------------------------------------------------------

--- Initialize the project loader: discover, validate, and register all projects
-- @param projects_root string Absolute path to /projects/ directory
-- @return table List of registered project manifests
function ProjectLoader.init(projects_root)
    local log = ngx and ngx.log or print
    local notice = ngx and ngx.NOTICE or nil

    if log and notice then
        log(notice, "=== Project Loader: Scanning ", projects_root, " ===")
    else
        print("=== Project Loader: Scanning " .. projects_root .. " ===")
    end

    local discovered = ProjectLoader.discover(projects_root)

    for _, entry in ipairs(discovered) do
        local manifest, err = ProjectLoader.loadManifest(entry.manifest_path, entry.path)
        if manifest then
            if manifest.enabled then
                ProjectLoader.register(manifest)
                if log and notice then
                    log(notice, "[Project Loader] Registered: ", manifest.code, " (", manifest.name, ") v", manifest.version)
                else
                    print("[Project Loader] Registered: " .. manifest.code .. " (" .. manifest.name .. ") v" .. manifest.version)
                end
            else
                if log and notice then
                    log(notice, "[Project Loader] Skipped (disabled): ", entry.dir_name)
                end
            end
        else
            local err_level = ngx and ngx.ERR or nil
            if log and err_level then
                log(err_level, "[Project Loader] Error loading ", entry.dir_name, ": ", err)
            else
                print("[Project Loader] Error loading " .. entry.dir_name .. ": " .. tostring(err))
            end
        end
    end

    if log and notice then
        log(notice, "=== Project Loader: ", #_registered_list, " project(s) registered ===")
    else
        print("=== Project Loader: " .. #_registered_list .. " project(s) registered ===")
    end

    return _registered_list
end

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------

--- Get all registered projects
-- @return table List of project manifests
function ProjectLoader.getRegistered()
    return _registered_list
end

--- Get a project by its code
-- @param code string Project code
-- @return table|nil manifest
function ProjectLoader.getByCode(code)
    if code then
        code = code:lower():gsub("-", "_")
    end
    return _registered[code]
end

--- Get project count
-- @return number
function ProjectLoader.getCount()
    return #_registered_list
end

--- Reset registry (useful for testing)
function ProjectLoader.reset()
    _registered = {}
    _registered_list = {}
end

return ProjectLoader
