--[[
    WSL Proxy Connection Queries
    ============================

    One encrypted WSL Proxy control-plane connection per namespace (api_url,
    email, password). The password is AES-encrypted at rest via
    Global.encryptSecret (keyed by OPENSSL_SECRET_KEY) and decrypted server-side
    only — never returned over any API. Mirrors DomainCredentialQueries.

    Consumed by lib/wslproxy-client.lua (login + list/get rules) and
    routes/domains.lua (connect / status / disconnect / rules proxy).
]]

local Global = require("helper.global")
local db = require("lapis.db")

local WslproxyConnectionQueries = {}

-- Public-safe projection: NEVER includes encrypted_password.
local function sanitize(row)
    if not row then return { connected = false } end
    return {
        connected = row.encrypted_password ~= nil and row.encrypted_password ~= "",
        uuid = row.uuid,
        api_url = row.api_url,
        email = row.email,
        has_secret = row.encrypted_password ~= nil and row.encrypted_password ~= "",
        connected_at = row.connected_at,
        updated_at = row.updated_at,
    }
end
WslproxyConnectionQueries.sanitize = sanitize

--- Raw row for a namespace (internal — contains the encrypted password).
function WslproxyConnectionQueries.get(namespace_id)
    local rows = db.query(
        "SELECT * FROM namespace_wslproxy_connections WHERE namespace_id = ? LIMIT 1", namespace_id)
    return rows and rows[1] or nil
end

--- Public status (no secrets) for a namespace.
function WslproxyConnectionQueries.status(namespace_id)
    return sanitize(WslproxyConnectionQueries.get(namespace_id))
end

--- Create or replace the namespace's connection. Encrypts the password.
-- @param params { namespace_id, api_url, email?, password (plaintext) }
-- @return public projection, nil  OR  nil, err
function WslproxyConnectionQueries.save(params)
    assert(params.namespace_id, "namespace_id required")
    local api_url = params.api_url and tostring(params.api_url):gsub("^%s+", ""):gsub("%s+$", "") or ""
    if api_url == "" then return nil, "api_url is required" end

    local existing = WslproxyConnectionQueries.get(params.namespace_id)
    -- A blank password on update means "keep the stored one".
    local encrypted = existing and existing.encrypted_password or nil
    if params.password and params.password ~= "" then
        local ok, enc = pcall(Global.encryptSecret, params.password)
        if not ok or not enc then return nil, "Failed to encrypt password" end
        encrypted = enc
    end
    if not encrypted then return nil, "password is required" end

    -- Upsert on the UNIQUE(namespace_id). Idempotent; one row per namespace.
    local rows = db.query([[
        INSERT INTO namespace_wslproxy_connections
            (uuid, namespace_id, api_url, email, encrypted_password, connected_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, NOW(), NOW(), NOW())
        ON CONFLICT (namespace_id) DO UPDATE SET
            api_url = EXCLUDED.api_url,
            email = EXCLUDED.email,
            encrypted_password = EXCLUDED.encrypted_password,
            connected_at = NOW(),
            updated_at = NOW()
        RETURNING *
    ]], existing and existing.uuid or Global.generateUUID(),
        params.namespace_id, api_url, params.email or db.NULL, encrypted)

    return sanitize(rows and rows[1] or nil)
end

--- Internal: decrypted credentials for server-side API calls.
-- @return { api_url, email, password }, nil  OR  nil, err. Never expose this.
function WslproxyConnectionQueries.getDecrypted(namespace_id)
    local row = WslproxyConnectionQueries.get(namespace_id)
    if not row or not row.encrypted_password or row.encrypted_password == "" then
        return nil, "WSL Proxy is not connected for this namespace"
    end
    local ok, password = pcall(Global.decryptSecret, row.encrypted_password)
    if not ok or not password then
        return nil, "Failed to decrypt stored WSL Proxy password"
    end
    return { api_url = row.api_url, email = row.email, password = password }, nil
end

function WslproxyConnectionQueries.delete(namespace_id)
    db.query("DELETE FROM namespace_wslproxy_connections WHERE namespace_id = ?", namespace_id)
    return true
end

return WslproxyConnectionQueries
