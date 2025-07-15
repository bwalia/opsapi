local CustomerModel = require "models.CustomerModel"
local Global = require "helper.global"

local CustomerQueries = {}

function CustomerQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    return CustomerModel:create(params, { returning = "*" })
end

function CustomerQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = CustomerModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function CustomerQueries.show(id)
    return CustomerModel:find({ uuid = id })
end

function CustomerQueries.update(id, params)
    local record = CustomerModel:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function CustomerQueries.destroy(id)
    local record = CustomerModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

function CustomerQueries.findByEmail(email)
    return CustomerModel:find({ email = email })
end

return CustomerQueries
