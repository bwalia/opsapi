--[[
    API Keys Migrations
    ===================

    Namespace-scoped machine credentials for server-to-server API access
    (e.g. jobshout filing CMS drafts). A key is an opaque secret shaped
    "opsk_" + 48 hex chars, shown once at creation and stored only as a
    SHA-256 hash so a database leak does not expose usable credentials.

    Each key carries its own permissions JSON ({"cms":["create"]}), which
    at request time is dropped into self.namespace_permissions in place of
    a member's role permissions — a key is never an owner or admin.

    Tables:
      1. api_keys

    Management is gated on the existing namespace.manage permission
    (NamespaceMiddleware.requireAdmin); no new RBAC module is registered.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

local function table_exists(name)
    local r = db.query([[SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists]], name)
    return r[1] and r[1].exists
end
local function index_exists(name)
    local r = db.query([[SELECT EXISTS (SELECT FROM pg_indexes WHERE indexname = ?) as exists]], name)
    return r[1] and r[1].exists
end

return {
    -- ========================================================================
    -- [1] Create api_keys
    -- ========================================================================
    [1] = function()
        if table_exists("api_keys") then return end

        schema.create_table("api_keys", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "name", types.varchar },
            { "key_prefix", types.varchar },                  -- first 12 chars, for display only
            { "key_hash", types.varchar({ unique = true }) }, -- SHA-256 hex of the full raw key
            { "scopes", types.text },                         -- JSON: {"<module>":["<action>", ...]}
            { "created_by", types.integer({ null = true }) }, -- users.id; soft reference
            { "last_used_at", types.time({ null = true }) },
            { "expires_at", types.time({ null = true }) },    -- NULL = never expires
            { "revoked_at", types.time({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE api_keys
                ADD CONSTRAINT api_keys_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        if not index_exists("idx_api_keys_uuid") then
            db.query("CREATE UNIQUE INDEX idx_api_keys_uuid ON api_keys (uuid)")
        end
        -- Listing keys for a namespace; live keys are the common case.
        if not index_exists("idx_api_keys_ns_live") then
            db.query([[
                CREATE INDEX idx_api_keys_ns_live
                ON api_keys (namespace_id)
                WHERE revoked_at IS NULL
            ]])
        end
    end,
}
