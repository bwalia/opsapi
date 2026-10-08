local CustomerModel = require "models.CustomerModel"
local Global = require "helper.global"
local cjson = require "cjson"

local CustomerQueries = {}

-- These columns are TEXT but the client sends structured data (e.g. addresses as
-- a JSON array). RequestParser decodes such values into Lua tables, which Postgres
-- cannot escape ("unknown table passed to escape_literal"). Serialize any
-- table-valued field back to a JSON string before it reaches the DB.
local JSON_TEXT_FIELDS = { "addresses", "tags" }
local function encode_json_text_fields(p)
    for _, field in ipairs(JSON_TEXT_FIELDS) do
        if type(p[field]) == "table" then
            p[field] = cjson.encode(p[field])
        end
    end
end

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
    -- The client's own user id (Billing & Entitlements); the column exists
    -- only where the billing feature is enabled.
    external_id = require("helper.project-config").isFeatureEnabled("billing") or nil,
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

    encode_json_text_fields(filtered_params)

    return CustomerModel:create(filtered_params, { returning = "*" })
end

function CustomerQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 10
    local namespace_id = params.namespace_id

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, name = true, email = true, phone = true, created_at = true, updated_at = true, first_name = true, last_name = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "created_at", "desc")
    -- There is no `name` column: sorting by name 500'd. Name = first + last.
    if orderField == "name" then orderField = "first_name " .. orderDir .. ", last_name" end

    local where_clause = ""
    local order_clause = " order by " .. orderField .. " " .. orderDir

    -- Filter by namespace if provided
    if namespace_id then
        where_clause = "where namespace_id = " .. tonumber(namespace_id)
    end

    -- ?search= matches email, names and (with billing) the app's external_id.
    local search = type(params.search) == "string" and params.search:match("^%s*(.-)%s*$") or ""
    if search ~= "" and where_clause ~= "" then
        local db = require("lapis.db")
        local like = db.escape_literal("%" .. search:sub(1, 100):gsub("[%%_\\]", "\\%0") .. "%")
        local cols = { "email", "first_name", "last_name" }
        if VALID_CUSTOMER_FIELDS.external_id then cols[#cols + 1] = "external_id" end
        local ors = {}
        for i, c in ipairs(cols) do ors[i] = c .. " ILIKE " .. like end
        where_clause = where_clause .. " and (" .. table.concat(ors, " or ") .. ")"
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

    encode_json_text_fields(filtered_params)

    -- record:update() returns a boolean; with returning="*" it refreshes the
    -- instance in place, so hand back the record itself (callers/route expect the
    -- updated customer object, not `true`).
    record:update(filtered_params, { returning = "*" })
    return record
end

function CustomerQueries.destroy(id)
    local record = CustomerModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

-- Email is unique per workspace (not across workspaces), so a lookup must say which.
function CustomerQueries.findByEmail(namespace_id, email)
    return CustomerModel:find({ namespace_id = namespace_id, email = email })
end

--- Billing runtime: the workspace customer the client's app knows as
-- `external_id` (its own user id). Created on first sight; an existing
-- customer with the same email (and no external_id yet) is adopted.
-- b = { email, first_name, last_name } (email is required to create).
-- @return row | nil, err
function CustomerQueries.upsertExternal(namespace_id, external_id, b)
    local db = require("lapis.db")
    if type(external_id) ~= "string" or not external_id:match("^[%w%-_.:@|]+$") or #external_id > 255 then
        return nil, "external_id must be 1-255 characters: letters, digits and - _ . : @ |"
    end
    local email = b.email ~= nil and b.email ~= cjson.null and tostring(b.email) or nil
    if email and (#email > 254 or not email:match("^[^%s@]+@[^%s@]+%.[^%s@]+$")) then
        return nil, "email is not a valid address"
    end
    local set = {}
    for _, f in ipairs({ "first_name", "last_name" }) do
        local v = b[f]
        if v ~= nil and v ~= cjson.null then
            if type(v) ~= "string" or #v > 120 then return nil, f .. " must be text (max 120)" end
            set[f] = v
        end
    end
    if email then set.email = email end

    local function by_external()
        return db.query("SELECT * FROM customers WHERE namespace_id = ? AND external_id = ?",
            namespace_id, external_id)[1]
    end
    local row = by_external()
    if not row and email then
        row = db.query([[SELECT * FROM customers WHERE namespace_id = ? AND lower(email) = lower(?)
            AND external_id IS NULL LIMIT 1]], namespace_id, email)[1]
        if row then set.external_id = external_id end
    end
    if not row then
        if not email then return nil, "email is required to create a customer" end
        set.uuid, set.namespace_id, set.external_id = Global.generateUUID(), namespace_id, external_id
        set.created_at, set.updated_at = db.raw("NOW()"), db.raw("NOW()")
        local ok, res = pcall(db.insert, "customers", set, { returning = "*" })
        if ok then return res[1] end
        if not tostring(res):find("duplicate key", 1, true) then error(res) end
        row = by_external() -- a concurrent call created it
        if not row then return nil, "another customer already uses this email" end
        return row
    end
    if next(set) ~= nil then
        set.updated_at = db.raw("NOW()")
        local ok, err = pcall(db.update, "customers", set, { id = row.id })
        if not ok then
            if tostring(err):find("duplicate key", 1, true) then
                return nil, "another customer already uses this email"
            end
            error(err)
        end
        row = db.query("SELECT * FROM customers WHERE id = ?", row.id)[1]
    end
    return row
end

return CustomerQueries
