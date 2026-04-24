--[[
  Project Theme Routes

  Serves theme configuration and CSS for modular projects.

  Endpoints:
    GET /api/v2/projects/:project_code/theme            → Theme metadata (theme.json)
    GET /api/v2/projects/:project_code/theme/styles.css  → CSS stylesheet
    GET /api/v2/projects/:project_code/theme/tenant      → Tenant-specific theme overrides
]]

local cjson = require("cjson")
local db = require("lapis.db")

return function(app)

    -- GET /api/v2/projects/:project_code/theme — Theme metadata
    app:get("/api/v2/projects/:project_code/theme", function(self)
        local ok, ProjectLoader = pcall(require, "helper.project-loader")
        if not ok then
            return { status = 500, json = { error = "Project loader not available" } }
        end

        local manifest = ProjectLoader.getByCode(self.params.project_code)
        if not manifest then
            return { status = 404, json = { error = "Project not found" } }
        end

        local theme_name = manifest.theme or "default"
        local theme_path = manifest.path .. "/themes/" .. theme_name .. "/theme.json"

        local f = io.open(theme_path, "r")
        if not f then
            -- Return default theme if no theme file exists
            return {
                status = 200,
                json = {
                    name = "default",
                    project_code = manifest.code,
                    primary_color = "#2563eb",
                    secondary_color = "#1e40af",
                    accent_color = "#3b82f6",
                    font_family = "Inter, sans-serif",
                    layout = "modern",
                }
            }
        end

        local content = f:read("*a")
        f:close()

        local ok_json, theme = pcall(cjson.decode, content)
        if not ok_json then
            return { status = 500, json = { error = "Invalid theme.json" } }
        end

        theme.project_code = manifest.code
        return { status = 200, json = theme }
    end)

    -- GET /api/v2/projects/:project_code/theme/styles.css — CSS stylesheet
    app:get("/api/v2/projects/:project_code/theme/styles.css", function(self)
        local ok, ProjectLoader = pcall(require, "helper.project-loader")
        if not ok then
            return { status = 404 }
        end

        local manifest = ProjectLoader.getByCode(self.params.project_code)
        if not manifest then
            return { status = 404 }
        end

        local theme_name = manifest.theme or "default"
        local css_path = manifest.path .. "/themes/" .. theme_name .. "/styles.css"

        local f = io.open(css_path, "r")
        ngx.header["Content-Type"] = "text/css; charset=utf-8"

        if not f then
            -- Return empty CSS if no styles file exists
            ngx.header["Cache-Control"] = "public, max-age=300"
            return { status = 200, layout = false, "/* No custom styles */" }
        end

        local css = f:read("*a")
        f:close()

        ngx.header["Cache-Control"] = "public, max-age=3600"
        return { status = 200, layout = false, css }
    end)

    -- GET /api/v2/projects/:project_code/theme/tenant — Tenant-specific overrides
    app:get("/api/v2/projects/:project_code/theme/tenant", function(self)
        local ok, ProjectLoader = pcall(require, "helper.project-loader")
        if not ok then
            return { status = 500, json = { error = "Project loader not available" } }
        end

        local manifest = ProjectLoader.getByCode(self.params.project_code)
        if not manifest then
            return { status = 404, json = { error = "Project not found" } }
        end

        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return { status = 200, json = { overrides = {}, custom_css = "" } }
        end

        -- Query tenant-specific theme overrides
        local rows = db.select(
            "* FROM project_tenant_themes WHERE project_code = ? AND namespace_id = ? LIMIT 1",
            manifest.code, namespace_id
        )

        if #rows == 0 then
            return { status = 200, json = { overrides = {}, custom_css = "" } }
        end

        local tenant_theme = rows[1]
        local overrides = {}
        if tenant_theme.theme_overrides then
            local ok_json, parsed = pcall(cjson.decode, tenant_theme.theme_overrides)
            if ok_json then
                overrides = parsed
            end
        end

        return {
            status = 200,
            json = {
                overrides = overrides,
                custom_css = tenant_theme.custom_css or "",
            }
        }
    end)
end
