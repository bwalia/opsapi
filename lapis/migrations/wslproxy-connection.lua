--[[
    Namespace → WSL Proxy connection
    ================================

    Per-namespace, encrypted-at-rest credentials for the WSL Proxy control-plane
    API (URL + email + password). The password is stored AES-encrypted via
    Global.encryptSecret (keyed by OPENSSL_SECRET_KEY) — never plaintext, never
    returned over the API; decrypted server-side only to log in and list/fetch
    rules. Mirrors queries/DomainCredentialQueries.lua.

    See lib/wslproxy-client.lua (the API client) and routes/domains.lua
    (connect/status/disconnect + /wslproxy/rules). Gated on FEATURES.SERVICES.

    One row per namespace (UNIQUE) → upsert via ON CONFLICT. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        pcall(function()
            db.query([[
                CREATE TABLE IF NOT EXISTS namespace_wslproxy_connections (
                    id                  SERIAL PRIMARY KEY,
                    uuid                TEXT UNIQUE,
                    namespace_id        INTEGER NOT NULL UNIQUE,
                    api_url             TEXT NOT NULL,
                    email               TEXT,
                    encrypted_password  TEXT NOT NULL,
                    connected_at        TIMESTAMPTZ,
                    created_at          TIMESTAMPTZ DEFAULT NOW(),
                    updated_at          TIMESTAMPTZ DEFAULT NOW()
                )
            ]])
        end)
    end,
}
