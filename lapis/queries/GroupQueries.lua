local Global = require "helper.global"
local Groups = require "models.GroupModel"
local Users = require "models.UserModel"
local UserGroupModel = require "models.UserGroupModel"
local Validation = require "helper.validations"
local Json = require("cjson")


local GroupQueries = {}

function GroupQueries.create(data)
    Validation.createGroup(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    return Groups:create(data, {
        returning = "*"
    })
end

function GroupQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    local paginated = Groups:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    -- Append the members into group object
    local groups, groupWmembers = paginated:get_page(page), {}
    for gI, group in ipairs(groups) do
        group:get_members()
        for index, member in ipairs(group.members) do
            local memberData = Users:find(member.id)
            group.members[index] = memberData
        end
        group.internal_id = group.id
        group.id = group.uuid
        table.insert(groupWmembers, group)
    end
    return {
        data = groupWmembers,
        total = paginated:total_items()
    }
end

function GroupQueries.show(id)
    local group = Groups:find({
        uuid = id
    })
    if group then
        group:get_members()
        for index, member in ipairs(group.members) do
            local memberData = Users:find(member.id)
            group.members[index] = memberData
        end
        group.internal_id = group.id
        group.id = group.uuid
        return group, ngx.HTTP_OK
    end
end

function GroupQueries.update(id, params)
    local role = Groups:find({
        uuid = id
    })
    params.id = role.id
    return role:update(params, {
        returning = "*"
    })
end

function GroupQueries.destroy(id)
    local role = Groups:find({
        uuid = id
    })
    return role:delete()
end

function GroupQueries.addMember(groupId, userId)
    if not groupId or not userId then
        return { error = "Group id and user id is must" }, 400
    end
    local group = Groups:find({
        uuid = groupId
    })
    if not group then
        return { error = "Group not found please check UUID of group" }, 400
    end
    local userIds = userId
    if type(userIds) == "string" then
        userIds = {userIds}
    else
        local placeholders = {}
        for key, uId in pairs(userIds) do
            table.insert(placeholders, uId)
        end
        userIds = placeholders
    end

    local user = Users:find_all(userIds, "uuid")
    user.password = nil
    if user then
        for index, userData in ipairs(user) do
            local ugData = {
                uuid = Global.generateUUID(),
                user_id = userData.id,
                group_id = group.id
            }
            local userGroup = UserGroupModel:create(ugData, {
                returning = "*"
            })
            if not userGroup then
                return { error = "Unable to make realtion" }, 400
            end
        end
        return { group, user }, 201
    else
        return { error = "User not found" }, 400
    end
end

-- SCIM functions

function GroupQueries.SCIMall(params)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    local paginated = Groups:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    -- Append the members into group object
    local groups, groupWmembers = paginated:get_page(page), {}
    for gI, group in ipairs(groups) do
        group:get_members()
        for index, member in ipairs(group.members) do
            local memberData = Users:find(member.user_id)
            local scimMemberData = {
                value = memberData.uuid,
                display = memberData.first_name .. " " .. memberData.last_name,
            }
            scimMemberData["$ref"] = "/scim/v2/Users/" .. memberData.uuid
            group.members[index] = scimMemberData
        end
        table.insert(groupWmembers, Global.scimGroupSchema(group))
    end
    return {
        Resources = groupWmembers,
        totalResults = paginated:total_items()
    }
end

function GroupQueries.SCIMupdate(id, params)
    local group = Groups:find({
        uuid = id
    })
    params.id = nil

    local groupBody = {
        name = params.displayName or group.name
    }

    local isUpdate = group:update(groupBody, {
        returning = "*"
    })
    if isUpdate then
        local groupMembers = UserGroupModel:find_all({group.id}, "group_id")
        for i, groupMember in ipairs(groupMembers) do
            groupMember:delete()
        end
        local response = {}
        for _, member in ipairs(params.members) do
            local groupMember, status = GroupQueries.addMember(id, member.value)
            table.insert(response, groupMember)
        end
        return response, 200
    end
end

return GroupQueries