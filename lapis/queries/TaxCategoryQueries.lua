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
    -- Bound values only (a "?" typed into search can't shift the placeholders).
    local where_clauses, values = { "1=1" }, {}

    if params.type then
        table.insert(where_clauses, "type = ?")
        table.insert(values, tostring(params.type))
    end
    if params.is_active ~= nil then
        table.insert(where_clauses, "is_active = ?")
        table.insert(values, params.is_active == true or params.is_active == "true")
    end
    if params.search and #tostring(params.search) > 0 then
        local like = "%" .. tostring(params.search):gsub("[%%_\\]", "\\%0") .. "%"
        table.insert(where_clauses, "(label ILIKE ? OR key ILIKE ? OR description ILIKE ?)")
        table.insert(values, like)
        table.insert(values, like)
        table.insert(values, like)
    end

    local where = table.concat(where_clauses, " AND ")
    local page = Global.pageParam(params.page)
    local per_page = Global.perPageParam(params.per_page, 100, 500)
    local offset = (page - 1) * per_page

    local page_values = { unpack(values) }
    page_values[#page_values + 1] = per_page
    page_values[#page_values + 1] = offset
    local rows = db.select("* FROM tax_categories WHERE " .. where .. " ORDER BY type, label LIMIT ? OFFSET ?",
        unpack(page_values))
    local count = db.select("COUNT(*) as total FROM tax_categories WHERE " .. where, unpack(values))
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
    return db.select("* FROM tax_hmrc_categories ORDER BY box, key")
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
