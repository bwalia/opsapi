-- luacheck: max line length 140
--[[
    Supplier portal files: private storage, virus-scan hook, short-lived download links
    ===================================================================================
    Files go to MinIO (helper/minio.lua) under supplier-portal/<namespace>/<po uuid>/<document uuid>, never to the
    public CMS media library. The bucket is SUPPLIER_PORTAL_BUCKET when set (use a private one), else
    MINIO_BUCKET. Nobody is ever given a MinIO URL: downloads go through
    GET /api/v2/public/supplier-portal/files/:token, where the token is an HMAC-signed link for one document and
    one person that expires after 2 minutes (lib/supplier-portal.lua signToken / verifyToken), and the route
    checks again that the person may still see the document before streaming it.

    Virus scanning: when SUPPLIER_PORTAL_CLAMAV is set (host:port of a clamd), every upload is streamed to it
    (INSTREAM) first; an infected file is refused, and a scanner that can't be reached refuses the upload too
    (fail closed). Unset: files are stored as not_scanned (the type, size and PDF-script checks still apply).
]]

local Rules = require("lib.supplier-portal")

local Files = {}

local function env(name)
    local v = os.getenv(name)
    if v == nil then return nil end
    v = v:match("^%s*(.-)%s*$")
    return v ~= "" and v or nil
end

function Files.hmac(key, msg)
    local h = assert(require("resty.openssl.hmac").new(key, "sha256"))
    return h:final(msg)
end

-- A key for download links only, derived from JWT_SECRET_KEY (so it changes when that is rotated).
function Files.linkKey()
    local secret = env("JWT_SECRET_KEY") or error("JWT_SECRET_KEY not configured")
    return Files.hmac(secret, "opsapi:supplier-portal:download-links:v1")
end

function Files.sha256hex(content)
    local d = assert(require("resty.openssl.digest").new("sha256"))
    local raw = d:final(content)
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function Files.client()
    local Minio = require("helper.minio")
    local c = Minio.new({ bucket = env("SUPPLIER_PORTAL_BUCKET") or env("MINIO_BUCKET"),
                          max_file_size = Rules.MAX_FILE_BYTES + 1 })
    local ok = c:validate()
    if not ok then return nil end
    return c
end

function Files.configured()
    return Files.client() ~= nil
end

function Files.key(ns_id, po_uuid, doc_uuid)
    return ("supplier-portal/%s/%s/%s"):format(tostring(ns_id), tostring(po_uuid), tostring(doc_uuid))
end

--- Store content. → { bucket, key } | nil, message
function Files.put(key, content, content_type)
    local c = Files.client()
    if not c then return nil, "File storage isn't set up here" end
    local _, err, info = c:upload({ content = content, filename = "file", content_type = content_type },
        { object_key = key, validate_type = false, max_size = Rules.MAX_FILE_BYTES + 1 })
    if not info then
        ngx.log(ngx.ERR, "[supplier-portal] store failed: ", tostring(err))
        return nil, "The file couldn't be stored - try again shortly"
    end
    return { bucket = info.bucket, key = info.key }
end

function Files.get(bucket, key)
    local c = Files.client()
    if not c then return nil, "File storage isn't set up here" end
    local body, err = c:get(key, bucket)
    if not body then
        ngx.log(ngx.ERR, "[supplier-portal] read failed: ", tostring(err))
        return nil, "The file couldn't be read - try again shortly"
    end
    return body
end

function Files.remove(bucket, key)
    local c = Files.client()
    if c then pcall(c.delete, c, key, bucket) end
end

--- Virus-scan hook. → "clean" | "not_scanned" | nil, message (infected or scanner down: refuse the upload)
function Files.scan(content)
    local target = env("SUPPLIER_PORTAL_CLAMAV")
    if not target then return "not_scanned" end
    local host, port = target:match("^([^:]+):?(%d*)$")
    if not host then return nil, "The virus scanner isn't set up correctly" end
    local sock = ngx.socket.tcp()
    sock:settimeout(30000)
    local ok, err = sock:connect(host, tonumber(port) or 3310)
    if not ok then
        ngx.log(ngx.ERR, "[supplier-portal] clamd unreachable: ", tostring(err))
        return nil, "The virus scanner isn't available - try again shortly"
    end
    local function u32(n)
        return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    end
    sock:send("zINSTREAM\0")
    local chunk = 65536
    for i = 1, #content, chunk do
        local part = content:sub(i, i + chunk - 1)
        sock:send(u32(#part) .. part)
    end
    sock:send(u32(0))
    local reply = sock:receive("*a") or ""
    sock:close()
    reply = reply:gsub("%z", "")
    if reply:find("OK$") then return "clean" end
    if reply:find("FOUND") then
        ngx.log(ngx.WARN, "[supplier-portal] upload refused by clamd: ", reply)
        return nil, "This file looks infected, so it wasn't uploaded"
    end
    ngx.log(ngx.ERR, "[supplier-portal] clamd said: ", reply)
    return nil, "The virus scanner couldn't check this file - try again shortly"
end

function Files.signLink(doc_uuid, user_uuid)
    local now = ngx.time()
    local token = Rules.signToken(doc_uuid, user_uuid, now, Rules.LINK_SECONDS, Files.linkKey(), Files.hmac)
    return { path = "/api/v2/public/supplier-portal/files/" .. token, expires_in = Rules.LINK_SECONDS,
             expires_at = now + Rules.LINK_SECONDS }
end

function Files.verifyLink(token)
    return Rules.verifyToken(token, ngx.time(), Files.linkKey(), Files.hmac)
end

return Files
