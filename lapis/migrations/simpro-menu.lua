--[[
    Field Service — Simpro menu + RBAC seeding

    Registers the modules the Simpro-aligned routes gate on, and the sidebar
    items that give the dashboard Simpro's own information architecture. Simpro
    groups its navigation People / Projects / Materials / Invoicing / Reports,
    and the priorities below interleave the new items with the existing field
    service ones so the sidebar reads in that order:

        30  Service Requests      (intake)
        34  Jobs & Projects
        36  Schedule / Visits
        40  Customers / Sites
        41  Assets                    <- new
        42  Parts
        43  Contracts                 <- new
        44  Employees
        46  Reports                   <- new
        48  Simpro sync               <- new

    Role grants follow the pattern already established for parts: Owner gets
    manage, Admin gets CRUD, and the field service operational roles get the
    slice that matches what they actually do. Engineers can read assets and
    write test history (they survey on site) but never see the portfolio-wide
    report pack or the sync console.

    fs_quotes is registered as a module but gets no sidebar item: quotations are
    still raised from the job screen (lib/quote-pdf.ts), and fs_quotes is where
    they are recorded for Simpro and for the quote-turnaround report. A separate
    Quotes page can come when quotes stop being job-first.

    Feature-gated under FEATURES.FIELD_SERVICE.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local MODULES = {
    { machine_name = "fs_assets", name = "Customer Assets",
      description = "Equipment installed at customer sites: register, condition surveys and test history",
      priority = 41 },
    { machine_name = "fs_contracts", name = "Contracts",
      description = "Maintenance contracts, SLAs and the service levels they cover",
      priority = 43 },
    { machine_name = "fs_quotes", name = "Quotes",
      description = "Remedial and project quotations, and their conversion into jobs",
      priority = 32 },
    { machine_name = "fs_reports", name = "Reports",
      description = "Asset, compliance, labour and performance reports (CSV / PDF / Power BI)",
      priority = 46 },
    { machine_name = "simpro_sync", name = "Simpro Sync",
      description = "Connection to the Simpro build, and the push/pull audit trail",
      priority = 48 },
}

local MENU_ITEMS = {
    { key = "field_service_assets", name = "Assets", icon = "HardDrive",
      path = "/dashboard/field-service/assets", module = "fs_assets", priority = 41 },
    { key = "field_service_contracts", name = "Contracts", icon = "ScrollText",
      path = "/dashboard/field-service/contracts", module = "fs_contracts", priority = 43 },
    { key = "field_service_reports", name = "Reports", icon = "BarChart3",
      path = "/dashboard/field-service/reports", module = "fs_reports", priority = 46 },
    { key = "field_service_simpro", name = "Simpro Sync", icon = "RefreshCw",
      path = "/dashboard/field-service/simpro", module = "simpro_sync", priority = 48 },
}

--- Merge `grants` (module -> actions) into every role whose name matches.
--- Existing entries are left alone so a hand-tuned tenant role is never
--- widened or narrowed by a re-run.
local function grant(role_names, grants)
    local roles = db.select("* FROM namespace_roles WHERE role_name IN ?", db.list(role_names))
    for _, role in ipairs(roles) do
        local perms, changed = {}, false
        if role.permissions and role.permissions ~= "" then
            local ok, decoded = pcall(cjson.decode, role.permissions)
            if ok and type(decoded) == "table" then perms = decoded end
        end
        for machine_name, actions in pairs(grants) do
            if not perms[machine_name] then
                perms[machine_name] = actions
                changed = true
            end
        end
        if changed then
            db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
        end
    end
end

local function all_modules(actions)
    local g = {}
    for _, m in ipairs(MODULES) do g[m.machine_name] = actions end
    return g
end

return {
    -- [1] Register the RBAC modules
    [1] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        for _, mod in ipairs(MODULES) do
            local existing = db.select("* FROM modules WHERE machine_name = ?", mod.machine_name)
            if #existing == 0 then
                db.insert("modules", {
                    uuid = MigrationUtils.generateUUID(),
                    machine_name = mod.machine_name,
                    name = mod.name,
                    description = mod.description,
                    priority = mod.priority,
                    created_at = timestamp,
                    updated_at = timestamp,
                })
                print("[Simpro] Registered module: " .. mod.machine_name)
            else
                -- fs_assets was registered and then deleted by field-service-v2's
                -- drop. If the row came back, make sure its description reflects
                -- the Simpro-shaped table rather than the old one.
                db.update("modules",
                    { name = mod.name, description = mod.description, updated_at = timestamp },
                    { machine_name = mod.machine_name })
            end
        end
    end,

    -- [2] Insert the sidebar items
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        for _, item in ipairs(MENU_ITEMS) do
            local existing = db.select("* FROM menu_items WHERE key = ?", item.key)
            if #existing == 0 then
                db.insert("menu_items", {
                    uuid = MigrationUtils.generateUUID(),
                    key = item.key,
                    name = item.name,
                    icon = item.icon,
                    path = item.path,
                    module = item.module,
                    required_action = "read",
                    priority = item.priority,
                    is_active = true,
                    is_admin_only = false,
                    always_show = false,
                    settings = "{}",
                    created_at = timestamp,
                    updated_at = timestamp,
                })
                print("[Simpro] Added menu item: " .. item.key)
            else
                -- field_service_assets previously pointed at the v2-dropped page.
                db.update("menu_items", {
                    name = item.name, icon = item.icon, path = item.path,
                    module = item.module, priority = item.priority,
                    is_active = true, updated_at = timestamp,
                }, { key = item.key })
            end
        end
    end,

    -- [3] Grant to the platform roles
    [3] = function()
        grant({ "Owner", "owner", "Namespace Owner" },
            all_modules({ "create", "read", "update", "delete", "manage" }))
        grant({ "Admin", "admin", "Namespace Admin" },
            all_modules({ "create", "read", "update", "delete" }))
    end,

    -- [4] Grant to the field service operational roles
    [4] = function()
        -- Service / contracts managers own the asset register, the contracts and
        -- the quotes, and are the audience for the report pack.
        grant({ "Service Manager", "service_manager" }, {
            fs_assets = { "create", "read", "update", "delete" },
            fs_contracts = { "create", "read", "update" },
            fs_quotes = { "create", "read", "update", "delete" },
            fs_reports = { "read" },
            simpro_sync = { "read" },
        })

        -- The service desk logs work and chases quotes; it does not restructure
        -- the asset register or amend contracts.
        grant({ "Telecaller", "telecaller", "Service Coordinator", "service_coordinator" }, {
            fs_assets = { "read" },
            fs_contracts = { "read" },
            fs_quotes = { "create", "read", "update" },
            fs_reports = { "read" },
        })

        -- Engineers survey assets on site: they read the register and write test
        -- history through the visit, but get no portfolio reporting or sync.
        grant({ "Engineer", "engineer" }, {
            fs_assets = { "read", "update" },
            fs_contracts = { "read" },
        })
    end,

    -- [5] Enable the menu items for existing namespaces
    [5] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()
        local namespaces = db.select("* FROM namespaces")

        for _, item in ipairs(MENU_ITEMS) do
            local menu_rows = db.select("* FROM menu_items WHERE key = ?", item.key)
            if #menu_rows > 0 then
                local menu_item = menu_rows[1]
                for _, ns in ipairs(namespaces) do
                    local exists = db.select([[
                        * FROM namespace_menu_config
                        WHERE namespace_id = ? AND menu_item_id = ?
                    ]], ns.id, menu_item.id)
                    if #exists == 0 then
                        db.insert("namespace_menu_config", {
                            uuid = MigrationUtils.generateUUID(),
                            namespace_id = ns.id,
                            menu_item_id = menu_item.id,
                            is_enabled = true,
                            created_at = timestamp,
                            updated_at = timestamp,
                        })
                    end
                end
            end
        end
    end,
}
