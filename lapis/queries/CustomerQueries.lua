local CustomerModel = require "models.CustomerModel"
local Global = require "helper.global"

local CustomerQueries = {}

-- Valid fields for customer creation (matches database schema)
local VALID_CUSTOMER_FIELDS = {
    uuid = true,
    email = true,
    first_name = true,
    last_name = true,
    phone = true,
    date_of_birth = true,
    addresses = true,
    notes = true,
    tags = true,
    accepts_marketing = true,
    namespace_id = true,
    marketing_opt_in_level = true,
    verified_email = true,
    tax_exempt = true,
    state = true,
    user_id = true,
}

function CustomerQueries.create(params)
    -- Filter to only valid fields
    local filtered_params = {}
    for field, _ in pairs(VALID_CUSTOMER_FIELDS) do
        if params[field] ~= nil then
            filtered_params[field] = params[field]
        end
    end

    -- Generate UUID if not provided
    if not filtered_params.uuid then
        filtered_params.uuid = Global.generateUUID()
    end

    -- Handle boolean fields - convert string 'true'/'false' to actual boolean
    if filtered_params.accepts_marketing ~= nil then
        if type(filtered_params.accepts_marketing) == "string" then
            filtered_params.accepts_marketing = filtered_params.accepts_marketing == "true"
        end
    end
    if filtered_params.verified_email ~= nil then
        if type(filtered_params.verified_email) == "string" then
            filtered_params.verified_email = filtered_params.verified_email == "true"
        end
    end
    if filtered_params.tax_exempt ~= nil then
        if type(filtered_params.tax_exempt) == "string" then
            filtered_params.tax_exempt = filtered_params.tax_exempt == "true"
        end
    end

    return CustomerModel:create(filtered_params, { returning = "*" })
end

function CustomerQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 10
    local namespace_id = params.namespace_id

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, email = true, phone = true, created_at = true, updated_at = true, first_name = true, last_name = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "created_at", "desc")

    local where_clause = ""
    local order_clause = " order by " .. orderField .. " " .. orderDir

    -- Filter by namespace if provided
    if namespace_id then
        where_clause = "where namespace_id = " .. tonumber(namespace_id)
    end

    local paginated = CustomerModel:paginated(where_clause .. order_clause, {
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

    -- Filter to only valid fields (exclude uuid and namespace_id for updates)
    local filtered_params = {}
    for field, _ in pairs(VALID_CUSTOMER_FIELDS) do
        if field ~= "uuid" and field ~= "namespace_id" and params[field] ~= nil then
            filtered_params[field] = params[field]
        end
    end

    -- Handle boolean fields - convert string 'true'/'false' to actual boolean
    if filtered_params.accepts_marketing ~= nil then
        if type(filtered_params.accepts_marketing) == "string" then
            filtered_params.accepts_marketing = filtered_params.accepts_marketing == "true"
        end
    end
    if filtered_params.verified_email ~= nil then
        if type(filtered_params.verified_email) == "string" then
            filtered_params.verified_email = filtered_params.verified_email == "true"
        end
    end
    if filtered_params.tax_exempt ~= nil then
        if type(filtered_params.tax_exempt) == "string" then
            filtered_params.tax_exempt = filtered_params.tax_exempt == "true"
        end
    end

    return record:update(filtered_params, { returning = "*" })
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
