--[[
    Media library API (lib/media-library.lua)
    =========================================

    Admin (auth + namespace + RBAC module "cms"):
      GET    /api/v2/cms/media/config   { configured, storage, max_bytes, site_url }
      GET    /api/v2/cms/media          ?search&type=jpeg|png|webp|gif|svg&sort=newest|oldest|name|largest&page&per_page
      POST   /api/v2/cms/media          multipart: file (or image / cover_image), alt_text, title,
                                         width, height, source_uuid (an edited copy of that image)
      GET    /api/v2/cms/media/:uuid    with used_in (posts and pages showing it)
      PUT    /api/v2/cms/media/:uuid    { alt_text, title }
      DELETE /api/v2/cms/media/:uuid    removes the file too

    Public (no auth):
      GET    /api/v2/public/media/:file  <uuid>.<ext> of a MinIO-stored image
]]

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local CmsHttp = require("helper.cms-http")
local Media = require("lib.media-library")

local api_response = CmsHttp.api_response

local function user_uuid(self)
    local u = self.current_user or {}
    return u.uuid or u.sub
end

return function(app)
    app:get("/api/v2/cms/media/config", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function()
            local storage = Media.storage()
            return api_response(200, {
                configured = storage ~= nil, storage = storage, max_bytes = Media.MAX_BYTES,
                site_url = require("helper.cms-public-media").site_url(),
            })
        end)))

    app:get("/api/v2/cms/media", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local items, meta = Media.list(self.namespace, self.params)
            return { status = 200, json = { success = true, data = items, meta = meta } }
        end)))

    app:post("/api/v2/cms/media", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "update", function(self)
            local p = self.params
            local row, err, status = Media.upload(self.namespace, user_uuid(self),
                p.file or p.image or p.cover_image, p)
            if not row then return api_response(status or 400, nil, err) end
            return api_response(201, row)
        end)))

    app:get("/api/v2/cms/media/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "read", function(self)
            local row = Media.get(self.namespace, self.params.uuid)
            if not row then return api_response(404, nil, "Image not found") end
            return api_response(200, row)
        end)))

    app:put("/api/v2/cms/media/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "update", function(self)
            local body = CmsHttp.parse_body()
            local row, err, status = Media.update(self.namespace, self.params.uuid, {
                alt_text = body.alt_text, title = body.title,
            })
            if not row then return api_response(status or 400, nil, err) end
            return api_response(200, row)
        end)))

    app:delete("/api/v2/cms/media/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("cms", "delete", function(self)
            local ok, err, status = Media.delete(self.namespace, self.params.uuid)
            if not ok then return api_response(status or 400, nil, err) end
            return api_response(200, { deleted = true })
        end)))

    app:get("/api/v2/public/media/:file", function(self)
        local body, mime, status = Media.serve(self.params.file)
        if not body then
            return { status = status or 404, layout = false, content_type = "text/plain", "Not found" }
        end
        -- Straight onto self.res.headers: the `headers` return option adds a second
        -- copy of a header the CORS filter already set, and browsers refuse two.
        local h = self.res.headers
        h["Cache-Control"] = "public, max-age=31536000, immutable"
        h["X-Content-Type-Options"] = "nosniff"
        h["Content-Security-Policy"] = "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox"
        -- Public images: any site may show them, and the dashboard's crop tool
        -- needs CORS to read the pixels. No cookies are involved.
        h["Access-Control-Allow-Origin"] = "*"
        h["Access-Control-Allow-Credentials"] = nil
        return { status = 200, layout = false, content_type = mime, body }
    end)
end
