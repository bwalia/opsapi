--[[
    Workspace (outbound) webhooks — a CORE module
    =============================================
    Namespaces register URLs that receive their events, signed and retried.
    Delivery rides on the plugin-events outbox (helper/plugin-events.lua):
    [1] makes sure those tables exist (they were created lazily by the first
    plugin migration before) and creates namespace_webhooks; [2] registers
    the `webhooks` RBAC module + menu item and grants it to owner/admin roles.
    Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        require("helper.plugin-events").ensureSchema()
        db.query([[
            CREATE TABLE IF NOT EXISTS namespace_webhooks (
                id BIGSERIAL PRIMARY KEY,
                uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
                namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                url TEXT NOT NULL,
                description TEXT,
                events JSONB NOT NULL DEFAULT '[]',
                encrypted_secret TEXT NOT NULL,
                is_active BOOLEAN NOT NULL DEFAULT true,
                created_by_uuid TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_namespace_webhooks_namespace ON namespace_webhooks (namespace_id)")
    end,

    [2] = function()
        local inserted = db.query([[
            INSERT INTO modules (uuid, machine_name, name, description, category, priority,
                                 is_active, is_system, default_actions, created_at, updated_at)
            VALUES (gen_random_uuid()::text, 'webhooks', 'Webhooks',
                    'Send this workspace''s events (invoice paid, lead created, ...) to your own URLs',
                    'Integrations', '0', true, false, 'create,read,update,delete,manage', NOW(), NOW())
            ON CONFLICT (machine_name) DO NOTHING
            RETURNING id
        ]])
        if inserted[1] then
            require("queries.ModuleQueries").propagateToNamespaceAdmins("webhooks")
            print("[Webhooks] Registered webhooks module; granted to owner/admin roles")
        end
        db.query([[
            INSERT INTO menu_items (uuid, key, name, icon, path, module, required_action, priority,
                                    is_active, is_admin_only, always_show, settings, created_at, updated_at)
            VALUES (gen_random_uuid()::text, 'webhooks', 'Webhooks', 'Webhook', '/dashboard/namespace/webhooks',
                    'webhooks', 'read', 102, true, false, false, '{}', NOW(), NOW())
            ON CONFLICT (key) DO NOTHING
        ]])
    end,
}
