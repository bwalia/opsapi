-- Signed public tokens for unsubscribe, preference centre, open pixel, click redirect.
-- Payload is base64url(json).sig where sig = HMAC-SHA256 hex of the payload with JWT_SECRET_KEY.
local cjson = require("cjson.safe")
local U = require("opsapi_marketing.util")

local T = {}

local function b64url_encode(s)
    local b = ngx.encode_base64(s)
    return (b:gsub("%+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local function b64url_decode(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = #s % 4
    if pad > 0 then s = s .. string.rep("=", 4 - pad) end
    local ok, raw = pcall(ngx.decode_base64, s)
    return ok and raw or nil
end

local function hmac_hex(secret, body)
    local ok_rh, resty_hmac = pcall(require, "resty.hmac")
    if ok_rh and resty_hmac then
        local h = resty_hmac:new(secret, resty_hmac.ALGOS.SHA256)
        if h and h:update(body) then
            local dig = h:final()
            if dig then
                return require("resty.string").to_hex(dig)
            end
        end
    end
    local ok, hmac = pcall(require, "resty.openssl.hmac")
    if not ok or not hmac then return nil, "hmac unavailable" end
    local h, err = hmac.new(secret, "sha256")
    if not h then return nil, err end
    if not h:update(body) then return nil, "hmac update failed" end
    local dig = h:final()
    if not dig then return nil, "hmac final failed" end
    return require("resty.string").to_hex(dig)
end

local function secret()
    local s = os.getenv("JWT_SECRET_KEY")
    if type(s) == "string" and s ~= "" then return s end
    return nil, "JWT_SECRET_KEY not set"
end

--- Mint a token. claims must include purpose, namespace_id, and typically contact_uuid / delivery_uuid.
-- Optional exp (unix). Default TTL 90 days for unsubscribe, 30 for tracking.
function T.mint(claims, ttl_seconds)
    local sec, err = secret()
    if not sec then return nil, err end
    local c = {}
    for k, v in pairs(claims or {}) do c[k] = v end
    c.iat = ngx.time()
    c.exp = c.exp or (c.iat + (ttl_seconds or 7776000))
    local payload = b64url_encode(cjson.encode(c))
    local sig, serr = hmac_hex(sec, payload)
    if not sig then return nil, serr end
    return payload .. "." .. sig
end

function T.verify(token, expected_purpose)
    if type(token) ~= "string" or not token:find(".", 1, true) then
        return nil, "invalid token"
    end
    local payload, sig = token:match("^([%w%-_]+)%.(%x+)$")
    if not payload or not sig then return nil, "invalid token format" end
    local sec, err = secret()
    if not sec then return nil, err end
    local expect, herr = hmac_hex(sec, payload)
    if not expect then return nil, herr end
    if #expect ~= #sig then return nil, "bad signature" end
    local diff = 0
    for i = 1, #expect do
        if expect:byte(i) ~= sig:byte(i) then diff = 1 end
    end
    if diff ~= 0 then return nil, "bad signature" end
    local raw = b64url_decode(payload)
    local claims = raw and cjson.decode(raw)
    if type(claims) ~= "table" then return nil, "bad claims" end
    if type(claims.exp) == "number" and claims.exp < ngx.time() then
        return nil, "expired"
    end
    if expected_purpose and claims.purpose ~= expected_purpose then
        return nil, "wrong purpose"
    end
    if not claims.namespace_id then return nil, "missing namespace" end
    return claims
end

function T.unsubscribe_url(ns, contact_uuid, channel, list_id, base)
    local tok, err = T.mint({
        purpose = "unsubscribe",
        namespace_id = tonumber(ns),
        contact_uuid = contact_uuid,
        channel = channel or "email",
        list_id = list_id,
    })
    if not tok then return nil, err end
    local root = (base and base ~= "" and base:gsub("/+$", "")) or ""
    return root .. "/api/v2/opsapi-marketing/public/unsubscribe?token=" .. ngx.escape_uri(tok)
end

function T.preferences_url(ns, contact_uuid, base)
    local tok, err = T.mint({
        purpose = "preferences",
        namespace_id = tonumber(ns),
        contact_uuid = contact_uuid,
    })
    if not tok then return nil, err end
    local root = (base and base ~= "" and base:gsub("/+$", "")) or ""
    return root .. "/api/v2/opsapi-marketing/public/preferences?token=" .. ngx.escape_uri(tok)
end

function T.open_pixel_url(ns, delivery_uuid, base)
    local tok, err = T.mint({
        purpose = "open",
        namespace_id = tonumber(ns),
        delivery_uuid = delivery_uuid,
    }, 2592000)
    if not tok then return nil, err end
    local root = (base and base ~= "" and base:gsub("/+$", "")) or ""
    return root .. "/api/v2/opsapi-marketing/public/o.gif?t=" .. ngx.escape_uri(tok)
end

function T.click_url(ns, delivery_uuid, dest, base)
    local tok, err = T.mint({
        purpose = "click",
        namespace_id = tonumber(ns),
        delivery_uuid = delivery_uuid,
        dest = dest,
    }, 2592000)
    if not tok then return nil, err end
    local root = (base and base ~= "" and base:gsub("/+$", "")) or ""
    return root .. "/api/v2/opsapi-marketing/public/c?t=" .. ngx.escape_uri(tok)
end

--- Long-lived token for SMS gateway inbound webhook auth.
function T.sms_inbound_token(ns, ttl_seconds)
    return T.mint({
        purpose = "sms_inbound",
        namespace_id = tonumber(ns),
    }, ttl_seconds or 31536000)
end

assert(U)

return T
