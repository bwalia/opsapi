-- Tax Category Queries
-- Admin CRUD for tax_categories and tax_hmrc_categories tables.

local db = require("lapis.db")
local Global = require("helper.global")

local TaxCategoryQueries = {}

-- ---------------------------------------------------------------------------
-- Transaction Categories
-- ---------------------------------------------------------------------------

function TaxCategoryQueries.getAll(params)
    params = params or {}
    local where_clauses = { "1=1" }

    if params.type then
        table.insert(where_clauses, "type = " .. db.escape_literal(params.type))
    end
    if params.is_active ~= nil then
        table.insert(where_clauses, "is_active = " .. db.escape_literal(params.is_active))
    end
    if params.search and #params.search > 0 then
        local search = db.escape_literal("%" .. params.search .. "%")
        table.insert(where_clauses, "(name ILIKE " .. search .. " OR description ILIKE " .. search .. ")")
    end

    local where = table.concat(where_clauses, " AND ")
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 100
    local offset = (page - 1) * per_page

    local rows = db.select("* FROM tax_categories WHERE " .. where .. " ORDER BY type, name LIMIT ? OFFSET ?",
        per_page, offset)
    local count = db.select("COUNT(*) as total FROM tax_categories WHERE " .. where)
    return rows, count and count[1] and count[1].total or 0
end

function TaxCategoryQueries.getById(id)
    local rows = db.select("* FROM tax_categories WHERE id = ? LIMIT 1", id)
    return rows and rows[1]
end

function TaxCategoryQueries.getByUuid(uuid)
    local rows = db.select("* FROM tax_categories WHERE uuid = ? LIMIT 1", uuid)
    return rows and rows[1]
end

function TaxCategoryQueries.create(data)
    data.uuid = data.uuid or Global.generateStaticUUID()
    data.created_at = db.raw("NOW()")
    data.updated_at = db.raw("NOW()")
    return db.insert("tax_categories", data)
end

function TaxCategoryQueries.update(uuid, data)
    data.updated_at = db.raw("NOW()")
    db.update("tax_categories", data, { uuid = uuid })
    return TaxCategoryQueries.getByUuid(uuid)
end

function TaxCategoryQueries.delete(uuid)
    db.update("tax_categories", { is_active = false, updated_at = db.raw("NOW()") }, { uuid = uuid })
end

-- ---------------------------------------------------------------------------
-- HMRC Categories
-- ---------------------------------------------------------------------------

function TaxCategoryQueries.getHmrcCategories()
    return db.select("* FROM tax_hmrc_categories ORDER BY box_number, key")
end

function TaxCategoryQueries.getHmrcByUuid(uuid)
    local rows = db.select("* FROM tax_hmrc_categories WHERE uuid = ? LIMIT 1", uuid)
    return rows and rows[1]
end

function TaxCategoryQueries.createHmrc(data)
    data.uuid = data.uuid or Global.generateStaticUUID()
    data.created_at = db.raw("NOW()")
    data.updated_at = db.raw("NOW()")
    return db.insert("tax_hmrc_categories", data)
end

function TaxCategoryQueries.updateHmrc(uuid, data)
    data.updated_at = db.raw("NOW()")
    db.update("tax_hmrc_categories", data, { uuid = uuid })
    return TaxCategoryQueries.getHmrcByUuid(uuid)
end

function TaxCategoryQueries.deleteHmrc(uuid)
    db.update("tax_hmrc_categories", { is_active = false, updated_at = db.raw("NOW()") }, { uuid = uuid })
end

return TaxCategoryQueries
