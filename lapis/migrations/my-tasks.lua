--[[
    My Tasks page (/dashboard/my-tasks): one sidebar item right after Dashboard,
    on the existing `projects` module (read), enabled for every existing
    namespace. Gated on FEATURES.KANBAN; idempotent (guarded inserts).
]]

local db = require("lapis.db")

local MENU_KEY = "my_tasks"

local function table_exists(name)
    return db.query("SELECT to_regclass(?) IS NOT NULL AS ok", name)[1].ok
end

return {
    [1] = function()
        if not table_exists("menu_items") then return end
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()
        local menu = db.select("* FROM menu_items WHERE key = ?", MENU_KEY)[1]
        if not menu then
            menu = db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = MENU_KEY,
                name = "My Tasks",
                icon = "ListTodo",
                path = "/dashboard/my-tasks",
                module = "projects",
                required_action = "read",
                priority = 2,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = timestamp,
                updated_at = timestamp,
            }, { returning = "*" })[1]
        end
        if table_exists("namespace_menu_config") then
            db.query([[
                INSERT INTO namespace_menu_config (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
                SELECT gen_random_uuid()::text, n.id, ?, true, NOW(), NOW() FROM namespaces n
                WHERE NOT EXISTS (SELECT 1 FROM namespace_menu_config c
                                  WHERE c.namespace_id = n.id AND c.menu_item_id = ?)
            ]], menu.id, menu.id)
        end
        print("[MyTasks] Registered the My Tasks menu item")
    end,
}
