--[[
  Project Dashboard Routes

  Serves project metadata, dashboard configuration, and page definitions
  for the modular project system.

  Endpoints:
    GET /api/v2/projects                              → List all registered projects
    GET /api/v2/projects/:project_code/dashboard       → Dashboard config for a project
    GET /api/v2/projects/:project_code/dashboard/pages/:page_id → Page definition from dashboards/*.json
    GET /api/v2/projects/:project_code/migrations/status → Migration status
]]

local respond_to = require("lapis.application").respond_to
local cjson = require("cjson")

return function(app)

    -- GET /api/v2/projects — List all registered projects
    app:get("/api/v2/projects", function(self)
        local ok, ProjectLoader = pcall(require, "helper.project-loader")
        if not ok then
            return { status = 500, json = { error = "Project loader not available" } }
        end

        local projects = ProjectLoader.getRegistered()
        local result = {}

        for _, manifest in ipairs(projects) do
            table.insert(result, {
                code = manifest.code,
                name = manifest.name,
                version = manifest.version,
                description = manifest.description,
                api_prefix = manifest.api_prefix,
                enabled = manifest.enabled,
                theme = manifest.theme,
                dashboard = manifest.dashboard,
            })
        end

        return {
            status = 200,
            json = {
                data = result,
                total = #result,
            }
        }
    end)

    -- GET /api/v2/projects/:project_code/dashboard — Dashboard config
    app:get("/api/v2/projects/:project_code/dashboard", function(self)
        local ok, ProjectLoader = pcall(require, "helper.project-loader")
        if not ok then
            return { status = 500, json = { error = "Project loader not available" } }
        end

        local manifest = ProjectLoader.getByCode(self.params.project_code)
        if not manifest then
            return { status = 404, json = { error = "Project not found" } }
        end

        -- Combine manifest dashboard config with discovered dashboard files
        local dashboard = {
            project_code = manifest.code,
            project_name = manifest.name,
            menu_items = manifest.dashboard and manifest.dashboard.menu_items or {},
            pages = {},
        }

        -- Discover dashboard JSON files
        local dashboards_dir = manifest.path .. "/dashboards"
        local ok_lfs, lfs = pcall(require, "lfs")
        if ok_lfs then
            local attr = lfs.attributes(dashboards_dir)
            if attr and attr.mode == "directory" then
                for file in lfs.dir(dashboards_dir) do
                    if file:match("%.json$") then
                        local page_id = file:gsub("%.json$", "")
                        local f = io.open(dashboards_dir .. "/" .. file, "r")
                        if f then
                            local content = f:read("*a")
                            f:close()
                            local ok_json, page_def = pcall(cjson.decode, content)
                            if ok_json then
                                page_def.page_id = page_def.page_id or page_id
                                table.insert(dashboard.pages, page_def)
                            end
                        end
                    end
                end
            end
        end

        return { status = 200, json = dashboard }
    end)

    -- GET /api/v2/projects/:project_code/dashboard/pages/:page_id — Single page definition
    app:get("/api/v2/projects/:project_code/dashboard/pages/:page_id", function(self)
        local ok, ProjectLoader = pcall(require, "helper.project-loader")
        if not ok then
            return { status = 500, json = { error = "Project loader not available" } }
        end

        local manifest = ProjectLoader.getByCode(self.params.project_code)
        if not manifest then
            return { status = 404, json = { error = "Project not found" } }
        end

        local page_path = manifest.path .. "/dashboards/" .. self.params.page_id .. ".json"
        local f = io.open(page_path, "r")
        if not f then
            return { status = 404, json = { error = "Dashboard page not found" } }
        end

        local content = f:read("*a")
        f:close()

        local ok_json, page_def = pcall(cjson.decode, content)
        if not ok_json then
            return { status = 500, json = { error = "Invalid dashboard page JSON" } }
        end

        page_def.page_id = page_def.page_id or self.params.page_id
        return { status = 200, json = page_def }
    end)

    -- GET /api/v2/projects/:project_code/migrations/status — Migration status
    app:get("/api/v2/projects/:project_code/migrations/status", function(self)
        local ok_loader, ProjectLoader = pcall(require, "helper.project-loader")
        if not ok_loader then
            return { status = 500, json = { error = "Project loader not available" } }
        end

        local manifest = ProjectLoader.getByCode(self.params.project_code)
        if not manifest then
            return { status = 404, json = { error = "Project not found" } }
        end

        local ok_migrator, ProjectMigrator = pcall(require, "helper.project-migrator")
        if not ok_migrator then
            return { status = 500, json = { error = "Project migrator not available" } }
        end

        local status = ProjectMigrator.status(manifest.code, manifest.path)
        status.project_code = manifest.code
        return { status = 200, json = status }
    end)
end
