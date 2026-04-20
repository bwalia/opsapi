-- Tax Filing Queries
-- CRUD for tax_returns table (filing records and duplicate detection).

local db = require("lapis.db")
local Global = require("helper.global")

local TaxFilingQueries = {}

function TaxFilingQueries.create(data)
    data.uuid = data.uuid or Global.generateStaticUUID()
    data.created_at = db.raw("NOW()")
    data.updated_at = db.raw("NOW()")
    return db.insert("tax_returns", data)
end

function TaxFilingQueries.getByStatementId(statement_id)
    return db.select(
        "* FROM tax_returns WHERE statement_id = ? ORDER BY created_at DESC LIMIT 1",
        statement_id
    )
end

function TaxFilingQueries.getByUserAndYear(user_id, tax_year)
    return db.select(
        "* FROM tax_returns WHERE user_id = ? AND tax_year = ? ORDER BY created_at DESC",
        user_id, tax_year
    )
end

function TaxFilingQueries.checkDuplicate(user_id, tax_year)
    local rows = db.select(
        "* FROM tax_returns WHERE user_id = ? AND tax_year = ? AND status = 'FILED' LIMIT 1",
        user_id, tax_year
    )
    return rows and #rows > 0
end

function TaxFilingQueries.updateStatus(id, status, hmrc_response)
    local updates = {
        status = status,
        updated_at = db.raw("NOW()"),
    }
    if hmrc_response then
        updates.hmrc_response = type(hmrc_response) == "string" and hmrc_response or require("cjson").encode(hmrc_response)
    end
    if status == "FILED" then
        updates.filed_at = db.raw("NOW()")
    end
    db.update("tax_returns", updates, { id = id })
end

function TaxFilingQueries.getAll(user_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 25
    local offset = (page - 1) * per_page

    local rows = db.select(
        "* FROM tax_returns WHERE user_id = ? ORDER BY created_at DESC LIMIT ? OFFSET ?",
        user_id, per_page, offset
    )

    local count = db.select("COUNT(*) as total FROM tax_returns WHERE user_id = ?", user_id)
    local total = count and count[1] and count[1].total or 0

    return rows, total
end

return TaxFilingQueries
