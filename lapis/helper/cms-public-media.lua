--[[
    CMS public media — the public www S3 website bucket as a media library store.

    When configured (CMS_PUBLIC_S3_*), library images go to this bucket and get
    a URL on CMS_PUBLIC_BASE_URL (e.g. https://www.workstation.co.uk/…) that the
    public site can embed with no site rebuild. Otherwise lib/media-library.lua
    uses the deployment's own MinIO.

    Env (secrets from Vault on workstation-opsapi):
      CMS_PUBLIC_S3_BUCKET       e.g. workstation-website
      CMS_PUBLIC_S3_ACCESS_KEY   IAM key with s3:PutObject + s3:DeleteObject on that bucket
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

local function env(name, fallback)
    local v = Global.getEnvVar(name)
    if v and v ~= "" then return v end
    return fallback
end

local function keys()
    return env("CMS_PUBLIC_S3_ACCESS_KEY") or env("AWS_ACCESS_KEY_ID"),
        env("CMS_PUBLIC_S3_SECRET_KEY") or env("AWS_SECRET_ACCESS_KEY")
end

--- True when Vault / env has enough to reach the public website bucket.
function M.configured()
    local key, secret = keys()
    return env("CMS_PUBLIC_S3_BUCKET") ~= nil and key ~= nil and secret ~= nil
end

function M.base_url()
    local base = env("CMS_PUBLIC_BASE_URL", "https://www.workstation.co.uk")
    return (base:gsub("/+$", ""))
end

--- The public website's address when CMS_PUBLIC_BASE_URL is set (no default):
-- lets the dashboard preview site-relative image paths such as /img/x.jpg.
function M.site_url()
    local base = env("CMS_PUBLIC_BASE_URL")
    return base and (base:gsub("/+$", "")) or nil
end

function M.bucket()
    return env("CMS_PUBLIC_S3_BUCKET")
end

--- S3 client for the website bucket (nil when not configured).
function M.client()
    if not M.configured() then return nil end
    local region = env("CMS_PUBLIC_S3_REGION", "eu-west-2")
    local key, secret = keys()
    return MinioClient.new({
        endpoint = env("CMS_PUBLIC_S3_ENDPOINT", "https://s3." .. region .. ".amazonaws.com"),
        access_key = key,
        secret_key = secret,
        bucket = M.bucket(),
        region = region,
        public_url = M.base_url(),
    })
end

return M
