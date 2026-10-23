-- Email images: uploaded once, stored in MinIO, served from a stable public URL
-- (/api/v2/opsapi-marketing/public/img/<uuid>.<ext>) that any mail client can load.
local db = require("lapis.db")
local U = require("opsapi_marketing.util")

local I = {}

I.MAX_BYTES = 2 * 1024 * 1024 -- emails should stay light; most clients clip big messages

-- The type comes from the bytes, never the file name. No SVG: it can carry script.
local KINDS = {
    { magic = "\137PNG\r\n\26\n", ext = "png", content_type = "image/png" },
    { magic = "\255\216\255", ext = "jpg", content_type = "image/jpeg" },
    { magic = "GIF87a", ext = "gif", content_type = "image/gif" },
    { magic = "GIF89a", ext = "gif", content_type = "image/gif" },
}

function I.kind(bytes)
    for _, k in ipairs(KINDS) do
        if bytes:sub(1, #k.magic) == k.magic then return k end
    end
    if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
        return { ext = "webp", content_type = "image/webp" }
    end
end

function I.url(base, row)
    return base .. "/api/v2/opsapi-marketing/public/img/" .. row.uuid .. "." .. row.ext
end

--- Store an image. @return row (with url) or nil, err
function I.save(ns, file_name, bytes, actor_uuid)
    local kind = I.kind(bytes)
    if not kind then return nil, "Use a PNG, JPEG, GIF or WebP image" end
    if #bytes > I.MAX_BYTES then return nil, "Images can be up to 2 MB" end
    local base = require("opsapi_marketing.send").public_base(U.settings(ns))
    if base == "" then
        return nil, "Set the public tracking/unsubscribe URL first: images in emails need a public address"
    end
    local uuid = require("helper.global").generateUUID()
    local Minio = require("helper.minio").getDefault()
    local key = "marketing/" .. tostring(ns) .. "/" .. uuid .. "." .. kind.ext
    local _, err, meta = Minio:upload({ filename = uuid .. "." .. kind.ext, content = bytes, content_type = kind.content_type },
        { object_key = key, validate_type = false, max_size = I.MAX_BYTES })
    if not meta then
        ngx.log(ngx.ERR, "[opsapi_marketing] image upload: ", tostring(err))
        return nil, "Could not store the image"
    end
    local row = db.query([[
        INSERT INTO mkt_images (uuid, namespace_id, object_key, bucket, content_type, ext, size_bytes, file_name, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING uuid, ext, content_type, size_bytes, file_name, created_at
    ]], uuid, ns, meta.key, meta.bucket, kind.content_type, kind.ext, #bytes,
        type(file_name) == "string" and file_name:sub(1, 255) or db.NULL, actor_uuid or db.NULL)[1]
    row.url = I.url(base, row)
    return row
end

--- The stored bytes of a public image. @return bytes, content_type or nil
function I.read(uuid)
    local row = U.one("SELECT * FROM mkt_images WHERE uuid = ?", uuid)
    if not row or not U.plugin_on(row.namespace_id) then return nil end
    local Minio = require("helper.minio").getDefault()
    local url = Minio:getPresignedUrl(row.object_key, 300, row.bucket, false, "GET")
    if not url then return nil end
    -- Signed for the configured host; connect to its resolved address (as uploads do).
    local res = require("resty.http").new():request_uri(url:gsub("^https?://[^/]+", Minio:_resolved_endpoint(), 1), {
        method = "GET", headers = { Host = Minio.host }, ssl_verify = false,
    })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "[opsapi_marketing] image read ", uuid, ": ", res and res.status or "no response")
        return nil
    end
    return res.body, row.content_type
end

return I
