--[[
    Domain Credential Queries
    =========================

    Namespace-scoped provider credentials (Cloudflare API tokens today). The
    secret itself is stored AES-encrypted (Global.encryptSecret, keyed by
    OPENSSL_SECRET_KEY) so the backend can decrypt it server-side to call the
    provider API — never persisted in plaintext, and never returned to clients.

    One credential per (namespace, provider) — upsert semantics on save.
]]

local DomainCredentialModel = require("models.DomainCredentialModel")
local Global = require("helper.global")
local db = require("lapis.db")

local DomainCredentialQueries = {}

-- Public-safe projection: everything EXCEPT encrypted_secret, plus a boolean flag.
local function sanitize(row)
    if not row then return nil end
    return {
        uuid = row.uuid,
        namespace_id = row.namespace_id,
        provider = row.provider,
        label = row.label,
        account_id = row.account_id,
        email = row.email,
        has_secret = row.encrypted_secret ~= nil and row.encrypted_secret ~= "",
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
end
DomainCredentialQueries.sanitize = sanitize

--- Create or update the credential for (namespace, provider). Encrypts the token.
-- @param params { namespace_id, provider, label?, secret (plaintext token), account_id?, email? }
function DomainCredentialQueries.save(params)
    assert(params.namespace_id, "namespace_id required")
    local provider = params.provider or "cloudflare"

    local existing = db.query([[
        SELECT * FROM domain_credentials WHERE namespace_id = ? AND provider = ? LIMIT 1
    ]], params.namespace_id, provider)
    existing = existing and existing[1] or nil

    local encrypted = existing and existing.encrypted_secret or nil
    if params.secret and params.secret ~= "" then
        encrypted = Global.encryptSecret(params.secret)
    end
    if not encrypted then
        return nil, "secret is required"
    end

    if existing then
        local model = DomainCredentialModel:find({ id = existing.id })
        return sanitize(model:update({
            label = params.label or existing.label,
            encrypted_secret = encrypted,
            account_id = params.account_id ~= nil and params.account_id or existing.account_id,
            email = params.email ~= nil and params.email or existing.email,
            updated_at = db.raw("NOW()"),
        }, { returning = "*" }))
    end

    local created = DomainCredentialModel:create({
        uuid = Global.generateUUID(),
        namespace_id = params.namespace_id,
        provider = provider,
        label = params.label,
        encrypted_secret = encrypted,
        account_id = params.account_id,
        email = params.email,
        metadata = "{}",
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
    return sanitize(created)
end

--- Public listing (no secrets) for a namespace.
function DomainCredentialQueries.list(namespace_id)
    local rows = db.query([[
        SELECT * FROM domain_credentials WHERE namespace_id = ? ORDER BY provider ASC
    ]], namespace_id)
    local out = {}
    for _, r in ipairs(rows or {}) do
        table.insert(out, sanitize(r))
    end
    return out
end

--- Internal: fetch and DECRYPT the token for server-side provider calls.
-- Returns plaintext token or nil, err. Never expose this over the API.
function DomainCredentialQueries.getDecryptedSecret(namespace_id, provider)
    provider = provider or "cloudflare"
    local rows = db.query([[
        SELECT * FROM domain_credentials WHERE namespace_id = ? AND provider = ? LIMIT 1
    ]], namespace_id, provider)
    local row = rows and rows[1] or nil
    if not row or not row.encrypted_secret or row.encrypted_secret == "" then
        return nil, "No " .. provider .. " credential configured for this namespace"
    end
    local ok, secret = pcall(Global.decryptSecret, row.encrypted_secret)
    if not ok or not secret then
        return nil, "Failed to decrypt stored credential"
    end
    return secret, nil, row
end

function DomainCredentialQueries.delete(namespace_id, provider)
    provider = provider or "cloudflare"
    db.query([[DELETE FROM domain_credentials WHERE namespace_id = ? AND provider = ?]], namespace_id, provider)
    return true
end

return DomainCredentialQueries
