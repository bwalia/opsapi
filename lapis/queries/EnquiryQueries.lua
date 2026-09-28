local Global = require "helper.global"
local Enquiries = require "models.EnquiriesModel"
local Validation = require "helper.validations"
local PermissionQueries = require "queries.PermissionQueries"


local EnquiryQueries = {}

-- Every function takes the caller's namespace_id: enquiries are tenant data.
-- Lookups by uuid are always AND namespace_id, so another tenant's enquiry is
-- simply "not found".

-- Fields a client may set; never uuid/id/namespace_id.
local WRITABLE = { "name", "email", "phone_no", "comments" }

local function pick(params)
    local out = {}
    for _, k in ipairs(WRITABLE) do
        if params[k] ~= nil then out[k] = params[k] end
    end
    return out
end

local function find(id, namespace_id)
    return Enquiries:find({ uuid = id, namespace_id = namespace_id })
end

function EnquiryQueries.create(data, namespace_id)
    Validation.createEnquiry(data)
    local row = pick(data)
    row.uuid = Global.generateUUID()
    row.namespace_id = namespace_id
    local enquiry = Enquiries:create(row, {
        returning = "*"
    })
    return {
        data = enquiry
    }
end

function EnquiryQueries.all(params, namespace_id)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, email = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    local paginated = Enquiries:paginated("where namespace_id = ? order by " .. orderField .. " " .. orderDir,
        namespace_id, { per_page = perPage })
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

function EnquiryQueries.show(id, namespace_id)
    local enquiry = find(id, namespace_id)
    if not enquiry then return nil end
    enquiry.internal_id = enquiry.id
    enquiry.id = enquiry.uuid
    return enquiry
end

function EnquiryQueries.update(id, params, namespace_id)
    local enquiry = find(id, namespace_id)
    if not enquiry then return nil end
    local changes = pick(params)
    if next(changes) == nil then return enquiry end
    return enquiry:update(changes, {
        returning = "*"
    })
end

function EnquiryQueries.destroy(id, namespace_id)
    local enquiry = find(id, namespace_id)
    if not enquiry then return nil end
    return enquiry:delete()
end

function EnquiryQueries.getByMachineName(mName)
    local module = Enquiries:find({
        machine_name = mName
    })
    return module
end

return EnquiryQueries
