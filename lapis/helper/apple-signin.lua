--[[
    Sign in with Apple helper.

    Verifies Apple identity tokens (JWKS / RS256) and builds the
    client_secret JWT (ES256) needed for the web authorization-code
    exchange. Mirrors the Google OAuth helpers that live inline in
    routes/auth.lua, but Apple needs JWKS + ES256 so it lives here.

    Env vars (all required for web redirect; native only needs the
    audience vars for identity-token verification):
      APPLE_TEAM_ID          — Apple Developer Team ID
      APPLE_KEY_ID           — Sign in with Apple key ID
      APPLE_PRIVATE_KEY      — .p8 PEM contents (literal \\n ok)
      APPLE_PRIVATE_KEY_PATH — alternative to APPLE_PRIVATE_KEY
      APPLE_CLIENT_ID        — Services ID (web audience + client_id)
      APPLE_BUNDLE_ID        — iOS bundle ID (native audience)
      APPLE_REDIRECT_URI     — web callback URL registered with Apple
]]

local cjson = require("cjson.safe")
local http = require("resty.http")
local Global = require("helper.global")

local AppleSignIn = {}

local APPLE_ISSUER = "https://appleid.apple.com"
local APPLE_AUTH_URL = "https://appleid.apple.com/auth/authorize"
local APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
local APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"

local jwks_cache = { keys = nil, fetched_at = 0 }
local JWKS_TTL = 3600

local client_secret_cache = { jwt = nil, exp = 0 }

local function base64url_encode(input)
    local b64 = ngx.encode_base64(input)
    return b64:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
end

local function base64url_decode(input)
    if not input or input == "" then
        return nil
    end
    local b64 = input:gsub("-", "+"):gsub("_", "/")
    local pad = #b64 % 4
    if pad > 0 then
        b64 = b64 .. string.rep("=", 4 - pad)
    end
    local ok, decoded = pcall(ngx.decode_base64, b64)
    if not ok then
        return nil
    end
    return decoded
end

local function der_to_raw(der)
    local pos = 1
    if der:byte(pos) ~= 0x30 then
        return nil, "Invalid DER: not a sequence"
    end
    pos = pos + 1
    local seq_len = der:byte(pos)
    pos = pos + 1
    if seq_len >= 0x80 then
        local len_bytes = seq_len - 0x80
        pos = pos + len_bytes
    end

    if der:byte(pos) ~= 0x02 then
        return nil, "Invalid DER: R not an integer"
    end
    pos = pos + 1
    local r_len = der:byte(pos)
    pos = pos + 1
    local r = der:sub(pos, pos + r_len - 1)
    pos = pos + r_len

    if der:byte(pos) ~= 0x02 then
        return nil, "Invalid DER: S not an integer"
    end
    pos = pos + 1
    local s_len = der:byte(pos)
    pos = pos + 1
    local s = der:sub(pos, pos + s_len - 1)

    local function pad_or_trim(val, size)
        if #val > size then
            return val:sub(#val - size + 1)
        elseif #val < size then
            return string.rep("\0", size - #val) .. val
        end
        return val
    end

    return pad_or_trim(r, 32) .. pad_or_trim(s, 32)
end

local function load_private_key()
    local pem = Global.getEnvVar("APPLE_PRIVATE_KEY")
    if pem and pem ~= "" then
        -- Vault / .env often store newlines as the two-char sequence \n
        pem = pem:gsub("\\n", "\n")
        return pem
    end

    local key_path = Global.getEnvVar("APPLE_PRIVATE_KEY_PATH")
    if not key_path or key_path == "" then
        return nil, "APPLE_PRIVATE_KEY or APPLE_PRIVATE_KEY_PATH required"
    end

    local file = io.open(key_path, "r")
    if not file then
        return nil, "Cannot open Apple private key: " .. key_path
    end
    local content = file:read("*all")
    file:close()
    if not content or content == "" then
        return nil, "Apple private key file is empty"
    end
    return content
end

function AppleSignIn.allowed_audiences()
    local audiences = {}
    local client_id = Global.getEnvVar("APPLE_CLIENT_ID")
    local bundle_id = Global.getEnvVar("APPLE_BUNDLE_ID")
    if client_id and client_id ~= "" then
        table.insert(audiences, client_id)
    end
    if bundle_id and bundle_id ~= "" and bundle_id ~= client_id then
        table.insert(audiences, bundle_id)
    end
    return audiences
end

function AppleSignIn.is_configured_for_web()
    local team_id = Global.getEnvVar("APPLE_TEAM_ID")
    local key_id = Global.getEnvVar("APPLE_KEY_ID")
    local client_id = Global.getEnvVar("APPLE_CLIENT_ID")
    local redirect_uri = Global.getEnvVar("APPLE_REDIRECT_URI")
    local has_key = (Global.getEnvVar("APPLE_PRIVATE_KEY") or "") ~= ""
        or (Global.getEnvVar("APPLE_PRIVATE_KEY_PATH") or "") ~= ""
    return team_id and key_id and client_id and redirect_uri and has_key
end

function AppleSignIn.is_configured_for_native()
    return #AppleSignIn.allowed_audiences() > 0
end

local function decode_jwt_part(part)
    local raw = base64url_decode(part)
    if not raw then
        return nil
    end
    return cjson.decode(raw)
end

function AppleSignIn.decode_unverified(token)
    if type(token) ~= "string" or token == "" then
        return nil
    end
    local parts = {}
    for part in string.gmatch(token, "[^%.]+") do
        table.insert(parts, part)
    end
    if #parts ~= 3 then
        return nil
    end
    local header = decode_jwt_part(parts[1])
    local payload = decode_jwt_part(parts[2])
    if not header or not payload then
        return nil
    end
    return header, payload, parts
end

function AppleSignIn.is_apple_id_token(token)
    local _, payload = AppleSignIn.decode_unverified(token)
    if not payload then
        return false
    end
    return payload.iss == APPLE_ISSUER
end

local function fetch_jwks()
    local now = ngx.time()
    if jwks_cache.keys and (now - jwks_cache.fetched_at) < JWKS_TTL then
        return jwks_cache.keys
    end

    local httpc = http.new()
    httpc:set_timeout(10000)
    local res, err = httpc:request_uri(APPLE_JWKS_URL, {
        method = "GET",
        ssl_verify = true,
    })
    if not res then
        return nil, "Failed to fetch Apple JWKS: " .. (err or "unknown")
    end
    if res.status ~= 200 then
        return nil, "Apple JWKS returned status " .. tostring(res.status)
    end

    local body = cjson.decode(res.body)
    if not body or type(body.keys) ~= "table" then
        return nil, "Invalid Apple JWKS payload"
    end

    jwks_cache.keys = body.keys
    jwks_cache.fetched_at = now
    return body.keys
end

local function jwk_to_pem(jwk)
    local pkey = require("resty.openssl.pkey")
    -- Prefer explicit JWK type; fall back to table form for older rocks.
    local key, err = pkey.new(cjson.encode({
        kty = jwk.kty or "RSA",
        kid = jwk.kid,
        use = jwk.use,
        alg = jwk.alg,
        n = jwk.n,
        e = jwk.e,
    }), "JWK")
    if not key then
        key, err = pkey.new({
            kty = jwk.kty or "RSA",
            n = jwk.n,
            e = jwk.e,
        })
    end
    if not key then
        return nil, err or "Failed to build RSA key from JWK"
    end
    local pem, pem_err = key:to_PEM("public")
    if not pem then
        return nil, pem_err or "Failed to export Apple public key"
    end
    return pem
end

local function audience_matches(aud, allowed)
    if type(aud) == "string" then
        for _, a in ipairs(allowed) do
            if aud == a then
                return true
            end
        end
        return false
    end
    if type(aud) == "table" then
        for _, claim_aud in ipairs(aud) do
            if audience_matches(claim_aud, allowed) then
                return true
            end
        end
    end
    return false
end

function AppleSignIn.verify_identity_token(token)
    local allowed = AppleSignIn.allowed_audiences()
    if #allowed == 0 then
        return nil, "Apple Sign In not configured (APPLE_CLIENT_ID / APPLE_BUNDLE_ID)"
    end

    local header, payload, parts = AppleSignIn.decode_unverified(token)
    if not header or not payload or not parts then
        return nil, "Malformed Apple identity token"
    end

    if payload.iss ~= APPLE_ISSUER then
        return nil, "Invalid Apple token issuer"
    end

    if type(payload.exp) == "number" and payload.exp < ngx.time() then
        return nil, "Apple identity token expired"
    end

    if not audience_matches(payload.aud, allowed) then
        return nil, "Apple token not issued for this app"
    end

    if not payload.sub or payload.sub == "" then
        return nil, "Apple token missing subject"
    end

    local keys, jwks_err = fetch_jwks()
    if not keys then
        return nil, jwks_err
    end

    local jwk
    for _, candidate in ipairs(keys) do
        if candidate.kid == header.kid then
            jwk = candidate
            break
        end
    end
    if not jwk then
        -- Key rotation: bust cache once and retry
        jwks_cache.fetched_at = 0
        keys, jwks_err = fetch_jwks()
        if not keys then
            return nil, jwks_err
        end
        for _, candidate in ipairs(keys) do
            if candidate.kid == header.kid then
                jwk = candidate
                break
            end
        end
    end
    if not jwk then
        return nil, "Apple JWKS key not found for kid"
    end

    local pem, pem_err = jwk_to_pem(jwk)
    if not pem then
        return nil, pem_err
    end

    local jwt = require("resty.jwt")
    local jwt_obj = jwt:verify(pem, token)
    if not jwt_obj or not jwt_obj.verified then
        return nil, "Apple identity token signature invalid: " ..
            tostring(jwt_obj and jwt_obj.reason or "unknown")
    end

    -- Normalise email_verified (Apple sometimes sends the string "true")
    if payload.email_verified == "true" or payload.email_verified == true then
        payload.email_verified = true
    end

    return payload, nil
end

function AppleSignIn.generate_client_secret()
    local now = ngx.time()
    if client_secret_cache.jwt and now < (client_secret_cache.exp - 60) then
        return client_secret_cache.jwt
    end

    local team_id = Global.getEnvVar("APPLE_TEAM_ID")
    local key_id = Global.getEnvVar("APPLE_KEY_ID")
    local client_id = Global.getEnvVar("APPLE_CLIENT_ID")
    if not team_id or not key_id or not client_id then
        return nil, "APPLE_TEAM_ID / APPLE_KEY_ID / APPLE_CLIENT_ID required"
    end

    local private_key, key_err = load_private_key()
    if not private_key then
        return nil, key_err
    end

    -- Apple allows client_secret JWTs up to 6 months; keep ours short.
    local exp = now + (86400 * 30)
    local header_b64 = base64url_encode(cjson.encode({
        alg = "ES256",
        kid = key_id,
    }))
    local payload_b64 = base64url_encode(cjson.encode({
        iss = team_id,
        iat = now,
        exp = exp,
        aud = APPLE_ISSUER,
        sub = client_id,
    }))
    local signing_input = header_b64 .. "." .. payload_b64

    local openssl_pkey = require("resty.openssl.pkey")
    local pkey, pkey_err = openssl_pkey.new(private_key)
    if not pkey then
        return nil, "Failed to load Apple private key: " .. tostring(pkey_err)
    end

    local signature, sign_err = pkey:sign(signing_input, "sha256", nil, { ecdsa_use_raw = false })
    if not signature then
        return nil, "Failed to sign Apple client_secret: " .. tostring(sign_err)
    end

    local raw_sig, conv_err = der_to_raw(signature)
    if not raw_sig then
        return nil, conv_err
    end

    local jwt = signing_input .. "." .. base64url_encode(raw_sig)
    client_secret_cache.jwt = jwt
    client_secret_cache.exp = exp
    return jwt
end

function AppleSignIn.build_authorize_url(state)
    local client_id = Global.getEnvVar("APPLE_CLIENT_ID")
    local redirect_uri = Global.getEnvVar("APPLE_REDIRECT_URI")
    if not client_id or not redirect_uri then
        return nil, "APPLE_CLIENT_ID / APPLE_REDIRECT_URI required"
    end

    -- response_mode=form_post is required when requesting name/email scope
    -- with an id_token. Callback must accept POST.
    return string.format(
        "%s?client_id=%s&redirect_uri=%s&response_type=code%%20id_token" ..
        "&scope=name%%20email&response_mode=form_post&state=%s",
        APPLE_AUTH_URL,
        ngx.escape_uri(client_id),
        ngx.escape_uri(redirect_uri),
        ngx.escape_uri(state or "/")
    )
end

function AppleSignIn.exchange_code(code)
    local client_id = Global.getEnvVar("APPLE_CLIENT_ID")
    local redirect_uri = Global.getEnvVar("APPLE_REDIRECT_URI")
    if not client_id or not redirect_uri then
        return nil, "APPLE_CLIENT_ID / APPLE_REDIRECT_URI required"
    end

    local client_secret, secret_err = AppleSignIn.generate_client_secret()
    if not client_secret then
        return nil, secret_err
    end

    local httpc = http.new()
    httpc:set_timeout(30000)
    local res, err = httpc:request_uri(APPLE_TOKEN_URL, {
        method = "POST",
        body = ngx.encode_args({
            client_id = client_id,
            client_secret = client_secret,
            code = code,
            grant_type = "authorization_code",
            redirect_uri = redirect_uri,
        }),
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        ssl_verify = true,
    })

    if not res then
        return nil, "Apple token exchange failed: " .. (err or "unknown")
    end

    local body = cjson.decode(res.body)
    if not body then
        return nil, "Invalid Apple token response"
    end
    if res.status ~= 200 or not body.id_token then
        local msg = body.error_description or body.error or ("status " .. tostring(res.status))
        return nil, "Apple token exchange error: " .. tostring(msg)
    end

    return body
end

--- Parse the one-time `user` JSON Apple posts on first authorization.
function AppleSignIn.parse_user_form(user_json)
    if type(user_json) ~= "string" or user_json == "" then
        return nil
    end
    local ok, data = pcall(cjson.decode, user_json)
    if not ok or type(data) ~= "table" then
        return nil
    end
    local first_name, last_name = "", ""
    if type(data.name) == "table" then
        first_name = data.name.firstName or data.name.first_name or ""
        last_name = data.name.lastName or data.name.last_name or ""
    end
    return {
        email = data.email,
        first_name = first_name,
        last_name = last_name,
    }
end

return AppleSignIn
