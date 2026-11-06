--[[
    Media library — one place for a workspace's content images
    ===========================================================

    Every image uploaded from the content editors (or the Media tab) becomes a
    media_assets row, so it can be found, reused, edited (as a new copy) and
    removed from one place.

    Where the file goes:
      s3_public  the public website bucket, when CMS_PUBLIC_S3_* is configured
                 (helper/cms-public-media.lua) — same as before the library
      minio      otherwise the deployment's own MinIO, served by
                 GET /api/v2/public/media/<uuid>.<ext> over MinIO's internal
                 endpoint (the public MinIO host is not reachable everywhere)

    The browser does crop/resize/rotate (the server has no image tools) and
    uploads the result as a new image linked to its original; an original is
    never overwritten, because published posts point at its URL.
]]

local db = require("lapis.db")
local Global = require("helper.global")
local MinioClient = require("helper.minio")
local CmsPublicMedia = require("helper.cms-public-media")

local M = {}

M.MAX_BYTES = 8 * 1024 * 1024

-- What the bytes really are decides the type; the browser's label is ignored.
local TYPES = {
    { mime = "image/jpeg", ext = "jpg", test = function(b) return b:sub(1, 3) == "\255\216\255" end },
    { mime = "image/png", ext = "png", test = function(b) return b:sub(1, 8) == "\137PNG\r\n\26\n" end },
    { mime = "image/gif", ext = "gif", test = function(b) return b:sub(1, 4) == "GIF8" end },
    { mime = "image/webp", ext = "webp", test = function(b) return b:sub(1, 4) == "RIFF" and b:sub(9, 12) == "WEBP" end },
    { mime = "image/svg+xml", ext = "svg", test = function(b) return b:sub(1, 4096):lower():find("<svg", 1, true) ~= nil end },
}
local EXT_OF = {}
for _, t in ipairs(TYPES) do EXT_OF[t.mime] = t.ext end

-- ?type= filter values
local TYPE_FILTER = {
    jpeg = "image/jpeg", png = "image/png", gif = "image/gif", webp = "image/webp", svg = "image/svg+xml",
}

local SORTS = {
    newest = "m.created_at DESC, m.id DESC",
    oldest = "m.created_at ASC, m.id ASC",
    name = "lower(coalesce(m.title, m.filename, '')) ASC, m.id ASC",
    largest = "m.size_bytes DESC NULLS LAST, m.id DESC",
}

local function detect(content)
    for _, t in ipairs(TYPES) do
        if t.test(content) then return t.mime end
    end
    return nil
end

-- SVG is code: a script in one runs when the file is opened directly. Refuse
-- anything active (the public route also sends a sandbox CSP).
local function unsafe_svg(content)
    local s = content:lower()
    return s:find("<script", 1, true) or s:find("javascript:", 1, true) or s:find("<foreignobject", 1, true)
        or s:find("<iframe", 1, true) or s:find("<embed", 1, true) or s:find("<object", 1, true)
        or s:find("%son[%a]+%s*=") or s:find("<!entity", 1, true)
end

local function text(v, max)
    if v == nil or v == db.NULL then return nil end
    local s = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s:sub(1, max)
end

local function int(v, max)
    local n = tonumber(v)
    if not n or n ~= n or n < 1 or n > max then return nil end
    return math.floor(n)
end

-- The host the browser reached us on: an image URL must work from a browser.
-- (Not OPSAPI_PUBLIC_URL: a shared Vault secret can point that at another stack.)
local function request_base()
    local scheme = (ngx.var.http_x_forwarded_proto or ""):match("^%s*([%a]+)") or ngx.var.scheme or "https"
    local host = ngx.var.http_host or ngx.var.host
    if not host or host == "" then return nil end
    return scheme:lower() .. "://" .. host
end

--- The deployment's own MinIO client, or nil when it is not configured.
function M.minio()
    local client = MinioClient.getDefault()
    if client:validate() then return client end
    return nil
end

--- Where new uploads go: "s3_public", "minio", or nil (nowhere to store them).
function M.storage()
    if CmsPublicMedia.configured() then return "s3_public" end
    if M.minio() then return "minio" end
    return nil
end

local SELECT = [[
    m.uuid, m.storage, m.url, m.filename, m.mime_type, m.size_bytes, m.width, m.height,
    m.alt_text, m.title, m.created_at, m.updated_at,
    (SELECT s.uuid FROM media_assets s WHERE s.id = m.source_asset_id) AS source_uuid,
    nullif(trim(concat_ws(' ', u.first_name, u.last_name)), '') AS uploaded_by_name
    FROM media_assets m LEFT JOIN users u ON u.uuid = m.uploaded_by_user_uuid
]]

--- Posts and pages that show this image (featured image or in their content).
function M.usage(namespace_id, url)
    local used = {}
    for _, t in ipairs({ { "cms_posts", "post" }, { "cms_pages", "page" } }) do
        local rows = db.query(([[
            SELECT uuid, title, status FROM %s
             WHERE namespace_id = ? AND deleted_at IS NULL
               AND (featured_image_url = ? OR position(? in coalesce(content_html, '')) > 0)
             ORDER BY updated_at DESC LIMIT 50]]):format(t[1]), namespace_id, url, url)
        for _, r in ipairs(rows) do
            used[#used + 1] = { kind = t[2], uuid = r.uuid, title = r.title, status = r.status }
        end
    end
    return used
end

function M.get(ns, uuid)
    local row = db.query("SELECT " .. SELECT .. " WHERE m.namespace_id = ? AND m.uuid = ?", ns.id, tostring(uuid))[1]
    if not row then return nil end
    row.used_in = M.usage(ns.id, row.url)
    return row
end

--- @param q table { search?, type?, sort?, page?, per_page? }
function M.list(ns, q)
    q = q or {}
    local where = { db.interpolate_query("m.namespace_id = ?", ns.id) }
    local search = text(q.search, 200)
    if search then
        local like = "%" .. search:gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = db.interpolate_query(
            "(m.filename ILIKE ? OR m.title ILIKE ? OR m.alt_text ILIKE ?)", like, like, like)
    end
    if q.type and TYPE_FILTER[q.type] then
        where[#where + 1] = db.interpolate_query("m.mime_type = ?", TYPE_FILTER[q.type])
    end
    local cond = table.concat(where, " AND ")
    local page = Global.pageParam(q.page)
    local per_page = Global.perPageParam(q.per_page, 40, 100)
    local total = tonumber(db.query("SELECT count(*) AS n FROM media_assets m WHERE " .. cond)[1].n) or 0
    local items = db.query(("SELECT %s WHERE %s ORDER BY %s LIMIT %d OFFSET %d"):format(
        SELECT, cond, SORTS[q.sort] or SORTS.newest, per_page, (page - 1) * per_page))
    return items, {
        page = page, per_page = per_page, total = total,
        total_pages = math.max(1, math.ceil(total / per_page)),
    }
end

--- Store an uploaded image and add it to the library.
-- @param ns table namespace row
-- @param user_uuid string|nil who uploaded it
-- @param file table Lapis multipart file { filename, content, content_type }
-- @param fields table { alt_text?, title?, width?, height?, source_uuid? }
-- @return table|nil row, string|nil error, number|nil HTTP status
function M.upload(ns, user_uuid, file, fields)
    fields = fields or {}
    if type(file) ~= "table" or type(file.content) ~= "string" or file.content == "" then
        return nil, "Choose an image to upload.", 400
    end
    if #file.content > M.MAX_BYTES then
        return nil, "That image is larger than 8 MB. Make it smaller and try again.", 413
    end
    local mime = detect(file.content)
    if not mime then
        return nil, "Only JPEG, PNG, WebP, GIF or SVG images can be uploaded.", 400
    end
    if mime == "image/svg+xml" and unsafe_svg(file.content) then
        return nil, "This SVG has scripts or other active parts inside, so it can't be uploaded. "
            .. "Save it again as a plain SVG, or as a PNG.", 400
    end

    local source_id
    if text(fields.source_uuid, 64) then
        local src = db.query("SELECT id FROM media_assets WHERE namespace_id = ? AND uuid = ?",
            ns.id, text(fields.source_uuid, 64))[1]
        if not src then return nil, "The original image is no longer in the library.", 404 end
        source_id = src.id
    end

    local storage = M.storage()
    if not storage then
        return nil, "Image storage isn't set up on this server yet. Ask your administrator to set up file storage.", 503
    end

    local uuid = Global.generateUUID()
    local ext = EXT_OF[mime]
    local body = { filename = uuid .. "." .. ext, content = file.content, content_type = mime }
    local opts = {
        validate_type = false, -- checked above, from the bytes
        max_size = M.MAX_BYTES,
        metadata = { source = "opsapi-media", namespace = tostring(ns.slug or ns.id) },
    }
    local client, url
    if storage == "s3_public" then
        client = CmsPublicMedia.client()
        local ns_part = tostring(ns.slug or ns.id):lower():gsub("[^a-z0-9%-]", "")
        if ns_part == "" then ns_part = tostring(ns.id) end
        opts.object_key = ("img/cms/%s/%s.%s"):format(ns_part, uuid, ext)
        opts.auto_create_bucket = false
        url = CmsPublicMedia.base_url() .. "/" .. opts.object_key
    else
        client = M.minio()
        local base = request_base()
        if not base then return nil, "Could not work out this server's web address.", 500 end
        opts.object_key = ("media/%s/%s.%s"):format(ns.uuid or ns.id, uuid, ext)
        url = base .. "/api/v2/public/media/" .. uuid .. "." .. ext
    end

    local _, err = client:upload(body, opts)
    if err then
        ngx.log(ngx.ERR, "[media] upload to ", storage, " failed: ", err)
        return nil, "The image could not be saved just now. Please try again in a minute.", 502
    end

    local ok, ierr = pcall(db.query, [[
        INSERT INTO media_assets (uuid, namespace_id, storage, bucket, object_key, url, filename, mime_type,
            size_bytes, width, height, alt_text, title, source_asset_id, uploaded_by_user_uuid)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        uuid, ns.id, storage, client.bucket, opts.object_key, url,
        text(file.filename, 255) or body.filename, mime, #file.content,
        int(fields.width, 50000) or db.NULL, int(fields.height, 50000) or db.NULL,
        text(fields.alt_text, 1000) or db.NULL, text(fields.title, 255) or db.NULL,
        source_id or db.NULL, user_uuid or db.NULL)
    if not ok then
        ngx.log(ngx.ERR, "[media] saving the row failed: ", tostring(ierr))
        pcall(client.delete, client, opts.object_key)
        return nil, "The image could not be saved just now. Please try again in a minute.", 500
    end
    return M.get(ns, uuid)
end

--- Change the alt text / title. Only fields present in `fields` change.
function M.update(ns, uuid, fields)
    local row = db.query("SELECT id FROM media_assets WHERE namespace_id = ? AND uuid = ?", ns.id, tostring(uuid))[1]
    if not row then return nil, "Image not found", 404 end
    local set = {}
    if fields.alt_text ~= nil then set.alt_text = text(fields.alt_text, 1000) or db.NULL end
    if fields.title ~= nil then set.title = text(fields.title, 255) or db.NULL end
    if next(set) then
        set.updated_at = db.raw("NOW()")
        db.update("media_assets", set, { id = row.id })
    end
    return M.get(ns, uuid)
end

--- Remove an image: the file from storage, then the row. A `link` image is
-- only taken out of the library (the file lives somewhere we don't own).
function M.delete(ns, uuid)
    local row = db.query("SELECT * FROM media_assets WHERE namespace_id = ? AND uuid = ?", ns.id, tostring(uuid))[1]
    if not row then return nil, "Image not found", 404 end
    if row.storage ~= "link" and row.object_key and row.object_key ~= db.NULL then
        local client = row.storage == "s3_public" and CmsPublicMedia.client() or M.minio()
        if not client then
            return nil, "The file can't be removed while its storage is switched off. Nothing was deleted.", 503
        end
        local ok, err = client:delete(row.object_key, row.bucket ~= db.NULL and row.bucket or nil)
        if not ok then
            ngx.log(ngx.ERR, "[media] deleting ", row.object_key, " failed: ", tostring(err))
            return nil, "The file could not be removed just now. Nothing was deleted; please try again.", 502
        end
    end
    db.query("DELETE FROM media_assets WHERE id = ?", row.id)
    return true
end

--- Bytes of a MinIO-stored image for the public route.
-- @return string|nil body, string|nil mime, number|nil error status
function M.serve(file)
    local uuid = tostring(file or ""):match("^(%x[%x%-]+)%.%a+$")
    if not uuid then return nil, nil, 404 end
    local row = db.query("SELECT object_key, bucket, mime_type FROM media_assets WHERE uuid = ? AND storage = 'minio'",
        uuid)[1]
    if not row then return nil, nil, 404 end
    local client = M.minio()
    if not client then return nil, nil, 503 end
    -- ponytail: whole file in memory (8 MB cap); stream it if the cap grows.
    local body, err, status = client:get(row.object_key, row.bucket ~= db.NULL and row.bucket or nil)
    if not body then
        if status == 404 then return nil, nil, 404 end
        ngx.log(ngx.ERR, "[media] reading ", row.object_key, " failed: ", tostring(err))
        return nil, nil, 502
    end
    return body, row.mime_type
end

return M
