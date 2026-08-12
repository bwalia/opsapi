--[[
    Render Templates API (namespace Template Library)
    =================================================

    Namespace-scoped, RBAC-gated (module "templates") CRUD for the reusable
    "{{slot}}" templates used by CMS pages (type cms_page) and the domains sync
    (type domain_wslproxy), plus preview endpoints that fill a template with data.

      GET    /api/v2/render-templates?type=cms_page
      POST   /api/v2/render-templates
      GET    /api/v2/render-templates/:uuid
      PUT    /api/v2/render-templates/:uuid
      DELETE /api/v2/render-templates/:uuid
      POST   /api/v2/render-templates/:uuid/preview   (render saved template)
      POST   /api/v2/render-templates/preview         (render ad-hoc content+data)
]]

local RenderTemplateQueries = require "queries.RenderTemplateQueries"
local TemplateRender = require "helper.template-render"
local CmsHttp = require "helper.cms-http"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local parse_body = CmsHttp.parse_body
local api_response = CmsHttp.api_response
local to_bool = CmsHttp.to_bool

return function(app)
    app:get("/api/v2/render-templates", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "read", function(self)
            local rows = RenderTemplateQueries.list(self.namespace.id, {
                template_type = self.params.type,
                search = self.params.search,
            })
            return { status = 200, json = { success = true, data = rows } }
        end)))

    app:post("/api/v2/render-templates", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "create", function(self)
            local body = parse_body()
            if not body.name or body.name == "" then
                return api_response(400, nil, "name is required")
            end
            local ttype = body.template_type or "cms_page"
            if not RenderTemplateQueries.VALID_TYPES[ttype] then
                return api_response(400, nil, "Invalid template_type (cms_page|domain_wslproxy)")
            end
            local tpl = RenderTemplateQueries.create(self.namespace.id, {
                name = body.name,
                slug = body.slug,
                template_type = ttype,
                content = body.content,
                sample_data = body.sample_data,
                description = body.description,
                is_default = to_bool(body.is_default, false),
            })
            return api_response(201, tpl)
        end)))

    app:get("/api/v2/render-templates/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "read", function(self)
            local tpl = RenderTemplateQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not tpl then return api_response(404, nil, "Template not found") end
            return api_response(200, tpl)
        end)))

    app:put("/api/v2/render-templates/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "update", function(self)
            local body = parse_body()
            local fields = {}
            for _, k in ipairs({ "name", "slug", "content", "sample_data", "description" }) do
                if body[k] ~= nil then fields[k] = body[k] end
            end
            if body.is_default ~= nil then fields.is_default = to_bool(body.is_default, false) end
            local tpl = RenderTemplateQueries.update(self.namespace.id, self.params.uuid, fields)
            if not tpl then return api_response(404, nil, "Template not found") end
            return api_response(200, tpl)
        end)))

    app:delete("/api/v2/render-templates/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "delete", function(self)
            local tpl = RenderTemplateQueries.softDelete(self.namespace.id, self.params.uuid)
            if not tpl then return api_response(404, nil, "Template not found") end
            return api_response(200, { deleted = true })
        end)))

    -- Render a SAVED template with provided data (or its stored sample_data).
    app:post("/api/v2/render-templates/:uuid/preview", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "read", function(self)
            local body = parse_body()
            local result = RenderTemplateQueries.preview(self.namespace.id, self.params.uuid, body.data)
            if not result then return api_response(404, nil, "Template not found") end
            return api_response(200, result)
        end)))

    -- Render AD-HOC content + data (live editor preview, nothing saved).
    app:post("/api/v2/render-templates/preview", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "read", function(self)
            local body = parse_body()
            return api_response(200, {
                rendered = TemplateRender.render(body.content or "", body.data or {}),
                placeholders = TemplateRender.placeholders(body.content or ""),
            })
        end)))
end
