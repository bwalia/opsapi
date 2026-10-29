--[[
    SAML single sign-on (core)
    ==========================
    Storage behind routes/saml.lua and lib/saml/*.

      [1] saml_providers        one SAML identity provider per row, owned by a
                                workspace (namespace). A workspace may have
                                several (e.g. Okta for staff, Entra for a partner).
          saml_used_assertions  assertion IDs already accepted, until they expire,
                                so a captured SAMLResponse can't be replayed.
      [2] "Single sign-on" menu item under workspace settings (namespace module).

    Idempotent; gated on FEATURES.CORE so every deployment gets it.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS saml_providers (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
                namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name VARCHAR(255) NOT NULL,
                idp_entity_id TEXT NOT NULL,
                idp_sso_url TEXT NOT NULL,
                idp_x509_cert TEXT NOT NULL,
                email_domains TEXT NOT NULL DEFAULT '',
                default_role VARCHAR(255),
                auto_provision BOOLEAN NOT NULL DEFAULT true,
                allow_idp_initiated BOOLEAN NOT NULL DEFAULT false,
                attribute_mapping JSONB NOT NULL DEFAULT '{}'::jsonb,
                is_enabled BOOLEAN NOT NULL DEFAULT true,
                last_login_at TIMESTAMP,
                login_count INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_saml_providers_namespace ON saml_providers(namespace_id)")
        db.query([[
            CREATE TABLE IF NOT EXISTS saml_used_assertions (
                assertion_id TEXT PRIMARY KEY,
                provider_id INTEGER NOT NULL REFERENCES saml_providers(id) ON DELETE CASCADE,
                expires_at TIMESTAMP NOT NULL
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_saml_used_assertions_expiry ON saml_used_assertions(expires_at)")
    end,

    [2] = function()
        if #db.select("1 FROM information_schema.tables WHERE table_name = 'menu_items'") == 0 then return end
        db.query([[
            INSERT INTO menu_items (uuid, key, name, icon, path, module, required_action, priority,
                                    is_active, is_admin_only, always_show, settings, created_at, updated_at)
            VALUES (gen_random_uuid()::text, 'sso', 'Single sign-on', 'KeyRound', '/dashboard/namespace/sso',
                    'namespace', 'read', 103, true, false, false, '{}', NOW(), NOW())
            ON CONFLICT (key) DO NOTHING
        ]])
    end,
}
