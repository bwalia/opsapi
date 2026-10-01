--[[
    Plugin API

      GET /api/v2/plugins          platform admins: installed plugins, routes, load failures
      GET /api/v2/plugins/:code    platform admins: one plugin, plus its migration + event status
      POST /api/v2/plugins/:code/events/retry
                                   platform admins: re-queue the plugin's dead event deliveries
      POST /api/v2/plugins/:code/jobs/:job/run
                                   platform admins: run a job now (every workspace, or
                                   ?namespace_id= one)
      GET /api/v2/namespace/plugins
                                   namespace.read: the installed plugins, on/off in this
                                   workspace, their settings (secrets: only whether set)
                                   and jobs
      PUT /api/v2/namespace/plugins/:code
                                   namespace.update: { enabled?, settings? } for this
                                   workspace (helper/plugin-workspaces.lua)
      GET /api/v2/plugins/:code/resources/:resource
                                   namespace members with <module>.read: what
                                   /dashboard/plugins/<code>/<key> shows — an
                                   sdk.crud resource (kind "resource": fields,
                                   columns, rights) or a custom page (kind
                                   "page": its ui/ URL and the APIs it may call)
      GET /plugin-ui/:code/*       public: a plugin's static ui/ files
      GET /plugin-ui/_sdk/:file    public: the page bridge (opsapi-ui.js/.css)

    The ui/ files are code, not data: public like any web app's bundles, with
    no credentials. A custom page runs in a sandboxed frame and reaches the
    API only through the dashboard's bridge, as the signed-in user, limited
    to the plugin's own API and the prefixes its manifest lists.

    Plugins are loaded by helper.project-loader; see PLUGINS.md.
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local ProjectLoader = require("helper.project-loader")
local PluginWorkspaces = require("helper.plugin-workspaces")
local PluginJobs = require("helper.plugin-jobs")

local function array(t)
    return setmetatable(t, cjson.array_mt)
end

-- Static types a plugin UI may ship (anything else is a 404).
local MIME = {
    html = "text/html; charset=utf-8", htm = "text/html; charset=utf-8",
    js = "text/javascript; charset=utf-8", mjs = "text/javascript; charset=utf-8",
    css = "text/css; charset=utf-8", json = "application/json", map = "application/json",
    svg = "image/svg+xml", png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
    gif = "image/gif", webp = "image/webp", ico = "image/x-icon", avif = "image/avif",
    woff = "font/woff", woff2 = "font/woff2", txt = "text/plain; charset=utf-8",
}
local NOT_FOUND = { status = 404, layout = false, content_type = "text/plain", "Not found" }

-- Serve one static file: revalidated every time (ETag), so a plugin update
-- shows at once, and loadable from the sandboxed frame (opaque origin).
local function serve_file(self, path)
    local mime = MIME[(path:match("%.(%w+)$") or ""):lower()]
    local f = mime and io.open(path, "rb")
    if not f then return NOT_FOUND end
    local body = f:read("*a")
    f:close()
    local etag = '"' .. ngx.md5(body) .. '"'
    ngx.header["ETag"] = etag
    ngx.header["Cache-Control"] = "no-cache"
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Cross-Origin-Resource-Policy"] = "cross-origin"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    if self.req.headers["if-none-match"] == etag then
        return { status = 304, layout = false, "" }
    end
    return { status = 200, layout = false, content_type = mime, body }
end

local function summary(m)
    return {
        code = m.code,
        name = m.name,
        version = m.version,
        description = m.description,
        sdk_version = m.sdk_version,
        api_prefix = m.api_prefix,
        status = #m.errors > 0 and "error" or "loaded",
        errors = array(m.errors),
        routes = array(m.routes),
        modules = array(m.modules),
        dashboard = m.dashboard,
        pages = array((function()
            local list = {}
            for _, pg in pairs(m.pages) do list[#list + 1] = { key = pg.key, label = pg.label, entry = pg.entry } end
            table.sort(list, function(a, b) return a.key < b.key end)
            return list
        end)()),
    }
end

return function(app)
    app:get("/api/v2/plugins", AuthMiddleware.requireRole("administrative", function()
        local data = {}
        for _, m in ipairs(ProjectLoader.getRegistered()) do
            table.insert(data, summary(m))
        end
        return {
            status = 200,
            json = { success = true, data = array(data), failures = array(ProjectLoader.failures()) },
        }
    end))

    app:get("/api/v2/plugins/:code", AuthMiddleware.requireRole("administrative", function(self)
        local m = ProjectLoader.getByCode(self.params.code)
        if not m then
            return { status = 404, json = { success = false, error = "Plugin not found" } }
        end
        local data = summary(m)
        local status = require("helper.project-migrator").status(m.code, m.path)
        data.migrations = {
            total = status.total,
            executed = array(status.executed),
            pending = array(status.pending),
            drift = array(status.drift),
        }
        local events = require("helper.plugin-events").stats(m.code)
        if events then
            events.subscriptions = array(events.subscriptions)
            events.publishes = array(events.publishes)
            events.failures = array(events.failures)
        end
        data.events = events
        data.jobs = PluginJobs.stats(m.code)
        return { status = 200, json = { success = true, data = data } }
    end))

    app:post("/api/v2/plugins/:code/jobs/:job/run", AuthMiddleware.requireRole("administrative", function(self)
        local m = ProjectLoader.getByCode(self.params.code)
        local job = m and (m.code .. "." .. self.params.job)
        local ns = self.params.namespace_id and tonumber(self.params.namespace_id)
        if self.params.namespace_id and not ns then
            return { status = 400, json = { success = false, error = "namespace_id must be a number" } }
        end
        local queued = job and PluginJobs.runNow(job, ns)
        if not queued then
            return { status = 404, json = { success = false, error = "Job not found" } }
        end
        return { status = 200, json = { success = true, data = { queued = queued } } }
    end))

    -- A workspace's plugins: on/off and settings (Workspace -> Plugins).
    local function workspace_view(m, ns)
        local data = PluginWorkspaces.describe(m, ns)
        data.jobs = PluginJobs.forNamespace(m.code, ns)
        return data
    end

    app:get("/api/v2/namespace/plugins", NamespaceMiddleware.requirePermission("namespace", "read", function(self)
        local data = {}
        for _, m in ipairs(ProjectLoader.getRegistered()) do
            data[#data + 1] = workspace_view(m, self.namespace.id)
        end
        table.sort(data, function(a, b) return a.name:lower() < b.name:lower() end)
        return { status = 200, json = { success = true, data = array(data) } }
    end))

    app:put("/api/v2/namespace/plugins/:code", NamespaceMiddleware.requirePermission("namespace", "update",
        function(self)
            local m = ProjectLoader.getByCode(self.params.code)
            if not m then
                return { status = 404, json = { success = false, error = "Plugin not found" } }
            end
            local body, body_err = require("helper.plugin-sdk").body(self)
            if not body then return { status = 400, json = { success = false, error = body_err } } end

            local user = self.current_user or {}
            local after, before, message, details = PluginWorkspaces.update(m, self.namespace.id,
                { enabled = body.enabled, settings = body.settings }, user.uuid)
            if not after then
                return { status = before, json = { success = false, error = message, details = details } }
            end

            -- Audit (never fails the change): what was turned on/off or set;
            -- secrets only as set / not set.
            local function snapshot(d)
                local values = {}
                for _, st in ipairs(d.settings) do
                    if st.secret then values[st.name] = st.is_set and "(set)" or nil else values[st.name] = st.value end
                end
                return { enabled = d.enabled, settings = next(values) and values or nil }
            end
            local action = after.enabled ~= before.enabled and (after.enabled and "plugin.enabled" or "plugin.disabled")
                or "plugin.settings_updated"
            pcall(function()
                local db = require("lapis.db")
                local u = user.uuid and db.query("SELECT id FROM users WHERE uuid = ?", user.uuid)[1]
                require("queries.NamespaceAuditLogQueries").log({
                    namespace_id = self.namespace.id, user_id = u and u.id, action = action,
                    entity_type = "plugin", entity_id = m.code,
                    old_values = snapshot(before), new_values = snapshot(after),
                    ip_address = ngx.var.remote_addr, user_agent = self.req.headers["user-agent"],
                })
            end)
            return { status = 200, json = { success = true, data = workspace_view(m, self.namespace.id) } }
        end))

    app:post("/api/v2/plugins/:code/events/retry", AuthMiddleware.requireRole("administrative", function(self)
        local m = ProjectLoader.getByCode(self.params.code)
        if not m then
            return { status = 404, json = { success = false, error = "Plugin not found" } }
        end
        local requeued = require("helper.plugin-events").retryDead(m.code)
        return { status = 200, json = { success = true, data = { requeued = requeued } } }
    end))

    -- Drives the dashboard's plugin pages: /dashboard/plugins/<code>/<key>
    app:get("/api/v2/plugins/:code/resources/:resource", NamespaceMiddleware.requireNamespace(function(self)
        local m = ProjectLoader.getByCode(self.params.code)
        local key = self.params.resource
        local resource = m and m.resources[key]
        local custom = m and not resource and m.pages[key]
        local page = resource or custom
        if not page then
            return { status = 404, json = { success = false, error = "Page not found" } }
        end
        if not PluginWorkspaces.isEnabled(m.code, self.namespace.id) then
            return { status = 404, json = { success = false, error = m.name .. " is turned off for this workspace",
                                            code = "PLUGIN_DISABLED" } }
        end
        local function can(action)
            return NamespaceMiddleware.hasPermission(self, page.module, action)
        end
        if not can("read") then
            return { status = 403, json = { success = false, error = "Permission denied" } }
        end

        local data = { plugin = { code = m.code, name = m.name, api_prefix = m.api_prefix } }
        if custom then
            data.kind = "page"
            data.key, data.label, data.module, data.description = custom.key, custom.label, custom.module,
                custom.description
            data.url = "/plugin-ui/" .. m.code .. "/" .. custom.entry:match("^ui/(.+)$")
            data.api = array({ m.api_prefix, unpack(custom.api) })
            data.can = { read = true, create = can("create"), update = can("update"), delete = can("delete") }
        else
            for k, v in pairs(resource) do data[k] = v end
            data.kind = "resource"
            data.can = {
                create = resource.actions.create and can("create"),
                update = resource.actions.update and can("update"),
                delete = resource.actions.delete and can("delete"),
            }
        end
        return { status = 200, json = { success = true, data = data } }
    end))

    -- The page bridge every custom page loads (static/plugin-ui/).
    app:get("/plugin-ui/_sdk/:file", function(self)
        local file = self.params.file
        if file ~= "opsapi-ui.js" and file ~= "opsapi-ui.css" then return NOT_FOUND end
        return serve_file(self, ngx.config.prefix():gsub("/+$", "") .. "/static/plugin-ui/" .. file)
    end)

    -- A plugin's static ui/ files (custom pages and their assets).
    app:get("/plugin-ui/:code/*", function(self)
        local m = ProjectLoader.getByCode(self.params.code)
        local rel = ProjectLoader.safeUiPath(self.params.splat)
        if not m or not rel then return NOT_FOUND end
        return serve_file(self, m.path .. "/ui/" .. rel)
    end)
end
