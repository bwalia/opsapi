--[[
    CMS Static Page API Routes
    ==========================

    Multi-tenant static website pages (About, Contact, ...) with rich WYSIWYG
    content. Admin endpoints are namespace-scoped and RBAC-gated (module "cms");
    public endpoints expose published pages for a namespace to its website.

    Admin (auth + namespace + RBAC module "cms"):
      GET    /api/v2/cms/pages
      POST   /api/v2/cms/pages
      GET    /api/v2/cms/pages/:uuid
      PUT    /api/v2/cms/pages/:uuid
      DELETE /api/v2/cms/pages/:uuid

    Public (no auth; namespace by slug):
      GET    /api/v2/public/cms/:namespace/pages            (all published)
      GET    /api/v2/public/cms/:namespace/nav              (nav-flagged pages)
      GET    /api/v2/public/cms/:namespace/pages/:slug
]]

local CmsPageQueries = require "queries.CmsPageQueries"
local RenderTemplateQueries = require "queries.RenderTemplateQueries"
local CmsHttp = require "helper.cms-http"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local parse_body = CmsHttp.parse_body
local api_response = CmsHttp.api_response
local to_bool = CmsHttp.to_bool
local resolve_namespace = CmsHttp.resolve_namespace

local PAGE_STATUS = { draft = true, published = true, archived = true }

local function public_page(p)
    return {
        uuid = p.uuid,
        title = p.title,
        slug = p.slug,
        excerpt = p.excerpt,
        content_html = p.content_html,
        featured_image_url = p.featured_image_url,
        template = p.template,
        published_at = p.published_at,
        updated_at = p.updated_at,
        seo_title = p.seo_title,
        seo_description = p.seo_description,
        seo_keywords = p.seo_keywords,
    }
end

return function(app)
    -------------------------------------------------------------------------
    -- ADMIN
    -------------------------------------------------------------------------
    app:get("/api/v2/cms/pages", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local pages = CmsPageQueries.list(self.namespace.id, {
                status = self.params.status,
                search = self.params.search,
            })
            return { status = 200, json = { success = true, data = pages } }
        end)))

    app:post("/api/v2/cms/pages", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "create", function(self)
            local body = parse_body()
            if not body.title or body.title == "" then
                return api_response(400, nil, "title is required")
            end
            local status = body.status or "draft"
            if not PAGE_STATUS[status] then
                return api_response(400, nil, "Invalid status (draft|published|archived)")
            end

            local user = self.current_user or {}
            local page = CmsPageQueries.create(self.namespace.id, {
                title = body.title,
                slug = body.slug,
                excerpt = body.excerpt,
                content_html = body.content_html,
                content_json = body.content_json,
                featured_image_url = body.featured_image_url,
                status = status,
                template = body.template,
                menu_order = body.menu_order,
                show_in_nav = to_bool(body.show_in_nav, false),
                parent_uuid = body.parent_uuid,
                author_uuid = user.uuid,
                seo_title = body.seo_title,
                seo_description = body.seo_description,
                seo_keywords = body.seo_keywords,
            })
            return api_response(201, page)
        end)))

    app:get("/api/v2/cms/pages/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local page = CmsPageQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not page then return api_response(404, nil, "Page not found") end
            return api_response(200, page)
        end)))

    app:put("/api/v2/cms/pages/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "update", function(self)
            local body = parse_body()
            if body.status and not PAGE_STATUS[body.status] then
                return api_response(400, nil, "Invalid status")
            end
            local fields = {}
            for _, k in ipairs({ "title", "slug", "excerpt", "content_html", "content_json",
                "featured_image_url", "status", "template", "parent_uuid",
                "seo_title", "seo_description", "seo_keywords" }) do
                if body[k] ~= nil then fields[k] = body[k] end
            end
            if body.menu_order ~= nil then fields.menu_order = body.menu_order end
            if body.show_in_nav ~= nil then fields.show_in_nav = to_bool(body.show_in_nav, false) end

            local page = CmsPageQueries.update(self.namespace.id, self.params.uuid, fields)
            if not page then return api_response(404, nil, "Page not found") end
            return api_response(200, page)
        end)))

    app:delete("/api/v2/cms/pages/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "delete", function(self)
            local page = CmsPageQueries.softDelete(self.namespace.id, self.params.uuid)
            if not page then return api_response(404, nil, "Page not found") end
            return api_response(200, { deleted = true })
        end)))

    -------------------------------------------------------------------------
    -- PUBLIC (no auth; namespace by slug)
    -------------------------------------------------------------------------
    app:get("/api/v2/public/cms/:namespace/pages", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end
        local pages = CmsPageQueries.listPublished(ns.id)
        return { status = 200, json = { success = true, data = pages } }
    end)

    app:get("/api/v2/public/cms/:namespace/nav", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end
        local nav = CmsPageQueries.listPublishedNav(ns.id)
        return { status = 200, json = { success = true, data = nav } }
    end)

    app:get("/api/v2/public/cms/:namespace/pages/:slug", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end
        local page = CmsPageQueries.getPublishedBySlug(ns.id, self.params.slug)
        if not page then return api_response(404, nil, "Page not found") end

        local out = public_page(page)
        -- Compose the page into its chosen layout template (if any). `template`
        -- holds a render_templates slug; "default"/unknown -> raw content_html.
        local rendered = RenderTemplateQueries.renderBySlug(ns.id, "cms_page", page.template, {
            title = page.title or "",
            slug = page.slug or "",
            excerpt = page.excerpt or "",
            content = page.content_html or "",
            featured_image_url = page.featured_image_url or "",
            seo_title = page.seo_title or "",
            seo_description = page.seo_description or "",
        })
        out.template = page.template
        out.rendered_html = rendered or page.content_html
        return { status = 200, json = { success = true, data = out } }
    end)
end
