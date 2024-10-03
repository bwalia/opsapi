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
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

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
        table.insert(groupWmembers, Global.scimGroupSchema(group))
    end
    return {
        Resources = groupWmembers,
        totalResults = paginated:total_items()
    }
end

function GroupQueries.show(id)
    return Groups:find({
        uuid = id
    })
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
    if not groupId or not userId.user_id then
        return {error = "Group id and user id is must"}, 400
    end
    local group = Groups:find({
        uuid = groupId
    })
    if not group then
        return {error = "Group not found please check UUID of group"}, 400
    end
    local userIds = userId.user_id
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
    if user then
        for index, userData in ipairs(user) do
            local ugData = {
                uuid = Global.generateUUID(),
                user_id = userData.id,
                group_id = group.id
            }
            UserGroupModel:create(ugData, {
                returning = "*"
            })
        end
        return {group, user}, 201
    else
        return {error = "User not found"}, 400
    end
end

return GroupQueries