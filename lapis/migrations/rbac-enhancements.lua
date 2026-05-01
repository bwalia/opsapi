local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Add description column to roles table
    [1] = function()
        -- Check if column already exists
        local result = db.query([[
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'roles' AND column_name = 'description'
        ]])
        if #result == 0 then
            schema.add_column("roles", "description", types.text({ null = true }))
        end
    end,

    -- Seed default modules for dashboard RBAC
    [2] = function()
        local modules = {
            { uuid = "m-dashboard-001", machine_name = "dashboard", name = "Dashboard", description = "Main dashboard overview and analytics", priority = "1" },
            { uuid = "m-users-002", machine_name = "users", name = "Users", description = "User management and administration", priority = "2" },
            { uuid = "m-roles-003", machine_name = "roles", name = "Roles", description = "Role management and configuration", priority = "3" },
            { uuid = "m-stores-004", machine_name = "stores", name = "Stores", description = "Store management and operations", priority = "4" },
            { uuid = "m-products-005", machine_name = "products", name = "Products", description = "Product catalog management", priority = "5" },
            { uuid = "m-orders-006", machine_name = "orders", name = "Orders", description = "Order processing and management", priority = "6" },
            { uuid = "m-customers-007", machine_name = "customers", name = "Customers", description = "Customer management and profiles", priority = "7" },
            { uuid = "m-settings-008", machine_name = "settings", name = "Settings", description = "System settings and configuration", priority = "8" },
            { uuid = "m-namespaces-009", machine_name = "namespaces", name = "Namespaces", description = "Platform namespace and tenant management", priority = "9" },
        }

        for _, module in ipairs(modules) do
            -- Check if module already exists
            local existing = db.select("* FROM modules WHERE machine_name = ?", module.machine_name)
            if #existing == 0 then
                db.insert("modules", {
                    uuid = module.uuid,
                    machine_name = module.machine_name,
                    name = module.name,
                    description = module.description,
                    priority = module.priority,
                    created_at = db.raw("NOW()"),
                    updated_at = db.raw("NOW()")
                })
            end
        end
    end,

    -- Add namespaces module (for existing installations)
    [3] = function()
        local existing = db.select("* FROM modules WHERE machine_name = ?", "namespaces")
        if #existing == 0 then
            db.insert("modules", {
                uuid = "m-namespaces-009",
                machine_name = "namespaces",
                name = "Namespaces",
                description = "Platform namespace and tenant management",
                priority = "9",
                created_at = db.raw("NOW()"),
                updated_at = db.raw("NOW()")
            })
        end
    end,
}
