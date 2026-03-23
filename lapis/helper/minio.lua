--[[
    MinIO/S3 Client Helper
    ======================

    Direct S3-compatible storage client for MinIO uploads.
    Uses AWS Signature Version 4 for authentication.

    Features:
    - Direct upload to MinIO without intermediary services
    - AWS Signature V4 authentication
    - Automatic content type detection
    - File validation (type, size)
    - Secure URL generation
    - Support for presigned URLs

    Configuration via environment variables:
    - MINIO_ENDPOINT: MinIO server URL (e.g., https://s3.example.com)
    - MINIO_ACCESS_KEY: Access key ID
    - MINIO_SECRET_KEY: Secret access key
    - MINIO_BUCKET: Default bucket name
    - MINIO_REGION: Region (default: us-east-1)
]]

local http = require("resty.http")
local resty_sha256 = require("resty.sha256")
local resty_hmac = require("resty.hmac")
local resty_string = require("resty.string")
local cjson = require("cjson.safe")

local MinioClient = {}
MinioClient.__index = MinioClient

--------------------------------------------------------------------------------
-- DNS Resolution Cache (module-level, shared across all MinioClient instances)
--
-- OpenResty cosockets rely on the nginx `resolver` directive for DNS, which can
-- fail intermittently in Kubernetes (cached NXDOMAIN, CoreDNS not ready, etc.).
-- This resolver uses resty.dns.resolver to query CoreDNS directly and caches
-- results for 30 seconds. Falls back to the original hostname on failure so the
-- nginx resolver still gets a chance.
--
-- Environment detection:
--   K8s  -> /var/run/secrets/kubernetes.io/serviceaccount exists
--           Uses resty.dns.resolver with CoreDNS from /etc/resolv.conf
--   Docker -> No K8s service account
--           Skips resty.dns.resolver entirely; relies on nginx resolver + Docker DNS
--------------------------------------------------------------------------------
local _dns_cache = {}       -- { [hostname] = { ip = "...", expires = ngx.now() + ttl } }
local DNS_CACHE_TTL = 30    -- seconds
local MAX_CNAME_DEPTH = 5   -- prevent infinite CNAME loops

-- Detect Kubernetes environment (runs once at module load)
local _is_kubernetes = nil

local function is_kubernetes()
    if _is_kubernetes ~= nil then return _is_kubernetes end
    -- K8s mounts a service account token in every pod
    local ok, f = pcall(io.open, "/var/run/secrets/kubernetes.io/serviceaccount/token", "r")
    if ok and f then
        f:close()
        _is_kubernetes = true
    else
        _is_kubernetes = false
    end
    return _is_kubernetes
end

-- Cache the resty.dns.resolver module (loaded once)
local _dns_module
local _dns_module_loaded = false

local function get_dns_module()
    if _dns_module_loaded then return _dns_module end
    _dns_module_loaded = true
    local ok, mod = pcall(require, "resty.dns.resolver")
    if ok then
        _dns_module = mod
    else
        ngx.log(ngx.WARN, "[MinIO DNS] resty.dns.resolver not available: ", tostring(mod))
    end
    return _dns_module
end

--- Read nameserver IPs from /etc/resolv.conf.
-- Re-reads if the previous attempt found no nameservers (handles startup race).
-- Filters out 127.x.x.x addresses (Docker embedded DNS) since resty.dns.resolver
-- cannot reliably query Docker's userland DNS proxy via cosockets.
local _nameservers
local function get_nameservers()
    if _nameservers and #_nameservers > 0 then return _nameservers end

    local servers = {}
    local ok, f_or_err = pcall(io.open, "/etc/resolv.conf", "r")
    if ok and f_or_err then
        local f = f_or_err
        for line in f:lines() do
            local ip = line:match("^%s*nameserver%s+([%d%.]+)")
            if ip and not ip:match("^127%.") then
                servers[#servers + 1] = ip
            end
        end
        f:close()
    end

    if #servers > 0 then
        _nameservers = servers
    else
        -- No non-loopback nameservers found; don't cache so we retry next time
        return nil
    end
    return _nameservers
end

--- Resolve a hostname to an IP address using resty.dns.resolver.
-- Only active in Kubernetes environments. In Docker, returns nil immediately
-- so the caller falls back to the original hostname (Docker DNS handles it).
-- Results are cached for DNS_CACHE_TTL seconds.
-- @param hostname string The hostname to resolve
-- @param depth number (internal) Current CNAME recursion depth
local function resolve_host(hostname, depth)
    depth = depth or 0

    -- Guard: nil or empty hostname
    if not hostname or hostname == "" then
        return nil
    end

    -- Skip resolution for IPv4 addresses
    if hostname:match("^%d+%.%d+%.%d+%.%d+$") then
        return hostname
    end

    -- Skip resolution for IPv6 addresses (bracketed or raw)
    if hostname:match("^%[") or hostname:match(":.*:") then
        return hostname
    end

    -- In Docker (non-K8s), skip resty.dns.resolver entirely.
    -- Docker's embedded DNS (127.0.0.11) handles resolution at the TCP layer,
    -- and resty.dns.resolver can't reliably query it via UDP cosockets.
    if not is_kubernetes() then
        return nil
    end

    -- Check cache
    local cached = _dns_cache[hostname]
    if cached and cached.expires > ngx.now() then
        return cached.ip
    end

    -- Get the DNS module
    local dns = get_dns_module()
    if not dns then
        return nil
    end

    -- Get usable nameservers (non-loopback)
    local nameservers = get_nameservers()
    if not nameservers then
        ngx.log(ngx.WARN, "[MinIO DNS] No usable nameservers found, skipping resolution")
        return nil
    end

    -- Create resolver instance
    local r, err = dns:new({
        nameservers = nameservers,
        retrans = 2,
        timeout = 2000,  -- 2 seconds
    })
    if not r then
        ngx.log(ngx.WARN, "[MinIO DNS] Failed to create resolver: ", tostring(err))
        return nil
    end

    -- Query for A record
    local answers, resolve_err = r:query(hostname, { qtype = 1 })
    if not answers then
        ngx.log(ngx.WARN, "[MinIO DNS] Query failed for ", hostname, ": ", tostring(resolve_err))
        return nil
    end

    if answers.errcode then
        ngx.log(ngx.WARN, "[MinIO DNS] DNS error for ", hostname,
            " (code=", tostring(answers.errcode), "): ", tostring(answers.errstr))
        return nil
    end

    -- Pick first A record
    for _, ans in ipairs(answers) do
        if ans.type == 1 and ans.address then
            _dns_cache[hostname] = {
                ip = ans.address,
                expires = ngx.now() + DNS_CACHE_TTL,
            }
            ngx.log(ngx.DEBUG, "[MinIO DNS] Resolved ", hostname, " -> ", ans.address)
            return ans.address
        end
    end

    -- Follow CNAME chain with depth limit
    if depth < MAX_CNAME_DEPTH then
        for _, ans in ipairs(answers) do
            if ans.type == 5 and ans.cname then
                ngx.log(ngx.DEBUG, "[MinIO DNS] Following CNAME ", hostname, " -> ", ans.cname)
                return resolve_host(ans.cname, depth + 1)
            end
        end
    elseif depth >= MAX_CNAME_DEPTH then
        ngx.log(ngx.WARN, "[MinIO DNS] CNAME depth limit reached for ", hostname)
    end

    ngx.log(ngx.WARN, "[MinIO DNS] No A record found for ", hostname)
    return nil
end

-- Configuration defaults
local DEFAULT_REGION = "us-east-1"
local MAX_FILE_SIZE = 10 * 1024 * 1024  -- 10MB default max
local ALLOWED_MIME_TYPES = {
    -- Images
    ["image/jpeg"] = { extensions = { "jpg", "jpeg" }, category = "image" },
    ["image/png"] = { extensions = { "png" }, category = "image" },
    ["image/gif"] = { extensions = { "gif" }, category = "image" },
    ["image/webp"] = { extensions = { "webp" }, category = "image" },
    ["image/svg+xml"] = { extensions = { "svg" }, category = "image" },
    ["image/bmp"] = { extensions = { "bmp" }, category = "image" },
    ["image/tiff"] = { extensions = { "tiff", "tif" }, category = "image" },
    ["image/heic"] = { extensions = { "heic" }, category = "image" },
    ["image/heif"] = { extensions = { "heif" }, category = "image" },

    -- Documents
    ["application/pdf"] = { extensions = { "pdf" }, category = "document" },
    ["application/msword"] = { extensions = { "doc" }, category = "document" },
    ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = { extensions = { "docx" }, category = "document" },
    ["application/vnd.ms-excel"] = { extensions = { "xls" }, category = "document" },
    ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"] = { extensions = { "xlsx" }, category = "document" },
    ["application/vnd.ms-powerpoint"] = { extensions = { "ppt" }, category = "document" },
    ["application/vnd.openxmlformats-officedocument.presentationml.presentation"] = { extensions = { "pptx" }, category = "document" },
    ["text/plain"] = { extensions = { "txt", "md" }, category = "document" },
    ["text/markdown"] = { extensions = { "md", "markdown" }, category = "document" },
    ["text/csv"] = { extensions = { "csv" }, category = "document" },

    -- Archives
    ["application/zip"] = { extensions = { "zip" }, category = "archive" },
    ["application/x-rar-compressed"] = { extensions = { "rar" }, category = "archive" },
    ["application/x-7z-compressed"] = { extensions = { "7z" }, category = "archive" },
    ["application/gzip"] = { extensions = { "gz" }, category = "archive" },

    -- Audio/Video
    ["audio/mpeg"] = { extensions = { "mp3" }, category = "audio" },
    ["audio/wav"] = { extensions = { "wav" }, category = "audio" },
    ["video/mp4"] = { extensions = { "mp4" }, category = "video" },
    ["video/webm"] = { extensions = { "webm" }, category = "video" },

    -- Generic
    ["application/octet-stream"] = { extensions = { "*" }, category = "binary" }
}

-- Extension to MIME type mapping
local EXTENSION_TO_MIME = {}
for mime, config in pairs(ALLOWED_MIME_TYPES) do
    for _, ext in ipairs(config.extensions) do
        if ext ~= "*" then
            EXTENSION_TO_MIME[ext:lower()] = mime
        end
    end
end

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

--- Get environment variable with optional default
local function getEnv(name, default)
    local value = os.getenv(name)
    if value and value ~= "" then
        return value:match("^%s*(.-)%s*$")  -- trim
    end
    return default
end

--- Generate SHA256 hash
local function sha256(data)
    local sha = resty_sha256:new()
    sha:update(data or "")
    return resty_string.to_hex(sha:final())
end

--- Generate HMAC-SHA256
local function hmac_sha256(key, data)
    local hmac = resty_hmac:new(key, resty_hmac.ALGOS.SHA256)
    hmac:update(data)
    return hmac:final()
end

--- Generate HMAC-SHA256 hex
local function hmac_sha256_hex(key, data)
    return resty_string.to_hex(hmac_sha256(key, data))
end

--- Get current UTC timestamp components
local function getUtcTime()
    local now = ngx.time()
    local date = os.date("!*t", now)
    return {
        timestamp = os.date("!%Y%m%dT%H%M%SZ", now),
        date = os.date("!%Y%m%d", now),
        year = date.year,
        month = date.month,
        day = date.day,
        hour = date.hour,
        min = date.min,
        sec = date.sec
    }
end

--- URL encode a string (S3-compatible)
local function urlEncode(str)
    if not str then return "" end
    str = tostring(str)
    return str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

--- Get content type from filename
local function getContentType(filename)
    if not filename then return "application/octet-stream" end
    local ext = filename:match("%.([^%.]+)$")
    if ext then
        return EXTENSION_TO_MIME[ext:lower()] or "application/octet-stream"
    end
    return "application/octet-stream"
end

--- Generate a unique object key
local function generateObjectKey(filename, prefix)
    local uuid = string.format("%s-%s-%s-%s-%s",
        string.sub(ngx.md5(tostring(math.random(1e9)) .. tostring(ngx.time())), 1, 8),
        string.sub(ngx.md5(tostring(ngx.time())), 1, 4),
        string.sub(ngx.md5(tostring(math.random(1e9))), 1, 4),
        string.sub(ngx.md5(tostring(ngx.now() * 1000)), 1, 4),
        string.sub(ngx.md5(tostring(math.random(1e9))), 1, 12)
    )

    local ext = filename and filename:match("%.([^%.]+)$") or "bin"
    local date_prefix = os.date("!%Y/%m/%d")

    if prefix and prefix ~= "" then
        return string.format("%s/%s/%s.%s", prefix, date_prefix, uuid, ext)
    end
    return string.format("%s/%s.%s", date_prefix, uuid, ext)
end

--------------------------------------------------------------------------------
-- AWS Signature Version 4
--------------------------------------------------------------------------------

--- Create AWS Signature V4 signing key
local function getSigningKey(secret_key, date, region, service)
    local k_date = hmac_sha256("AWS4" .. secret_key, date)
    local k_region = hmac_sha256(k_date, region)
    local k_service = hmac_sha256(k_region, service)
    local k_signing = hmac_sha256(k_service, "aws4_request")
    return k_signing
end

--- Create canonical request
local function createCanonicalRequest(method, uri, query_string, headers, signed_headers, payload_hash)
    local canonical_headers = ""
    local header_list = {}

    for name, value in pairs(headers) do
        table.insert(header_list, { name = name:lower(), value = value })
    end

    table.sort(header_list, function(a, b) return a.name < b.name end)

    for _, h in ipairs(header_list) do
        canonical_headers = canonical_headers .. h.name .. ":" .. h.value .. "\n"
    end

    return table.concat({
        method,
        uri,
        query_string or "",
        canonical_headers,
        signed_headers,
        payload_hash
    }, "\n")
end

--- Create string to sign
local function createStringToSign(timestamp, date, region, service, canonical_request)
    local scope = string.format("%s/%s/%s/aws4_request", date, region, service)
    return table.concat({
        "AWS4-HMAC-SHA256",
        timestamp,
        scope,
        sha256(canonical_request)
    }, "\n")
end

--- Generate Authorization header
local function generateAuthHeader(access_key, secret_key, region, service, method, uri, query_string, headers, payload)
    local time = getUtcTime()
    local payload_hash = sha256(payload or "")

    -- Build signed headers list
    local signed_headers_list = {}
    for name, _ in pairs(headers) do
        table.insert(signed_headers_list, name:lower())
    end
    table.sort(signed_headers_list)
    local signed_headers = table.concat(signed_headers_list, ";")

    -- Create canonical request
    local canonical_request = createCanonicalRequest(
        method, uri, query_string, headers, signed_headers, payload_hash
    )

    -- Create string to sign
    local string_to_sign = createStringToSign(
        time.timestamp, time.date, region, service, canonical_request
    )

    -- Calculate signature
    local signing_key = getSigningKey(secret_key, time.date, region, service)
    local signature = hmac_sha256_hex(signing_key, string_to_sign)

    -- Build authorization header
    local credential = string.format("%s/%s/%s/%s/aws4_request",
        access_key, time.date, region, service)

    return string.format(
        "AWS4-HMAC-SHA256 Credential=%s, SignedHeaders=%s, Signature=%s",
        credential, signed_headers, signature
    ), time.timestamp, payload_hash
end

--------------------------------------------------------------------------------
-- MinIO Client Methods
--------------------------------------------------------------------------------

--- Create a new MinIO client instance
function MinioClient.new(config)
    local self = setmetatable({}, MinioClient)

    config = config or {}

    self.endpoint = config.endpoint or getEnv("MINIO_ENDPOINT")
    self.access_key = config.access_key or getEnv("MINIO_ACCESS_KEY")
    self.secret_key = config.secret_key or getEnv("MINIO_SECRET_KEY")
    self.bucket = config.bucket or getEnv("MINIO_BUCKET")
    self.region = config.region or getEnv("MINIO_REGION") or DEFAULT_REGION
    self.max_file_size = config.max_file_size or MAX_FILE_SIZE
    self.allowed_types = config.allowed_types or ALLOWED_MIME_TYPES

    -- Public URL for browser access (different from internal endpoint)
    -- MINIO_ENDPOINT_WEB_EXTERNAL should be set to the externally accessible URL
    -- e.g., http://127.0.0.1:9000 or https://s3.yourdomain.com
    self.public_url = config.public_url or getEnv("MINIO_ENDPOINT_WEB_EXTERNAL") or self.endpoint

    -- Parse endpoint to get host, hostname, and port
    if self.endpoint then
        self.host = self.endpoint:gsub("^https?://", ""):gsub("/$", "")
        self.use_ssl = self.endpoint:match("^https") ~= nil

        -- Extract hostname and port separately for DNS resolution
        local host_port = self.host
        local hostname, port = host_port:match("^(.+):(%d+)$")
        if not hostname then
            hostname = host_port
            port = self.use_ssl and "443" or "80"
        end
        self._hostname = hostname
        self._port = port
        self._scheme = self.use_ssl and "https" or "http"
    end

    return self
end

--- Build an endpoint URL with DNS-resolved IP for the current request.
-- Resolves the hostname via resty.dns.resolver and returns a URL using the IP.
-- The original hostname is preserved in self.host for the Host header.
-- Falls back to the original endpoint if resolution fails.
function MinioClient:_resolved_endpoint()
    if not self._hostname then
        return self.endpoint
    end

    local ip = resolve_host(self._hostname)
    if not ip then
        return self.endpoint  -- fallback: let nginx resolver try
    end

    return self._scheme .. "://" .. ip .. ":" .. self._port
end

--- Validate client configuration
function MinioClient:validate()
    local errors = {}

    if not self.endpoint or self.endpoint == "" then
        table.insert(errors, "MINIO_ENDPOINT is not configured")
    end
    if not self.access_key or self.access_key == "" then
        table.insert(errors, "MINIO_ACCESS_KEY is not configured")
    end
    if not self.secret_key or self.secret_key == "" then
        table.insert(errors, "MINIO_SECRET_KEY is not configured")
    end
    if not self.bucket or self.bucket == "" then
        table.insert(errors, "MINIO_BUCKET is not configured")
    end

    if #errors > 0 then
        return false, table.concat(errors, "; ")
    end
    return true
end

--- Validate file before upload
function MinioClient:validateFile(file, options)
    options = options or {}

    if not file then
        return false, "No file provided"
    end

    if not file.content or file.content == "" then
        return false, "File content is empty"
    end

    local file_size = #file.content
    local max_size = options.max_size or self.max_file_size

    if file_size > max_size then
        return false, string.format("File size (%d bytes) exceeds maximum allowed (%d bytes)",
            file_size, max_size)
    end

    -- Validate content type if restrictions are enabled
    if options.validate_type ~= false then
        local content_type = file.content_type or getContentType(file.filename)
        local type_config = self.allowed_types[content_type]

        if not type_config and content_type ~= "application/octet-stream" then
            return false, string.format("File type '%s' is not allowed", content_type)
        end

        -- Validate category if specified
        if options.allowed_categories then
            local allowed = false
            for _, cat in ipairs(options.allowed_categories) do
                if type_config and type_config.category == cat then
                    allowed = true
                    break
                end
            end
            if not allowed then
                return false, string.format("File category is not allowed. Allowed: %s",
                    table.concat(options.allowed_categories, ", "))
            end
        end
    end

    return true
end

--- Check if a bucket exists
-- @param bucket string The bucket name to check
-- @return boolean True if bucket exists
function MinioClient:bucketExists(bucket)
    bucket = bucket or self.bucket

    local valid, config_err = self:validate()
    if not valid then
        return false, config_err
    end

    local uri = "/" .. bucket
    local headers = {
        ["Host"] = self.host,
        ["x-amz-content-sha256"] = sha256(""),
        ["x-amz-date"] = getUtcTime().timestamp
    }

    local auth_header, timestamp, _ = generateAuthHeader(
        self.access_key,
        self.secret_key,
        self.region,
        "s3",
        "HEAD",
        uri,
        "",
        headers,
        ""
    )

    headers["Authorization"] = auth_header
    headers["x-amz-date"] = timestamp

    local httpc = http.new()
    httpc:set_timeout(5000)

    local url = self:_resolved_endpoint() .. uri
    local res, _ = httpc:request_uri(url, {
        method = "HEAD",
        headers = headers,
        ssl_verify = false
    })

    return res and res.status == 200
end

--- Create a bucket if it doesn't exist
-- @param bucket string The bucket name to create
-- @return boolean Success status
-- @return string|nil Error message if failed
function MinioClient:createBucket(bucket)
    bucket = bucket or self.bucket

    local valid, config_err = self:validate()
    if not valid then
        return false, config_err
    end

    -- Check if bucket already exists
    if self:bucketExists(bucket) then
        ngx.log(ngx.DEBUG, "[MinIO] Bucket already exists: ", bucket)
        return true
    end

    ngx.log(ngx.INFO, "[MinIO] Creating bucket: ", bucket)

    local uri = "/" .. bucket
    local headers = {
        ["Host"] = self.host,
        ["x-amz-content-sha256"] = sha256(""),
        ["x-amz-date"] = getUtcTime().timestamp
    }

    local auth_header, timestamp, _ = generateAuthHeader(
        self.access_key,
        self.secret_key,
        self.region,
        "s3",
        "PUT",
        uri,
        "",
        headers,
        ""
    )

    headers["Authorization"] = auth_header
    headers["x-amz-date"] = timestamp

    local httpc = http.new()
    httpc:set_timeout(10000)

    local url = self:_resolved_endpoint() .. uri
    local res, err = httpc:request_uri(url, {
        method = "PUT",
        headers = headers,
        ssl_verify = false
    })

    if not res then
        ngx.log(ngx.ERR, "[MinIO] Create bucket request failed: ", err)
        return false, "Create bucket request failed: " .. tostring(err)
    end

    if res.status >= 200 and res.status < 300 then
        ngx.log(ngx.INFO, "[MinIO] Bucket created successfully: ", bucket)
        return true
    elseif res.status == 409 then
        -- Bucket already exists (race condition)
        ngx.log(ngx.DEBUG, "[MinIO] Bucket already exists: ", bucket)
        return true
    else
        local error_body = res.body or "Unknown error"
        ngx.log(ngx.ERR, "[MinIO] Create bucket failed [", res.status, "]: ", error_body)
        return false, string.format("Create bucket failed (HTTP %d): %s", res.status, error_body)
    end
end

--- Upload a file to MinIO
-- @param file table File object with { content, filename, content_type? }
-- @param options table Optional settings { prefix?, bucket?, validate?, auto_create_bucket? }
-- @return string|nil URL of uploaded file
-- @return string|nil Error message if failed
function MinioClient:upload(file, options)
    options = options or {}

    -- Validate configuration
    local valid, config_err = self:validate()
    if not valid then
        ngx.log(ngx.ERR, "[MinIO] Configuration error: ", config_err)
        return nil, "Storage configuration error: " .. config_err
    end

    -- Validate file
    local file_valid, file_err = self:validateFile(file, options)
    if not file_valid then
        ngx.log(ngx.WARN, "[MinIO] File validation failed: ", file_err)
        return nil, file_err
    end

    -- Prepare upload parameters
    local bucket = options.bucket or self.bucket

    -- Auto-create bucket if it doesn't exist (default: true)
    local auto_create = options.auto_create_bucket
    if auto_create == nil then
        auto_create = true  -- Default to auto-create
    end

    if auto_create then
        local bucket_ok, bucket_err = self:createBucket(bucket)
        if not bucket_ok then
            return nil, "Failed to create bucket: " .. (bucket_err or "Unknown error")
        end
    end
    local object_key = options.object_key or generateObjectKey(file.filename, options.prefix)
    local content_type = file.content_type or getContentType(file.filename)
    local content = file.content

    -- Build request
    local uri = "/" .. bucket .. "/" .. object_key
    local headers = {
        ["Host"] = self.host,
        ["Content-Type"] = content_type,
        ["Content-Length"] = tostring(#content),
        ["x-amz-content-sha256"] = sha256(content),
        ["x-amz-date"] = getUtcTime().timestamp
    }

    -- Add custom metadata if provided
    if options.metadata then
        for key, value in pairs(options.metadata) do
            headers["x-amz-meta-" .. key:lower()] = tostring(value)
        end
    end

    -- Generate authorization
    local auth_header, timestamp, _ = generateAuthHeader(
        self.access_key,
        self.secret_key,
        self.region,
        "s3",
        "PUT",
        uri,
        "",
        headers,
        content
    )

    headers["Authorization"] = auth_header
    headers["x-amz-date"] = timestamp

    -- Make request
    local httpc = http.new()
    httpc:set_timeout(30000)  -- 30 second timeout

    local url = self:_resolved_endpoint() .. uri

    ngx.log(ngx.DEBUG, "[MinIO] Uploading to: ", url)

    local res, err = httpc:request_uri(url, {
        method = "PUT",
        body = content,
        headers = headers,
        ssl_verify = false  -- Set to true in production with proper CA
    })

    if not res then
        ngx.log(ngx.ERR, "[MinIO] Upload request failed: ", err)
        return nil, "Upload request failed: " .. tostring(err)
    end

    if res.status >= 200 and res.status < 300 then
        -- Success - construct public URL (use public_url for browser access)
        local public_url = (self.public_url or self.endpoint) .. "/" .. bucket .. "/" .. object_key

        ngx.log(ngx.INFO, "[MinIO] Upload successful: ", object_key)
        ngx.log(ngx.INFO, "[MinIO] Public URL: ", public_url)

        return public_url, nil, {
            key = object_key,
            bucket = bucket,
            size = #content,
            content_type = content_type,
            etag = res.headers["ETag"]
        }
    else
        local error_body = res.body or "Unknown error"
        ngx.log(ngx.ERR, "[MinIO] Upload failed [", res.status, "]: ", error_body)
        return nil, string.format("Upload failed (HTTP %d): %s", res.status, error_body)
    end
end

--- Delete an object from MinIO
-- @param object_key string The object key to delete
-- @param bucket string Optional bucket (uses default if not provided)
-- @return boolean Success status
-- @return string|nil Error message if failed
function MinioClient:delete(object_key, bucket)
    bucket = bucket or self.bucket

    local valid, config_err = self:validate()
    if not valid then
        return false, config_err
    end

    local uri = "/" .. bucket .. "/" .. object_key
    local headers = {
        ["Host"] = self.host,
        ["x-amz-content-sha256"] = sha256(""),
        ["x-amz-date"] = getUtcTime().timestamp
    }

    local auth_header, timestamp, _ = generateAuthHeader(
        self.access_key,
        self.secret_key,
        self.region,
        "s3",
        "DELETE",
        uri,
        "",
        headers,
        ""
    )

    headers["Authorization"] = auth_header
    headers["x-amz-date"] = timestamp

    local httpc = http.new()
    httpc:set_timeout(10000)

    local url = self:_resolved_endpoint() .. uri
    local res, err = httpc:request_uri(url, {
        method = "DELETE",
        headers = headers,
        ssl_verify = false
    })

    if not res then
        return false, "Delete request failed: " .. tostring(err)
    end

    if res.status == 204 or res.status == 200 then
        ngx.log(ngx.INFO, "[MinIO] Deleted: ", object_key)
        return true
    else
        return false, string.format("Delete failed (HTTP %d)", res.status)
    end
end

--- Check if an object exists
-- @param object_key string The object key to check
-- @param bucket string Optional bucket
-- @return boolean Exists status
-- @return table|nil Object metadata if exists
function MinioClient:exists(object_key, bucket)
    bucket = bucket or self.bucket

    local valid, config_err = self:validate()
    if not valid then
        return false, nil, config_err
    end

    local uri = "/" .. bucket .. "/" .. object_key
    local headers = {
        ["Host"] = self.host,
        ["x-amz-content-sha256"] = sha256(""),
        ["x-amz-date"] = getUtcTime().timestamp
    }

    local auth_header, timestamp, _ = generateAuthHeader(
        self.access_key,
        self.secret_key,
        self.region,
        "s3",
        "HEAD",
        uri,
        "",
        headers,
        ""
    )

    headers["Authorization"] = auth_header
    headers["x-amz-date"] = timestamp

    local httpc = http.new()
    httpc:set_timeout(5000)

    local url = self:_resolved_endpoint() .. uri
    local res, _ = httpc:request_uri(url, {
        method = "HEAD",
        headers = headers,
        ssl_verify = false
    })

    if res and res.status == 200 then
        return true, {
            content_type = res.headers["Content-Type"],
            content_length = tonumber(res.headers["Content-Length"]),
            etag = res.headers["ETag"],
            last_modified = res.headers["Last-Modified"]
        }
    end

    return false, nil
end

--- Generate a presigned URL for download
-- @param object_key string The object key
-- @param expires_in number Seconds until expiration (default 3600)
-- @param bucket string Optional bucket
-- @return string|nil Presigned URL
function MinioClient:getPresignedUrl(object_key, expires_in, bucket)
    bucket = bucket or self.bucket
    expires_in = expires_in or 3600

    local valid, config_err = self:validate()
    if not valid then
        return nil, config_err
    end

    local time = getUtcTime()
    local credential = string.format("%s/%s/%s/s3/aws4_request",
        self.access_key, time.date, self.region)

    local uri = "/" .. bucket .. "/" .. object_key

    -- Build query string
    local query_params = {
        ["X-Amz-Algorithm"] = "AWS4-HMAC-SHA256",
        ["X-Amz-Credential"] = credential,
        ["X-Amz-Date"] = time.timestamp,
        ["X-Amz-Expires"] = tostring(expires_in),
        ["X-Amz-SignedHeaders"] = "host"
    }

    -- Sort and encode query string
    local query_parts = {}
    local sorted_keys = {}
    for k in pairs(query_params) do
        table.insert(sorted_keys, k)
    end
    table.sort(sorted_keys)

    for _, k in ipairs(sorted_keys) do
        table.insert(query_parts, urlEncode(k) .. "=" .. urlEncode(query_params[k]))
    end
    local query_string = table.concat(query_parts, "&")

    -- Create canonical request
    local headers = { ["host"] = self.host }
    local canonical_request = createCanonicalRequest(
        "GET", uri, query_string, headers, "host", "UNSIGNED-PAYLOAD"
    )

    -- Create string to sign
    local string_to_sign = createStringToSign(
        time.timestamp, time.date, self.region, "s3", canonical_request
    )

    -- Calculate signature
    local signing_key = getSigningKey(self.secret_key, time.date, self.region, "s3")
    local signature = hmac_sha256_hex(signing_key, string_to_sign)

    return self.endpoint .. uri .. "?" .. query_string .. "&X-Amz-Signature=" .. signature
end

--- Get content type from filename (public method)
--- @param filename string The filename to get content type for
--- @return string The MIME type
function MinioClient:getContentType(filename)
    return getContentType(filename)
end

--------------------------------------------------------------------------------
-- Module exports
--------------------------------------------------------------------------------

-- Create singleton instance
local default_client = nil

--- Get default client instance
function MinioClient.getDefault()
    if not default_client then
        default_client = MinioClient.new()
    end
    return default_client
end

--- Quick upload function using default client
function MinioClient.quickUpload(file, options)
    return MinioClient.getDefault():upload(file, options)
end

--- Quick delete function using default client
function MinioClient.quickDelete(object_key, bucket)
    return MinioClient.getDefault():delete(object_key, bucket)
end

return MinioClient
