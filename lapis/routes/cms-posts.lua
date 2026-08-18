--[[
    CMS Blog Post API Routes
    ========================

    Multi-tenant blog articles with rich WYSIWYG content, categories and tags.
    Admin endpoints are namespace-scoped and RBAC-gated (module "cms"); public
    endpoints expose published posts for a namespace to its public website.

    Admin (auth + namespace + RBAC module "cms"):
      GET    /api/v2/cms/posts
      POST   /api/v2/cms/posts
      GET    /api/v2/cms/posts/:uuid
      PUT    /api/v2/cms/posts/:uuid
      DELETE /api/v2/cms/posts/:uuid

    Public (no auth; namespace by slug):
      GET    /api/v2/public/cms/:namespace/posts
      GET    /api/v2/public/cms/:namespace/posts/:slug
]]

local CmsPostQueries = require "queries.CmsPostQueries"
local CmsHttp = require "helper.cms-http"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local parse_body = CmsHttp.parse_body
local api_response = CmsHttp.api_response
local to_bool = CmsHttp.to_bool
local coerce_list = CmsHttp.coerce_list
local resolve_namespace = CmsHttp.resolve_namespace

local POST_STATUS = { draft = true, published = true, scheduled = true, archived = true }
local VISIBILITY = { public = true, private = true }

--- Shape a post row for the public site (omit internal/private fields).
local function public_post(p)
    return {
        uuid = p.uuid,
        title = p.title,
        slug = p.slug,
        excerpt = p.excerpt,
        content_html = p.content_html,
        featured_image_url = p.featured_image_url,
        author_name = p.author_name,
        published_at = p.published_at,
        reading_minutes = p.reading_minutes,
        view_count = p.view_count,
        is_featured = p.is_featured,
        category = p.category,
        categories = p.categories or {},
        tags = p.tags or {},
        seo_title = p.seo_title,
        seo_description = p.seo_description,
        seo_keywords = p.seo_keywords,
    }
end

--- Shape a post-list item for the public site (no full body).
local function public_post_summary(p)
    return {
        uuid = p.uuid,
        title = p.title,
        slug = p.slug,
        excerpt = p.excerpt,
        featured_image_url = p.featured_image_url,
        author_name = p.author_name,
        published_at = p.published_at,
        reading_minutes = p.reading_minutes,
        is_featured = p.is_featured,
        category = p.category,
        categories = p.categories or {},
        tags = p.tags or {},
    }
end

return function(app)
    -------------------------------------------------------------------------
    -- ADMIN
    -------------------------------------------------------------------------
    app:get("/api/v2/cms/posts", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local result = CmsPostQueries.list(self.namespace.id, {
                page = self.params.page,
                perPage = self.params.perPage,
                status = self.params.status,
                category_uuid = self.params.category,
                tag = self.params.tag,
                search = self.params.search,
                is_featured = self.params.featured == "true" and true or nil,
            })
            return { status = 200, json = { success = true, data = result.data, meta = result.meta } }
        end)))

    app:post("/api/v2/cms/posts", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "create", function(self)
            local body = parse_body()
            if not body.title or body.title == "" then
                return api_response(400, nil, "title is required")
            end
            local status = body.status or "draft"
            if not POST_STATUS[status] then
                return api_response(400, nil, "Invalid status (draft|published|scheduled|archived)")
            end
            local visibility = body.visibility or "public"
            if not VISIBILITY[visibility] then
                return api_response(400, nil, "Invalid visibility (public|private)")
            end

            local user = self.current_user or {}
            local author_name = body.author_name
            if not author_name or author_name == "" then
                author_name = user.first_name and (user.first_name .. " " .. (user.last_name or "")) or user.username
            end

            local post = CmsPostQueries.create(self.namespace.id, {
                title = body.title,
                slug = body.slug,
                excerpt = body.excerpt,
                content_html = body.content_html,
                content_json = body.content_json,
                featured_image_url = body.featured_image_url,
                status = status,
                visibility = visibility,
                is_featured = to_bool(body.is_featured, false),
                category_uuid = body.category_uuid,
                category_uuids = coerce_list(body.category_uuids),
                tags = coerce_list(body.tags),
                author_uuid = user.uuid,
                author_name = author_name,
                scheduled_at = body.scheduled_at,
                seo_title = body.seo_title,
                seo_description = body.seo_description,
                seo_keywords = body.seo_keywords,
            })
            return api_response(201, post)
        end)))

    app:get("/api/v2/cms/posts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local post = CmsPostQueries.getByUuid(self.namespace.id, self.params.uuid)
            if not post then return api_response(404, nil, "Post not found") end
            return api_response(200, post)
        end)))

    app:put("/api/v2/cms/posts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "update", function(self)
            local body = parse_body()
            if body.status and not POST_STATUS[body.status] then
                return api_response(400, nil, "Invalid status")
            end
            if body.visibility and not VISIBILITY[body.visibility] then
                return api_response(400, nil, "Invalid visibility")
            end

            local fields = {}
            for _, k in ipairs({ "title", "slug", "excerpt", "content_html", "content_json",
                "featured_image_url", "status", "visibility", "category_uuid", "author_name",
                "scheduled_at", "seo_title", "seo_description", "seo_keywords" }) do
                if body[k] ~= nil then fields[k] = body[k] end
            end
            if body.is_featured ~= nil then fields.is_featured = to_bool(body.is_featured, false) end
            if body.category_uuids ~= nil then fields.category_uuids = coerce_list(body.category_uuids) end
            if body.tags ~= nil then fields.tags = coerce_list(body.tags) end

            local post = CmsPostQueries.update(self.namespace.id, self.params.uuid, fields)
            if not post then return api_response(404, nil, "Post not found") end
            return api_response(200, post)
        end)))

    app:delete("/api/v2/cms/posts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "delete", function(self)
            local post = CmsPostQueries.softDelete(self.namespace.id, self.params.uuid)
            if not post then return api_response(404, nil, "Post not found") end
            return api_response(200, { deleted = true })
        end)))

    -------------------------------------------------------------------------
    -- PUBLIC (no auth; namespace by slug)
    -------------------------------------------------------------------------
    app:get("/api/v2/public/cms/:namespace/posts", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end

        local result = CmsPostQueries.listPublished(ns.id, {
            page = self.params.page,
            perPage = self.params.perPage,
            category = self.params.category,
            tag = self.params.tag,
            search = self.params.search,
        })
        local out = {}
        for _, p in ipairs(result.data) do out[#out + 1] = public_post_summary(p) end
        return { status = 200, json = { success = true, data = out, meta = result.meta } }
    end)

    app:get("/api/v2/public/cms/:namespace/posts/:slug", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end

        local post = CmsPostQueries.getPublishedBySlug(ns.id, self.params.slug)
        if not post then return api_response(404, nil, "Post not found") end
        return { status = 200, json = { success = true, data = public_post(post) } }
    end)
end
