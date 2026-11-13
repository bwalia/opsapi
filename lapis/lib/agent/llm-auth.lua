--[[
    Request signing for the cloud model providers in lib/agent/llm.lua
    ==================================================================

      LlmAuth.sigv4(req)            AWS Signature Version 4 (Bedrock Runtime): returns the
                                    headers to send, Authorization included.
      LlmAuth.google_assertion(sa)  the RS256-signed JWT a Google service account trades for
                                    an OAuth access token (Vertex AI).
      LlmAuth.google_token(sa, fetch)
                                    that access token, cached per service account (per worker)
                                    until a minute before it expires.

    Pure Lua + luaossl (openssl.digest / openssl.hmac / openssl.pkey, already used by
    lib/outbound-webhooks), so the specs run it in plain LuaJIT against AWS's published
    test vectors. Nothing here logs a key, a token or a signature.
]]

local LlmAuth = {}

local function hex(bin)
    return (bin:gsub(".", function(ch) return ("%02x"):format(ch:byte()) end))
end
LlmAuth.hex = hex

function LlmAuth.sha256(data)
    return require("openssl.digest").new("sha256"):final(data or "")
end

function LlmAuth.hmac(key, data)
    return require("openssl.hmac").new(key, "sha256"):final(data)
end

-- ---------------------------------------------------------------------------
-- base64 (ngx.encode_base64 isn't there outside nginx, e.g. in the specs)
-- ---------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function LlmAuth.base64(s)
    if ngx and ngx.encode_base64 then return ngx.encode_base64(s) end
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local q = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
        out[#out + 1] = B64:sub(q[1] + 1, q[1] + 1) .. B64:sub(q[2] + 1, q[2] + 1)
            .. (b and B64:sub(q[3] + 1, q[3] + 1) or "=") .. (c and B64:sub(q[4] + 1, q[4] + 1) or "=")
    end
    return table.concat(out)
end

function LlmAuth.base64url(s)
    return (LlmAuth.base64(s):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

function LlmAuth.unbase64(s)
    if ngx and ngx.decode_base64 then return ngx.decode_base64(s) end
    s = tostring(s or ""):gsub("[^%w%+/]", "")
    local out = {}
    for i = 1, #s, 4 do
        local n, count = 0, 0
        for j = i, i + 3 do
            local v = B64_INDEX[s:sub(j, j)]
            n = n * 64 + (v or 0)
            if v then count = count + 1 end
        end
        local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
        out[#out + 1] = bytes:sub(1, count - 1)
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- AWS Signature Version 4
-- ---------------------------------------------------------------------------

--- RFC 3986 encoding as SigV4 wants it: everything but A-Z a-z 0-9 - _ . ~
function LlmAuth.uri_encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function trim(s)
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
end

--- The signing key: HMAC chain over date, region, service.
function LlmAuth.sigv4_key(secret, date, region, service)
    local k = LlmAuth.hmac("AWS4" .. secret, date)
    k = LlmAuth.hmac(k, region)
    k = LlmAuth.hmac(k, service)
    return LlmAuth.hmac(k, "aws4_request")
end

--- Sign one request.
-- req = { method, host, path (as sent, already percent-encoded), query (table or string, optional),
--         headers (extra headers to sign and send), payload (the exact body string),
--         access_key, secret_key, session_token?, region, service, amz_date? ("YYYYMMDDTHHMMSSZ"),
--         double_encode? (true for every service but S3: the path is encoded once more) }
-- @return headers (every signed header + Authorization), and the signature details for tests
function LlmAuth.sigv4(req)
    local amz_date = req.amz_date or os.date("!%Y%m%dT%H%M%SZ", ngx and ngx.time and ngx.time() or os.time())
    local date = amz_date:sub(1, 8)
    local headers = {}
    for k, v in pairs(req.headers or {}) do headers[k] = v end
    headers["host"] = req.host
    headers["x-amz-date"] = amz_date
    if req.session_token then headers["x-amz-security-token"] = req.session_token end

    local names, canonical = {}, {}
    for k, v in pairs(headers) do
        local lk = k:lower()
        names[#names + 1] = lk
        canonical[lk] = trim(v)
    end
    table.sort(names)
    local lines = {}
    for i, k in ipairs(names) do lines[i] = k .. ":" .. canonical[k] .. "\n" end
    local signed = table.concat(names, ";")

    local path = req.path or "/"
    if req.double_encode ~= false then
        path = path:gsub("[^/]+", function(seg) return LlmAuth.uri_encode(seg) end)
    end
    local query = req.query or ""
    if type(query) == "table" then
        local keys = {}
        for k in pairs(query) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for i, k in ipairs(keys) do parts[i] = LlmAuth.uri_encode(k) .. "=" .. LlmAuth.uri_encode(query[k]) end
        query = table.concat(parts, "&")
    end

    local canonical_request = table.concat({
        (req.method or "POST"):upper(), path, query, table.concat(lines), signed,
        hex(LlmAuth.sha256(req.payload or "")),
    }, "\n")
    local scope = date .. "/" .. req.region .. "/" .. req.service .. "/aws4_request"
    local string_to_sign = "AWS4-HMAC-SHA256\n" .. amz_date .. "\n" .. scope .. "\n"
        .. hex(LlmAuth.sha256(canonical_request))
    local signature = hex(LlmAuth.hmac(LlmAuth.sigv4_key(req.secret_key, date, req.region, req.service),
        string_to_sign))
    headers["Authorization"] = "AWS4-HMAC-SHA256 Credential=" .. req.access_key .. "/" .. scope
        .. ", SignedHeaders=" .. signed .. ", Signature=" .. signature
    return headers, { canonical_request = canonical_request, string_to_sign = string_to_sign,
        signature = signature }
end

-- ---------------------------------------------------------------------------
-- Google service account -> OAuth access token (Vertex AI)
-- ---------------------------------------------------------------------------

LlmAuth.GOOGLE_SCOPE = "https://www.googleapis.com/auth/cloud-platform"
LlmAuth.GOOGLE_TOKEN_URI = "https://oauth2.googleapis.com/token"

--- The signed JWT (RFC 7523) for a service account { client_email, private_key, token_uri? }.
-- now: seconds (default ngx.time()).
function LlmAuth.google_assertion(sa, now)
    local cjson = require("cjson.safe")
    now = now or (ngx and ngx.time and ngx.time()) or os.time()
    local header = LlmAuth.base64url(cjson.encode({ alg = "RS256", typ = "JWT" }))
    local claims = LlmAuth.base64url(cjson.encode({
        iss = sa.client_email, scope = LlmAuth.GOOGLE_SCOPE, aud = sa.token_uri or LlmAuth.GOOGLE_TOKEN_URI,
        iat = now, exp = now + 3600,
    }))
    local input = header .. "." .. claims
    local ok, key = pcall(require("openssl.pkey").new, sa.private_key)
    if not ok or not key then return nil, "the service account's private_key can't be read" end
    local sig_ok, sig = pcall(function()
        return key:sign(require("openssl.digest").new("sha256"):update(input))
    end)
    if not sig_ok or not sig then return nil, "could not sign the service-account assertion" end
    return input .. "." .. LlmAuth.base64url(sig)
end

local TOKENS = {} -- client_email -> { token, expires } (per worker)

--- An access token for the service account, cached until a minute before it expires.
-- fetch(url, body) -> { status, body } | nil, err  (the caller's HTTP client: form-encoded POST)
function LlmAuth.google_token(sa, fetch)
    local now = (ngx and ngx.time and ngx.time()) or os.time()
    local cached = TOKENS[sa.client_email]
    if cached and cached.expires - 60 > now then return cached.token end
    local assertion, aerr = LlmAuth.google_assertion(sa, now)
    if not assertion then return nil, aerr end
    local body = "grant_type=" .. LlmAuth.uri_encode("urn:ietf:params:oauth:grant-type:jwt-bearer")
        .. "&assertion=" .. assertion
    local res, err = fetch(sa.token_uri or LlmAuth.GOOGLE_TOKEN_URI, body)
    if not res then return nil, "Google token request failed: " .. tostring(err) end
    local data = require("cjson.safe").decode(res.body or "")
    if res.status >= 400 or type(data) ~= "table" or type(data.access_token) ~= "string" then
        local why = type(data) == "table" and (data.error_description or data.error) or ("HTTP " .. res.status)
        return nil, "Google rejected the service account (" .. tostring(why):sub(1, 200) .. ")", res.status
    end
    TOKENS[sa.client_email] = { token = data.access_token, expires = now + (tonumber(data.expires_in) or 3600) }
    return data.access_token
end

function LlmAuth.forget_tokens()
    TOKENS = {}
end

return LlmAuth
