--[[
    Cloudflare API Client
    =====================

    Thin wrapper over the Cloudflare v4 API for the Domain Management module.
    Two-way: list zones, and read/create/update/delete DNS records.

    Auth: a per-namespace API token, stored AES-encrypted in domain_credentials
    and decrypted server-side via DomainCredentialQueries.getDecryptedSecret.
    The token is passed to Client.new(token) — this module never reads the DB.

    TLS: ssl_verify is environment-aware, mirroring lib/hmrc-mtd-client.lua.
    Production verifies certs (requires lua_ssl_trusted_certificate in nginx.conf,
    already present); local/sandbox may relax it via CLOUDFLARE_ENVIRONMENT or the
    generic OPSAPI_SSL_VERIFY flag.

    Every method returns (result, nil) on success or (nil, err_string) on failure —
    HTTP errors and Cloudflare error envelopes are normalised into err_string.
]]

local cjson = require("cjson")

local Cloudflare = {}
Cloudflare.__index = Cloudflare

local API_BASE = "https://api.cloudflare.com/client/v4"

-- Verify TLS unless explicitly told not to. Cloudflare is always real TLS, so the
-- only reason to relax is a local box without a CA bundle.
local function tls_verify()
    local env = (os.getenv("CLOUDFLARE_ENVIRONMENT") or ""):lower()
    if env == "sandbox" or env == "local" or env == "development" then
        return false
    end
    local flag = os.getenv("OPSAPI_SSL_VERIFY")
    if flag ~= nil and flag ~= "" then
        return flag == "true" or flag == "1"
    end
    return true -- default: verify
end

local function http_client()
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(20000)
    return httpc, nil
end

--- Create a client bound to a token.
-- @param token string Cloudflare API token (already decrypted)
function Cloudflare.new(token)
    return setmetatable({ token = token }, Cloudflare)
end

-- Core request. Returns (result_table, nil) or (nil, err).
function Cloudflare:request(method, path, body)
    if not self.token or self.token == "" then
        return nil, "Cloudflare token not configured"
    end
    local httpc, err = http_client()
    if not httpc then return nil, err end

    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }
    local payload = nil
    if body ~= nil then
        local enc_ok, enc = pcall(cjson.encode, body)
        if not enc_ok then return nil, "Failed to encode request body" end
        payload = enc
    end

    local res, rerr = httpc:request_uri(API_BASE .. path, {
        method = method,
        headers = headers,
        body = payload,
        ssl_verify = tls_verify(),
    })
    if not res then
        return nil, "Cloudflare request failed: " .. tostring(rerr)
    end

    local ok, decoded = pcall(cjson.decode, res.body or "")
    if not ok or type(decoded) ~= "table" then
        return nil, "Cloudflare returned a non-JSON response (HTTP " .. tostring(res.status) .. ")"
    end

    if decoded.success == false or (res.status and res.status >= 400) then
        local msg = "Cloudflare API error (HTTP " .. tostring(res.status) .. ")"
        if type(decoded.errors) == "table" and decoded.errors[1] then
            local e = decoded.errors[1]
            msg = msg .. ": " .. tostring(e.message or e.code or "unknown")
        end
        return nil, msg
    end

    return decoded, nil
end

--------------------------------------------------------------------------------
-- Zones
--------------------------------------------------------------------------------
function Cloudflare:list_zones(opts)
    opts = opts or {}
    local qs = "?per_page=" .. tostring(opts.per_page or 50)
    if opts.name and opts.name ~= "" then
        qs = qs .. "&name=" .. opts.name
    end
    local res, err = self:request("GET", "/zones" .. qs)
    if not res then return nil, err end
    return res.result or {}, nil
end

--- Find a zone id by (apex) domain name.
function Cloudflare:find_zone_id(name)
    local zones, err = self:list_zones({ name = name })
    if not zones then return nil, err end
    if zones[1] then return zones[1].id, nil end
    return nil, "Zone not found for " .. tostring(name)
end

--------------------------------------------------------------------------------
-- DNS records (read + create/update/delete)
--------------------------------------------------------------------------------
function Cloudflare:list_dns_records(zone_id, opts)
    opts = opts or {}
    if not zone_id or zone_id == "" then return nil, "zone_id required" end
    local qs = "?per_page=" .. tostring(opts.per_page or 100)
    if opts.type and opts.type ~= "" then qs = qs .. "&type=" .. opts.type end
    if opts.name and opts.name ~= "" then qs = qs .. "&name=" .. opts.name end
    local res, err = self:request("GET", "/zones/" .. zone_id .. "/dns_records" .. qs)
    if not res then return nil, err end
    return res.result or {}, nil
end

-- record = { type, name, content, ttl?, proxied?, priority? }
function Cloudflare:create_dns_record(zone_id, record)
    if not zone_id or zone_id == "" then return nil, "zone_id required" end
    if not record or not record.type or not record.name or record.content == nil then
        return nil, "record requires type, name and content"
    end
    local res, err = self:request("POST", "/zones/" .. zone_id .. "/dns_records", record)
    if not res then return nil, err end
    return res.result, nil
end

function Cloudflare:update_dns_record(zone_id, record_id, record)
    if not zone_id or zone_id == "" then return nil, "zone_id required" end
    if not record_id or record_id == "" then return nil, "record_id required" end
    local res, err = self:request("PUT", "/zones/" .. zone_id .. "/dns_records/" .. record_id, record)
    if not res then return nil, err end
    return res.result, nil
end

function Cloudflare:delete_dns_record(zone_id, record_id)
    if not zone_id or zone_id == "" then return nil, "zone_id required" end
    if not record_id or record_id == "" then return nil, "record_id required" end
    local res, err = self:request("DELETE", "/zones/" .. zone_id .. "/dns_records/" .. record_id)
    if not res then return nil, err end
    return res.result, nil
end

--- Cheap credential validation: GET /user/tokens/verify.
function Cloudflare:verify_token()
    local res, err = self:request("GET", "/user/tokens/verify")
    if not res then return nil, err end
    return res.result or {}, nil
end

return Cloudflare
