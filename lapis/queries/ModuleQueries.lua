local Global = require "helper.global"
local Modules = require "models.ModuleModel"
local Validation = require "helper.validations"
local PermissionQueries = require "queries.PermissionQueries"
local db = require("lapis.db")
local cjson = require("cjson")


local ModuleQueries = {}

function ModuleQueries.create(data)
    Validation.createModule(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    local module = Modules:create(data, {
        returning = "*"
    })
    if module then
        local pData = {
            module_id = module.id,
            permissions = "read,write,delete",
            role = "administrative"
        }
        PermissionQueries.createWithModuleId(pData)

        -- Auto-propagate new module to all namespace admin/owner roles
        ModuleQueries.propagateToNamespaceAdmins(module.machine_name)

        return module
    end
end

--- Auto-add "manage" permission for a new module to admin and owner roles
-- Scoped by project_code: only propagates to namespaces matching the module's project
-- @param machine_name string The module's machine_name
-- @param project_code string|nil Optional project code to scope propagation
function ModuleQueries.propagateToNamespaceAdmins(machine_name, project_code)
    local admin_roles

    if project_code and project_code ~= "" and project_code ~= "all" then
        -- Scoped: only propagate to namespaces with matching project_code (or "all"/NULL)
        admin_roles = db.query([[
            SELECT nr.id, nr.permissions FROM namespace_roles nr
            JOIN namespaces n ON nr.namespace_id = n.id
            WHERE nr.role_name IN ('admin', 'owner')
            AND (n.project_code = ? OR n.project_code = 'all' OR n.project_code IS NULL)
        ]], project_code)
    else
        -- No scope: propagate to all namespaces
        admin_roles = db.query(
            "SELECT id, permissions FROM namespace_roles WHERE role_name IN ('admin', 'owner')"
        )
    end
    for _, role in ipairs(admin_roles or {}) do
        local ok, perms = pcall(cjson.decode, role.permissions or "{}")
        if ok and not perms[machine_name] then
            perms[machine_name] = { "manage" }
            db.update("namespace_roles", {
                permissions = cjson.encode(perms)
            }, { id = role.id })
        end
    end
end

function ModuleQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, machine_name = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    local paginated = Modules:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function ModuleQueries.show(id)
    return Modules:find({
        uuid = id
    })
end

function ModuleQueries.update(id, params)
    local module = Modules:find({
        uuid = id
    })
    if not module then
        return nil
    end
    -- Remove routing/identity params to avoid overwriting primary key or UUID
    params.id = nil
    params.uuid = nil
    params.splat = nil
    return module:update(params, {
        returning = "*"
    })
end

function ModuleQueries.destroy(id)
    local module = Modules:find({
        uuid = id
    })
    if not module then
        return nil
    end
    return module:delete()
end

function ModuleQueries.getByMachineName(mName)
    local module = Modules:find({
        machine_name = mName
    })
    return module
end

return ModuleQueries