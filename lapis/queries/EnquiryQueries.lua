local Global = require "helper.global"
local Enquiries = require "models.EnquiriesModel"
local Validation = require "helper.validations"
local PermissionQueries = require "queries.PermissionQueries"


local EnquiryQueries = {}

function EnquiryQueries.create(data)
    Validation.createEnquiry(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    local enquiry = Enquiries:create(data, {
        returning = "*"
    })
    return {
        data = enquiry
    }
end

function EnquiryQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Enquiries:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    local enquries = {}
    for _, enquiry in ipairs(paginated:get_page(page)) do
        enquiry.internal_id = enquiry.id
        enquiry.id = enquiry.uuid
        table.insert(enquries, enquiry)
    end
    return {
        data = enquries,
        total = paginated:total_items()
    }
end

function EnquiryQueries.show(id)
    local enquiry = Enquiries:find({
        uuid = id
    })
    enquiry.internal_id = enquiry.id
    enquiry.id = enquiry.uuid
    return enquiry
end

function EnquiryQueries.update(id, params)
    local module = Enquiries:find({
        uuid = id
    })
    params.id = module.id
    return module:update(params, {
        returning = "*"
    })
end

function EnquiryQueries.destroy(id)
    local module = Enquiries:find({
        uuid = id
    })
    return module:delete()
end

function EnquiryQueries.getByMachineName(mName)
    local module = Enquiries:find({
        machine_name = mName
    })
    return module
end

return EnquiryQueries
