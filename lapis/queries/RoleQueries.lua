local Global = require "helper.global"
local db = require("lapis.db")
local Model = require("lapis.db.model").Model
local Validation = require "helper.validations"


local Roles = Model:extend("roles")
local RoleQueries = {}

function RoleQueries.create(roleData)
    Validation.createRole(roleData)
    if roleData.uuid == nil then
        roleData.uuid = Global.generateUUID()
    end
    return Roles:create(roleData, {
        returning = "*"
    })
end

function RoleQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Roles:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields = 'id as internal_id, uuid as id, role_name, created_at, updated_at'
    })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function RoleQueries.show(id)
    -- Try UUID first (string format), then try numeric ID
    local role = Roles:find({ uuid = tostring(id) })
    if not role and tonumber(id) then
        role = Roles:find({ id = tonumber(id) })
    end
    return role
end

function RoleQueries.update(id, params)
    local role = RoleQueries.show(id)
    if not role then
        return nil
    end
    
    role:update(params)
    return role
end

function RoleQueries.destroy(id)
    local role = RoleQueries.show(id)
    if not role then
        return nil
    end
    
    return role:delete()
end

function RoleQueries.roleByName(name)
    return Roles:find({
        role_name = tostring(name)
    })
end

-- Alias for list (used by routes/roles.lua)
function RoleQueries.list(params)
    return RoleQueries.all(params).data
end

-- Count all roles
function RoleQueries.count()
    local result = db.query("SELECT COUNT(*) as count FROM roles")
    return result[1] and result[1].count or 0
end

-- Delete role by ID or UUID
function RoleQueries.delete(id)
    local role = RoleQueries.show(id)
    if not role then
        return nil
    end
    return role:delete()
end

return RoleQueries