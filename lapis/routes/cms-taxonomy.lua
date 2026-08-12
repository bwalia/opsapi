--[[
    CMS Taxonomy API Routes (Categories + Tags)
    ===========================================

    Namespace-scoped, RBAC-gated (module "cms") management of blog categories
    and tags, plus public reads for the website's category/tag navigation.

    Admin (auth + namespace + RBAC module "cms"):
      Categories:
        GET    /api/v2/cms/categories
        POST   /api/v2/cms/categories
        PUT    /api/v2/cms/categories/:uuid
        DELETE /api/v2/cms/categories/:uuid
      Tags:
        GET    /api/v2/cms/tags
        POST   /api/v2/cms/tags
        PUT    /api/v2/cms/tags/:uuid
        DELETE /api/v2/cms/tags/:uuid

    Public (no auth; namespace by slug):
      GET    /api/v2/public/cms/:namespace/categories
      GET    /api/v2/public/cms/:namespace/tags
]]

local CmsCategoryQueries = require "queries.CmsCategoryQueries"
local CmsTagQueries = require "queries.CmsTagQueries"
local CmsHttp = require "helper.cms-http"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local parse_body = CmsHttp.parse_body
local api_response = CmsHttp.api_response
local resolve_namespace = CmsHttp.resolve_namespace

return function(app)
    -------------------------------------------------------------------------
    -- CATEGORIES (admin)
    -------------------------------------------------------------------------
    app:get("/api/v2/cms/categories", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local cats = CmsCategoryQueries.list(self.namespace.id, { search = self.params.search })
            return { status = 200, json = { success = true, data = cats } }
        end)))

    app:post("/api/v2/cms/categories", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "create", function(self)
            local body = parse_body()
            if not body.name or body.name == "" then
                return api_response(400, nil, "name is required")
            end
            local cat = CmsCategoryQueries.create(self.namespace.id, {
                name = body.name,
                slug = body.slug or "",
                description = body.description,
                parent_uuid = body.parent_uuid,
                position = body.position,
            })
            return api_response(201, cat)
        end)))

    app:put("/api/v2/cms/categories/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "update", function(self)
            local body = parse_body()
            local cat = CmsCategoryQueries.update(self.namespace.id, self.params.uuid, {
                name = body.name,
                slug = body.slug,
                description = body.description,
                parent_uuid = body.parent_uuid,
                position = body.position,
            })
            if not cat then return api_response(404, nil, "Category not found") end
            return api_response(200, cat)
        end)))

    app:delete("/api/v2/cms/categories/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "delete", function(self)
            local cat = CmsCategoryQueries.softDelete(self.namespace.id, self.params.uuid)
            if not cat then return api_response(404, nil, "Category not found") end
            return api_response(200, { deleted = true })
        end)))

    -------------------------------------------------------------------------
    -- TAGS (admin)
    -------------------------------------------------------------------------
    app:get("/api/v2/cms/tags", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local tags = CmsTagQueries.list(self.namespace.id, { search = self.params.search })
            return { status = 200, json = { success = true, data = tags } }
        end)))

    app:post("/api/v2/cms/tags", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "create", function(self)
            local body = parse_body()
            if not body.name or body.name == "" then
                return api_response(400, nil, "name is required")
            end
            local tag = CmsTagQueries.create(self.namespace.id, {
                name = body.name,
                slug = body.slug or "",
            })
            return api_response(201, tag)
        end)))

    app:put("/api/v2/cms/tags/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "update", function(self)
            local body = parse_body()
            local tag, errcode = CmsTagQueries.update(self.namespace.id, self.params.uuid, {
                name = body.name,
                slug = body.slug,
            })
            if errcode == "slug_taken" then
                return api_response(409, nil, "A tag with this slug already exists")
            end
            if not tag then return api_response(404, nil, "Tag not found") end
            return api_response(200, tag)
        end)))

    app:delete("/api/v2/cms/tags/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "delete", function(self)
            local tag = CmsTagQueries.softDelete(self.namespace.id, self.params.uuid)
            if not tag then return api_response(404, nil, "Tag not found") end
            return api_response(200, { deleted = true })
        end)))

    -------------------------------------------------------------------------
    -- PUBLIC (no auth; namespace by slug)
    -------------------------------------------------------------------------
    app:get("/api/v2/public/cms/:namespace/categories", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end
        local cats = CmsCategoryQueries.list(ns.id, {})
        local out = {}
        for _, c in ipairs(cats) do
            out[#out + 1] = { uuid = c.uuid, name = c.name, slug = c.slug,
                description = c.description, post_count = c.post_count }
        end
        return { status = 200, json = { success = true, data = out } }
    end)

    app:get("/api/v2/public/cms/:namespace/tags", function(self)
        local ns = resolve_namespace(self)
        if not ns then return api_response(404, nil, "Namespace not found") end
        local tags = CmsTagQueries.list(ns.id, {})
        local out = {}
        for _, t in ipairs(tags) do
            out[#out + 1] = { uuid = t.uuid, name = t.name, slug = t.slug, post_count = t.post_count }
        end
        return { status = 200, json = { success = true, data = out } }
    end)
end
