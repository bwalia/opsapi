--[[
    ES256 signing for Billing & Entitlements (docs/BILLING_ENTITLEMENTS.md §6)
    =========================================================================
    Entitlement tokens and offline licence files are compact JWS (JWT) signed
    with ONE deployment key. Clients verify them locally with the public keys
    from GET /api/v2/public/billing/jwks.json, so OpsAPI is not on the hot path
    of their requests.

      BILLING_SIGNING_KEY            EC P-256 private key (PEM; "\n" escapes ok)
      BILLING_SIGNING_KEY_ID         optional key id (default: the JWK thumbprint)
      BILLING_PREVIOUS_PUBLIC_KEYS   optional JSON array of old public JWKs, kept
                                     in the JWKS during a key rotation

    Without BILLING_SIGNING_KEY nothing is signed (callers answer 503): there
    is never a built-in or weak fallback key.

    Generate a key:  openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt
]]

-- Private cjson instance: the shared one encodes {} as [] (an empty feature
-- map must stay an object).
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)

local Signing = {}

local function env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return nil
end

local function b64url(s)
    return (ngx.encode_base64(s):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local state -- nil = not loaded yet; false = not configured; table = loaded

local function load()
    if state ~= nil then return state or nil end
    local raw = env("BILLING_SIGNING_KEY")
    if not raw then
        state = false
        return nil
    end
    local ok, key = pcall(require("resty.openssl.pkey").new, (raw:gsub("\\n", "\n")))
    if not ok or not key then
        ngx.log(ngx.ERR, "[billing] BILLING_SIGNING_KEY is not a valid EC private key: ", tostring(key))
        state = false
        return nil
    end
    local jwk = cjson.decode(key:tostring("public", "JWK") or "")
    if type(jwk) ~= "table" or jwk.crv ~= "P-256" then
        ngx.log(ngx.ERR, "[billing] BILLING_SIGNING_KEY must be an EC P-256 (prime256v1) key")
        state = false
        return nil
    end
    jwk.kid = env("BILLING_SIGNING_KEY_ID") or jwk.kid
    jwk.alg, jwk.use = "ES256", "sig"
    local keys = { jwk }
    local previous = cjson.decode(env("BILLING_PREVIOUS_PUBLIC_KEYS") or "[]")
    for _, k in ipairs(type(previous) == "table" and previous or {}) do
        if type(k) == "table" and k.kty == "EC" and k.kid ~= jwk.kid then keys[#keys + 1] = k end
    end
    state = { key = key, kid = jwk.kid, jwks = { keys = keys } }
    return state
end

--- JSON with empty tables as {} (feature maps), for jsonb writes and claims.
function Signing.encode(v)
    return cjson.encode(v)
end

function Signing.configured()
    return load() ~= nil
end

--- The public keys clients verify with ({ keys = [...] }, empty when unconfigured).
function Signing.jwks()
    local s = load()
    return s and s.jwks or { keys = {} }
end

--- Sign claims as a compact JWS. typ names what it is
-- ("opsapi-entitlements+jwt" / "opsapi-license+jwt").
-- @return token | nil, err
function Signing.sign(typ, claims)
    local s = load()
    if not s then return nil, "not configured" end
    local input = b64url(cjson.encode({ alg = "ES256", typ = typ, kid = s.kid }))
        .. "." .. b64url(cjson.encode(claims))
    local sig, err = s.key:sign(input, "sha256", nil, { ecdsa_use_raw = true })
    if not sig then return nil, err end
    return input .. "." .. b64url(sig)
end

return Signing
