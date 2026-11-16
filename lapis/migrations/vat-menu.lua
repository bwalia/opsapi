--[[
    VAT screens (VAT plan phase 5): "VAT" under the Tax menu -> /dashboard/tax/vat.
    Shown to whoever can use File My Tax (module tax_statements). Idempotent; skips
    when there is no menu or no Tax parent (e.g. a deployment without tax_copilot).
]]

local db = require("lapis.db")

return {
    [1] = function()
        local ok = db.query("SELECT to_regclass('public.menu_items') IS NOT NULL AS ok")[1]
        if not (ok and (ok.ok == true or ok.ok == "t")) then return end
        local parent = db.select("id FROM menu_items WHERE key = ? LIMIT 1", "tax")
        if not parent[1] then return end
        if #db.select("id FROM menu_items WHERE key = ?", "tax_vat") > 0 then return end
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()
        db.insert("menu_items", {
            uuid = MigrationUtils.generateUUID(),
            key = "tax_vat", name = "VAT", icon = "Receipt", path = "/dashboard/tax/vat",
            module = "tax_statements", required_action = "read", priority = 36,
            parent_id = parent[1].id, is_active = true, is_admin_only = false, always_show = false,
            settings = "{}", created_at = ts, updated_at = ts,
        })
        print("[VAT] menu item: Tax -> VAT")
    end,

    [2] = function()
        -- RBAC modules "vat" (workspace VAT, VAT groups) and "vat_agent" (accountants), as in
        -- helper/project-config.lua PROJECT_MODULES.vat. Granted to owner/admin roles on FIRST
        -- insert only, so a permission an admin later takes away stays taken away.
        for _, m in ipairs({
            { "vat", "VAT", "VAT registration, VAT coding rules and VAT records" },
            { "vat_agent", "VAT clients (accountants)",
                "Act for clients' VAT once HMRC confirms the client authorised you" },
        }) do
            local inserted = db.query([[
                INSERT INTO modules (uuid, machine_name, name, description, category, priority,
                                     is_active, is_system, default_actions, created_at, updated_at)
                VALUES (gen_random_uuid()::text, ?, ?, ?, 'Accounting', '0', true, false,
                        'create,read,update,delete,manage', NOW(), NOW())
                ON CONFLICT (machine_name) DO NOTHING
                RETURNING id
            ]], m[1], m[2], m[3])
            if inserted[1] then
                require("queries.ModuleQueries").propagateToNamespaceAdmins(m[1])
                print("[VAT] Registered module " .. m[1] .. "; granted to owner/admin roles")
            end
        end
    end,

    -- 3. Step 2 grants only when IT creates the module, but on existing installs
    --    scripts/setup-namespace.lua had already created "vat" and "vat_agent" (from
    --    PROJECT_MODULES, without granting them), so no owner or admin held them and
    --    workspace VAT, groups and accountants worked only for platform admins. Grant
    --    them to owner/admin roles in every workspace where no role has the key yet
    --    (a workspace that already set it, even by taking it away, is left alone).
    [3] = function()
        local cjson = require("cjson.safe")
        local t = db.query("SELECT to_regclass('public.namespace_roles') IS NOT NULL AS ok")[1]
        if not (t and (t.ok == true or t.ok == "t")) then return end
        local roles = db.query("SELECT id, namespace_id, role_name, permissions FROM namespace_roles") or {}
        for _, key in ipairs({ "vat", "vat_agent" }) do
            local configured, granted = {}, 0
            for _, r in ipairs(roles) do
                local perms = type(r.permissions) == "string" and cjson.decode(r.permissions) or nil
                if type(perms) == "table" and perms[key] ~= nil then configured[r.namespace_id] = true end
            end
            for _, r in ipairs(roles) do
                if (r.role_name == "owner" or r.role_name == "admin") and not configured[r.namespace_id] then
                    local perms = type(r.permissions) == "string" and cjson.decode(r.permissions) or nil
                    if type(perms) == "table" then
                        perms[key] = { "manage" }
                        local enc = cjson.encode(perms)
                        db.update("namespace_roles", { permissions = enc }, { id = r.id })
                        r.permissions = enc
                        granted = granted + 1
                    end
                end
            end
            print("[VAT] " .. key .. ": granted to " .. granted .. " owner/admin role(s)")
        end
    end,
}
