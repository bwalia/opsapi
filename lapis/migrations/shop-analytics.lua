-- luacheck: max line length 140
--[[
    Shop Analytics (FEATURES.SHOP) — registered as zzs31–zzs35 in migrations.lua
    =============================================================================
    [1] Window indexes: the analytics queries filter every shop table by
        (namespace_id, <timestamp>); without these each report scans the tenant.
    [2] RBAC module "shop_analytics" (category Commerce, as in PROJECT_MODULES).
    [3] Grant it to existing owner + admin roles. requirePermission lets only
        platform admins bypass RBAC, so without this owners would get a 403.
        Members get nothing; an owner grants it to whoever should see revenue.
    [4] Sidebar item "Shop Analytics" in the Shop & Orders group.
    [5] Enable that item for every existing namespace.

    No new tables and no visitor data: analytics are derived from shop_* rows.
]]

local db = require("lapis.db")

local MODULE = "shop_analytics"

return {
    [1] = function()
        local indexes = {
            "CREATE INDEX IF NOT EXISTS shop_orders_ns_paid_at_idx ON shop_orders (namespace_id, paid_at) WHERE paid_at IS NOT NULL",
            "CREATE INDEX IF NOT EXISTS shop_orders_ns_created_at_idx ON shop_orders (namespace_id, created_at)",
            "CREATE INDEX IF NOT EXISTS shop_carts_ns_created_at_idx ON shop_carts (namespace_id, created_at)",
            "CREATE INDEX IF NOT EXISTS shop_quotes_ns_created_at_idx ON shop_quotes (namespace_id, created_at)",
            "CREATE INDEX IF NOT EXISTS shop_chat_sessions_ns_created_at_idx ON shop_chat_sessions (namespace_id, created_at)",
        }
        for _, sql in ipairs(indexes) do db.query(sql) end
    end,

    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()
        if #db.select("* FROM modules WHERE machine_name = ?", MODULE) == 0 then
            db.insert("modules", {
                uuid = MigrationUtils.generateUUID(),
                machine_name = MODULE,
                name = "Shop Analytics",
                description = "Shop sales, checkout, cart, quote and AI chat reporting",
                priority = 41,
                created_at = timestamp,
                updated_at = timestamp,
            })
            print("[ShopAnalytics] Registered module: " .. MODULE)
        end
        local has_category = db.query([[
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'modules' AND column_name = 'category'
        ]])[1]
        if has_category then
            db.query([[
                UPDATE modules SET category = 'Commerce', updated_at = NOW()
                 WHERE machine_name = ? AND (category IS NULL OR category = '')
            ]], MODULE)
        end
    end,

    [3] = function()
        local cjson_ok, cjson = pcall(require, "cjson")
        if not cjson_ok then return end

        local function grant(role_names, actions)
            local roles = db.select("* FROM namespace_roles WHERE role_name IN ?", db.list(role_names))
            for _, role in ipairs(roles) do
                local perms = {}
                if type(role.permissions) == "table" then
                    perms = role.permissions
                elseif role.permissions and role.permissions ~= "" then
                    local ok, decoded = pcall(cjson.decode, role.permissions)
                    if ok and type(decoded) == "table" then perms = decoded end
                end
                if not perms[MODULE] then
                    perms[MODULE] = actions
                    db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
                end
            end
        end

        grant({ "Owner", "owner", "Namespace Owner" }, { "create", "read", "update", "delete", "manage" })
        grant({ "Admin", "admin", "Namespace Admin" }, { "create", "read", "update", "delete" })
    end,

    [4] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()
        if #db.select("* FROM menu_items WHERE key = ?", MODULE) == 0 then
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = MODULE,
                name = "Shop Analytics",
                icon = "BarChart3",
                path = "/dashboard/shop/analytics",
                module = MODULE,
                required_action = "read",
                priority = 41,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = '{"group":"commerce"}',
                created_at = timestamp,
                updated_at = timestamp,
            })
            print("[ShopAnalytics] Added menu item: " .. MODULE)
        end
    end,

    [5] = function()
        db.query([[
            INSERT INTO namespace_menu_config (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
            SELECT gen_random_uuid()::text, n.id, mi.id, true, NOW(), NOW()
              FROM namespaces n
             CROSS JOIN menu_items mi
             WHERE mi.key = ']] .. MODULE .. [['
               AND NOT EXISTS (
                   SELECT 1 FROM namespace_menu_config c
                    WHERE c.namespace_id = n.id AND c.menu_item_id = mi.id
               )
        ]])
    end,
}
