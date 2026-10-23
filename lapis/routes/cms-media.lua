--[[
    CMS public media upload
    =======================

    POST /api/v2/cms/media  (auth + namespace + cms:update)
      multipart: file|image|cover_image, optional slug, optional kind (default cover)

    Uploads to the public www S3 website bucket and returns a URL under
    CMS_PUBLIC_BASE_URL (e.g. https://www.workstation.co.uk/img/blog/<slug>/cover.jpg).

    GET  /api/v2/cms/media/config
      { configured: bool, base_url?: string } — dashboard hides upload when unset.
]]

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local CmsHttp = require("helper.cms-http")
local CmsPublicMedia = require("helper.cms-public-media")

local api_response = CmsHttp.api_response

return function(app)
    app:get("/api/v2/cms/media/config", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local ok = CmsPublicMedia.configured()
            return {
                status = 200,
                json = {
                    success = true,
                    data = {
                        configured = ok,
                        base_url = ok and CmsPublicMedia.base_url() or nil,
                    },
                },
            }
        end)))

    app:post("/api/v2/cms/media", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "update", function(self)
            if not CmsPublicMedia.configured() then
                return api_response(503, nil,
                    "Public CMS media is not configured. Add CMS_PUBLIC_S3_* (or AWS_*) to Vault for this ring.")
            end

            local file = self.params.file or self.params.image or self.params.cover_image
            local ns = self.namespace or {}
            local result, err = CmsPublicMedia.upload(file, {
                slug = self.params.slug,
                namespace_slug = ns.slug or ns.name,
                kind = self.params.kind or "cover",
            })
            if not result then
                return api_response(400, nil, err or "Upload failed")
            end
            return api_response(201, result)
        end)))
end
