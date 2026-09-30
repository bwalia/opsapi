--[[
    Plugin API

      GET /api/v2/plugins          platform admins: installed plugins, routes, load failures
      GET /api/v2/plugins/:code    platform admins: one plugin, plus its migration status
      GET /api/v2/plugins/:code/resources/:resource
                                   namespace members with <module>.read: the
                                   dashboard page schema of an sdk.crud resource

    Plugins are loaded by helper.project-loader; see PLUGINS.md.
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local ProjectLoader = require("helper.project-loader")

local function array(t)
    return setmetatable(t, cjson.array_mt)
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
        return { status = 200, json = { success = true, data = data } }
    end))

    -- Drives the dashboard's generic plugin page: /dashboard/plugins/<code>/<resource>
    app:get("/api/v2/plugins/:code/resources/:resource", NamespaceMiddleware.requireNamespace(function(self)
        local m = ProjectLoader.getByCode(self.params.code)
        local page = m and m.resources[self.params.resource]
        if not page then
            return { status = 404, json = { success = false, error = "Page not found" } }
        end
        local function can(action)
            return NamespaceMiddleware.hasPermission(self, page.module, action)
        end
        if not can("read") then
            return { status = 403, json = { success = false, error = "Permission denied" } }
        end

        local data = { plugin = { code = m.code, name = m.name } }
        for k, v in pairs(page) do data[k] = v end
        data.can = {
            create = page.actions.create and can("create"),
            update = page.actions.update and can("update"),
            delete = page.actions.delete and can("delete"),
        }
        return { status = 200, json = { success = true, data = data } }
    end))
end
