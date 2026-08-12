--[[
    Render Templates (namespace Template Library) Migrations
    ========================================================

    A namespace-scoped library of reusable "{{slot}}" templates. One template is
    a plain string with `{{placeholder}}` slots + an optional sample_data JSON.
    `template_type` discriminates what a template is for:
       - 'cms_page'        HTML page layout ({{title}}, {{content}}, …) chosen in
                           the CMS page editor.
       - 'domain_wslproxy' WSL Proxy vhost JSON format for the domains sync.

    Tables:
      1. render_templates  (namespace-scoped, soft-deleted)

    Also registers the "templates" RBAC module and grants it to owner/admin so
    the CMS "Templates" tab and the domain template picker are permissioned.
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
    -- [1] Create render_templates
    -- ========================================================================
    [1] = function()
        if table_exists("render_templates") then return end

        schema.create_table("render_templates", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer },
            { "name", types.varchar },
            { "slug", types.varchar },
            { "template_type", types.varchar({ default = "cms_page" }) },
            { "content", types.text({ null = true }) },       -- the template body ({{slots}})
            { "sample_data", types.text({ null = true }) },   -- JSON sample for preview
            { "description", types.text({ null = true }) },
            { "is_default", types.boolean({ default = false }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "deleted_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE render_templates
                ADD CONSTRAINT render_templates_namespace_fk
                FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE
            ]])
        end)

        pcall(function()
            db.query([[
                ALTER TABLE render_templates
                ADD CONSTRAINT render_templates_type_check
                CHECK (template_type IN ('cms_page', 'domain_wslproxy'))
            ]])
        end)

        -- Unique slug per (namespace, type) among live rows.
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX render_templates_ns_type_slug_unique
                ON render_templates (namespace_id, template_type, slug)
                WHERE deleted_at IS NULL
            ]])
        end)

        if not index_exists("idx_render_templates_uuid") then
            db.query("CREATE UNIQUE INDEX idx_render_templates_uuid ON render_templates (uuid)")
        end
        if not index_exists("idx_render_templates_ns_type") then
            db.query([[
                CREATE INDEX idx_render_templates_ns_type
                ON render_templates (namespace_id, template_type)
                WHERE deleted_at IS NULL
            ]])
        end
    end,

    -- ========================================================================
    -- [2] Register the "templates" RBAC module + grant to owner/admin roles
    -- ========================================================================
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()

        local existing = db.select("* FROM modules WHERE machine_name = ?", "templates")
        if #existing == 0 then
            db.insert("modules", {
                uuid = MigrationUtils.generateUUID(),
                machine_name = "templates",
                name = "Templates",
                description = "Reusable {{slot}} templates for CMS pages and domain sync formats",
                priority = 47,
                created_at = ts,
                updated_at = ts,
            })
            print("[Templates] Registered module: templates")
        end

        local cjson_ok, cjson = pcall(require, "cjson")
        if not cjson_ok then return end

        local owner_roles = db.select(
            "* FROM namespace_roles WHERE role_name IN ('Owner', 'owner', 'Namespace Owner')")
        local owner_actions = { "create", "read", "update", "delete", "manage" }
        for _, role in ipairs(owner_roles) do
            local perms = {}
            if role.permissions and role.permissions ~= "" then
                local ok, decoded = pcall(cjson.decode, role.permissions)
                if ok and type(decoded) == "table" then perms = decoded end
            end
            if not perms["templates"] then perms["templates"] = owner_actions end
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
        end

        local admin_roles = db.select(
            "* FROM namespace_roles WHERE role_name IN ('Admin', 'admin', 'Namespace Admin')")
        local admin_actions = { "create", "read", "update", "delete" }
        for _, role in ipairs(admin_roles) do
            local perms = {}
            if role.permissions and role.permissions ~= "" then
                local ok, decoded = pcall(cjson.decode, role.permissions)
                if ok and type(decoded) == "table" then perms = decoded end
            end
            if not perms["templates"] then perms["templates"] = admin_actions end
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
        end
    end,

    -- ========================================================================
    -- [3] Widen the template_type CHECK to also allow 'domain_rule' (the WSL
    --     Proxy *rule* JSON format, alongside the server format domain_wslproxy).
    --     Idempotent: drop-if-exists then recreate with the full set.
    -- ========================================================================
    [3] = function()
        pcall(function()
            db.query("ALTER TABLE render_templates DROP CONSTRAINT IF EXISTS render_templates_type_check")
        end)
        pcall(function()
            db.query([[
                ALTER TABLE render_templates
                ADD CONSTRAINT render_templates_type_check
                CHECK (template_type IN ('cms_page', 'domain_wslproxy', 'domain_rule'))
            ]])
        end)
    end,
}
