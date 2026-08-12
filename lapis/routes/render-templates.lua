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

local cjson = require("cjson")
local parse_body = CmsHttp.parse_body
local api_response = CmsHttp.api_response
local to_bool = CmsHttp.to_bool

-- Preview data arrives as a JSON string (form-posted). Decode it to a table so
-- the renderer can substitute; nil/empty -> nil (lets the saved-template preview
-- fall back to its stored sample_data).
local function decode_data(v)
    if v == nil then return nil end
    if type(v) == "table" then return v end
    if type(v) == "string" and v ~= "" then
        local ok, decoded = pcall(cjson.decode, v)
        if ok and type(decoded) == "table" then return decoded end
    end
    return nil
end

-- Starter content + sample data per template type, shown pre-filled in the
-- "New template" dialog. The domain formats come straight from the WSL Proxy
-- renderer's defaults, so the starter is ALWAYS the current production format
-- (single source of truth — no drift between here and the sync engine).
local function type_defaults()
    local Wsl = require("helper.wslproxy-server")
    return {
        cms_page = {
            content = table.concat({
                '<article class="page">',
                '  <header>',
                '    <h1>{{title}}</h1>',
                '    <p class="excerpt">{{excerpt}}</p>',
                '  </header>',
                '  <main>{{content}}</main>',
                '</article>',
            }, "\n"),
            sample_data = cjson.encode({
                title = "About Us", excerpt = "Who we are", content = "<p>Body…</p>",
            }),
        },
        domain_wslproxy = {
            content = Wsl.DEFAULT_SERVER_TEMPLATE,
            sample_data = cjson.encode({
                server_name = "acme.com", root = "/var/www/html", profile_id = "prod",
                rules = "opsapi-acme-com", listens_json = '[{"listen": "80"}]',
                ssl_enabled = true, ssl_email = "admin@acme.com", ssl_force_https = true,
                ssl_staging = false, ssl_auto_renew = true, config = "",
            }),
        },
        domain_rule = {
            content = Wsl.DEFAULT_RULE_TEMPLATE,
            sample_data = cjson.encode({
                rule_id = "opsapi-acme-com", profile_id = "prod", rule_path = "/",
                backend = "193.237.176.232:18039", servers_json = '["host:acme.com"]',
            }),
        },
    }
end

return function(app)
    -- Default starter content/sample for each type (for the New template dialog).
    app:get("/api/v2/render-templates/defaults", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "read", function(self)
            return { status = 200, json = { success = true, data = type_defaults() } }
        end)))

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
            local result = RenderTemplateQueries.preview(self.namespace.id, self.params.uuid, decode_data(body.data))
            if not result then return api_response(404, nil, "Template not found") end
            return api_response(200, result)
        end)))

    -- Render AD-HOC content + data (live editor preview, nothing saved).
    app:post("/api/v2/render-templates/preview", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("templates", "read", function(self)
            local body = parse_body()
            return api_response(200, {
                rendered = TemplateRender.render(body.content or "", decode_data(body.data) or {}),
                placeholders = TemplateRender.placeholders(body.content or ""),
            })
        end)))
end
