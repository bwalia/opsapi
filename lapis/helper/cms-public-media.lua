--[[
    CMS public media — upload images to the public www S3 website bucket.

    When configured (CMS_PUBLIC_S3_*), editors can upload a featured image and
    get back a URL on CMS_PUBLIC_BASE_URL (e.g. https://www.workstation.co.uk/…)
    that the public site can embed immediately — no git PR / full site rebuild.

    Env (secrets from Vault on workstation-opsapi):
      CMS_PUBLIC_S3_BUCKET       e.g. workstation-website
      CMS_PUBLIC_S3_ACCESS_KEY   IAM key with s3:PutObject on that bucket
      CMS_PUBLIC_S3_SECRET_KEY
      CMS_PUBLIC_S3_REGION       default eu-west-2
      CMS_PUBLIC_S3_ENDPOINT     default https://s3.<region>.amazonaws.com
      CMS_PUBLIC_BASE_URL        default https://www.workstation.co.uk

    Falls back to AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY when the CMS_*
    key pair is unset (same shape as the website deploy secrets).
]]

local MinioClient = require("helper.minio")
local Global = require("helper.global")

local M = {}

local MAX_BYTES = 8 * 1024 * 1024 -- 8 MiB featured / embed images
local ALLOWED_EXT = {
    jpg = true, jpeg = true, png = true, webp = true, gif = true, svg = true,
}
local ALLOWED_MIME = {
    ["image/jpeg"] = true,
    ["image/png"] = true,
    ["image/webp"] = true,
    ["image/gif"] = true,
    ["image/svg+xml"] = true,
}

local function env(name, fallback)
    local v = Global.getEnvVar(name)
    if v and v ~= "" then return v end
    return fallback
end

--- True when Vault / env has enough to reach the public website bucket.
function M.configured()
    local bucket = env("CMS_PUBLIC_S3_BUCKET")
    local key = env("CMS_PUBLIC_S3_ACCESS_KEY") or env("AWS_ACCESS_KEY_ID")
    local secret = env("CMS_PUBLIC_S3_SECRET_KEY") or env("AWS_SECRET_ACCESS_KEY")
    return bucket ~= nil and key ~= nil and secret ~= nil
end

function M.base_url()
    local base = env("CMS_PUBLIC_BASE_URL", "https://www.workstation.co.uk")
    return (base:gsub("/+$", ""))
end

local function sanitize_slug(raw)
    if not raw or raw == "" then return nil end
    local s = tostring(raw):lower()
    s = s:gsub("%s+", "-"):gsub("[^a-z0-9%-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    if s == "" or #s > 120 then return nil end
    return s
end

local function ext_of(filename, content_type)
    local ext = (filename or ""):match("%.([%w]+)$")
    if ext then
        ext = ext:lower()
        if ext == "jpeg" then ext = "jpg" end
        if ALLOWED_EXT[ext] then return ext end
    end
    if content_type == "image/png" then return "png" end
    if content_type == "image/webp" then return "webp" end
    if content_type == "image/gif" then return "gif" end
    if content_type == "image/svg+xml" then return "svg" end
    if content_type == "image/jpeg" then return "jpg" end
    return nil
end

local function sanitize_kind(raw)
    if not raw or raw == "" then return "cover" end
    local s = tostring(raw):lower()
    s = s:gsub("%s+", "-"):gsub("[^a-z0-9%-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    if s == "" or #s > 80 then return "cover" end
    return s
end

local function object_key(opts)
    local ns = sanitize_slug(opts.namespace_slug) or "cms"
    local slug = sanitize_slug(opts.slug)
    local ext = opts.ext
    local kind = sanitize_kind(opts.kind)
    if slug then
        -- Same layout as workstation-website/public/img/blog/<slug>/cover.*
        -- kind=cover for featured; kind=inline-<id> for in-body images.
        return string.format("img/blog/%s/%s.%s", slug, kind, ext)
    end
    local id = (Global.generateUUID() or tostring(ngx.now())):gsub("%-", "")
    return string.format("img/cms/%s/%s.%s", ns, id, ext)
end

--- Upload a Lapis multipart file table to the public website bucket.
-- @param file table  { filename, content, content_type }
-- @param opts table  { slug?, namespace_slug?, kind? }
-- @return table|nil  { url, key, bucket, size, content_type }
-- @return string|nil error
function M.upload(file, opts)
    opts = opts or {}
    if not M.configured() then
        return nil, "Public CMS media is not configured (set CMS_PUBLIC_S3_BUCKET + credentials in Vault)"
    end
    if type(file) ~= "table" or not file.content or file.content == "" then
        return nil, "No file uploaded"
    end

    local size = #file.content
    if size > MAX_BYTES then
        return nil, string.format("Image too large (max %d MB)", MAX_BYTES / (1024 * 1024))
    end

    local ctype = file.content_type or ""
    if ctype ~= "" and not ALLOWED_MIME[ctype] then
        -- Some browsers send empty or octet-stream; fall through to extension check.
        if ctype ~= "application/octet-stream" then
            return nil, "Only image uploads are allowed (jpeg, png, webp, gif, svg)"
        end
    end

    local ext = ext_of(file.filename, ctype)
    if not ext then
        return nil, "Could not determine image type from filename or Content-Type"
    end

    local region = env("CMS_PUBLIC_S3_REGION", "eu-west-2")
    local endpoint = env("CMS_PUBLIC_S3_ENDPOINT", "https://s3." .. region .. ".amazonaws.com")
    local bucket = env("CMS_PUBLIC_S3_BUCKET")
    local access_key = env("CMS_PUBLIC_S3_ACCESS_KEY") or env("AWS_ACCESS_KEY_ID")
    local secret_key = env("CMS_PUBLIC_S3_SECRET_KEY") or env("AWS_SECRET_ACCESS_KEY")

    local client = MinioClient.new({
        endpoint = endpoint,
        access_key = access_key,
        secret_key = secret_key,
        bucket = bucket,
        region = region,
        public_url = M.base_url(), -- rewritten below; path-style unused for www
        max_file_size = MAX_BYTES,
        allowed_types = ALLOWED_MIME,
    })

    local key = object_key({
        slug = opts.slug,
        namespace_slug = opts.namespace_slug,
        kind = opts.kind or "cover",
        ext = ext,
    })

    local _, err, meta = client:upload(file, {
        bucket = bucket,
        object_key = key,
        auto_create_bucket = false,
        metadata = {
            source = "opsapi-cms",
            namespace = tostring(opts.namespace_slug or ""),
        },
    })
    if err then
        return nil, err
    end

    local url = M.base_url() .. "/" .. key
    return {
        url = url,
        key = key,
        bucket = bucket,
        size = meta and meta.size or size,
        content_type = meta and meta.content_type or ctype,
    }
end

return M
