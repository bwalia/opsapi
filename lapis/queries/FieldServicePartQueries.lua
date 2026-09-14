--[[
    Field Service — parts catalog queries
    ======================================

    The master list of parts / products we fit on jobs. Namespace-scoped. Job
    items may link to a part (fs_job_items.part_id) for reporting; the catalog
    itself is just CRUD.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local FsPartModel = require("models.FsPartModel")
local Common = require("queries.FieldServiceCommon")

local nilify, nullable, to_number, to_bool, arr =
    Common.nilify, Common.nullable, Common.to_number, Common.to_bool, Common.arr

local PartQueries = {}

local function shape_part(p)
    return {
        uuid = p.uuid,
        sku = p.sku,
        name = p.name,
        description = p.description,
        category = p.category,
        unit_cost = p.unit_cost,
        unit_price = p.unit_price,
        tax_rate = tonumber(p.tax_rate) or 0,
        stock_quantity = p.stock_quantity,
        reorder_level = p.reorder_level,
        is_active = p.is_active,
        metadata = Common.decode(p.metadata, {}),
        created_at = p.created_at,
        updated_at = p.updated_at,
    }
end

function PartQueries.listParts(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where = { "namespace_id = ?", "deleted_at IS NULL" }
    local values = { namespace_id }

    if not to_bool(params.include_inactive, false) and params.is_active == nil then
        table.insert(where, "is_active = true")
    elseif params.is_active ~= nil and params.is_active ~= "" then
        table.insert(where, "is_active = ?")
        table.insert(values, to_bool(params.is_active, true))
    end
    if nilify(params.category) then
        table.insert(where, "category = ?")
        table.insert(values, tostring(params.category))
    end
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        table.insert(where, "(name ILIKE ? OR sku ILIKE ? OR description ILIKE ? OR category ILIKE ?)")
        for _ = 1, 4 do table.insert(values, term) end
    end
    local where_sql = table.concat(where, " AND ")

    local count = db.query("SELECT COUNT(*) AS total FROM fs_parts WHERE " .. where_sql, unpack(values))

    local page_values = { unpack(values) }
    table.insert(page_values, per_page)
    table.insert(page_values, offset)
    local rows = db.query("SELECT * FROM fs_parts WHERE " .. where_sql .. " ORDER BY name ASC LIMIT ? OFFSET ?",
        unpack(page_values))

    local items = {}
    for _, p in ipairs(rows or {}) do table.insert(items, shape_part(p)) end
    return { items = arr(items), meta = Common.meta(count[1].total, page, per_page) }
end

function PartQueries.getPart(namespace_id, uuid)
    local rows = db.query("SELECT * FROM fs_parts WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1",
        tostring(uuid), namespace_id)
    return rows and rows[1] and shape_part(rows[1]) or nil
end

local TEXT_FIELDS = { "sku", "name", "description", "category" }
local NUM_FIELDS = { "unit_cost", "unit_price", "stock_quantity", "reorder_level" }

local function validate_tax(data)
    if data.tax_rate == nil then return true end
    local r = to_number(data.tax_rate)
    if r and (r < 0 or r > 100) then return false end
    return true
end

function PartQueries.createPart(namespace_id, actor_uuid, data)
    if not nilify(data.name) then return nil, "name is required" end
    if not validate_tax(data) then return nil, "tax_rate must be between 0 and 100" end

    local fields = {
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        tax_rate = to_number(data.tax_rate) or 0,
        is_active = to_bool(data.is_active, true),
        created_by_uuid = nilify(actor_uuid),
    }
    for _, f in ipairs(TEXT_FIELDS) do fields[f] = nilify(data[f]) end
    for _, f in ipairs(NUM_FIELDS) do fields[f] = to_number(data[f]) end
    if type(data.metadata) == "table" then fields.metadata = cjson.encode(data.metadata) end

    local part = FsPartModel:create(fields)
    return PartQueries.getPart(namespace_id, part.uuid)
end

function PartQueries.updatePart(namespace_id, uuid, data)
    local id = Common.resolve_id("fs_parts", namespace_id, uuid)
    if not id then return nil, "Part not found" end
    if not validate_tax(data) then return nil, "tax_rate must be between 0 and 100" end

    local update = {}
    for _, f in ipairs(TEXT_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if update.name == db.NULL then return nil, "name cannot be empty" end
    for _, f in ipairs(NUM_FIELDS) do
        if data[f] ~= nil then update[f] = to_number(data[f]) or db.NULL end
    end
    if data.tax_rate ~= nil then update.tax_rate = to_number(data.tax_rate) or 0 end
    if data.is_active ~= nil then update.is_active = to_bool(data.is_active, true) end
    if type(data.metadata) == "table" then update.metadata = cjson.encode(data.metadata) end
    if next(update) == nil then return nil, "No valid fields to update" end

    FsPartModel:find(id):update(update)
    return PartQueries.getPart(namespace_id, uuid)
end

function PartQueries.deletePart(namespace_id, uuid)
    local id = Common.resolve_id("fs_parts", namespace_id, uuid)
    if not id then return nil, "Part not found" end
    -- Job items keep their copied description / price; they just lose the catalog link.
    db.query("UPDATE fs_parts SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", id)
    return true
end

return PartQueries
