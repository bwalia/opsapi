local Global = require "helper.global"
local BankTransactions = require "models.BankTransactionModel"
local db = require("lapis.db")

local BankTransactionQueries = {}

function BankTransactionQueries.create(data, user_id)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    data.user_id = user_id

    local transaction = BankTransactions:create(data, {
        returning = "*"
    })
    transaction.internal_id = transaction.id
    transaction.id = transaction.uuid
    return { data = transaction }
end

function BankTransactionQueries.all(params, user_id)
    local page = params.page or 1
    local perPage = params.perPage or 10

    local valid_fields = { id = true, transaction_date = true, balance = true, money_in = true, money_out = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "transaction_date", "desc")

    local paginated = BankTransactions:paginated(
        "WHERE user_id = ? ORDER BY " .. orderField .. " " .. orderDir,
        user_id,
        {
            per_page = perPage,
            fields = 'id as internal_id, uuid as id, user_id, transaction_date, description, money_in, money_out, balance, document_uuid'
        }
    )
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function BankTransactionQueries.show(uuid, user_id)
    local transaction = BankTransactions:find({
        uuid = uuid,
        user_id = user_id
    })
    if transaction then
        transaction.internal_id = transaction.id
        transaction.id = transaction.uuid
        return transaction
    end
    return nil
end

function BankTransactionQueries.update(uuid, params, user_id)
    local transaction = BankTransactions:find({
        uuid = uuid,
        user_id = user_id
    })
    if not transaction then
        return nil
    end
    params.id = transaction.id
    params.uuid = nil
    params.user_id = nil
    return transaction:update(params, {
        returning = "*"
    })
end

function BankTransactionQueries.destroy(uuid, user_id)
    local transaction = BankTransactions:find({
        uuid = uuid,
        user_id = user_id
    })
    if not transaction then
        return false
    end
    return transaction:delete()
end

-- Get all transactions with document details
function BankTransactionQueries.allWithDocuments(params, user_id)
    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 10
    local offset = (page - 1) * perPage

    local valid_fields = { transaction_date = true, balance = true, money_in = true, money_out = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "transaction_date", "desc")

    -- Get transactions with document details via LEFT JOIN
    local transactions = db.query([[
        SELECT
            bt.id as internal_id,
            bt.uuid as id,
            bt.user_id,
            bt.transaction_date,
            bt.description,
            bt.money_in,
            bt.money_out,
            bt.balance,
            bt.document_uuid,
            CASE WHEN d.uuid IS NOT NULL THEN
                json_build_object(
                    'uuid', d.uuid,
                    'title', d.title,
                    'excerpt', d.excerpt,
                    'status', d.status,
                    'created_at', d.created_at,
                    'cover_image', (
                        SELECT json_build_object('url', i.url, 'alt_text', i.alt_text)
                        FROM images i
                        WHERE i.document_id = d.id AND i.is_cover = true
                        LIMIT 1
                    )
                )
            ELSE NULL END as document
        FROM bank_transactions bt
        LEFT JOIN documents d ON bt.document_uuid = d.uuid
        WHERE bt.user_id = ?
        ORDER BY bt.]] .. orderField .. " " .. orderDir .. [[
        LIMIT ? OFFSET ?
    ]], user_id, perPage, offset)

    -- Get total count
    local count_result = db.query([[
        SELECT COUNT(*) as total FROM bank_transactions WHERE user_id = ?
    ]], user_id)
    local total = count_result[1] and count_result[1].total or 0

    return {
        data = transactions,
        total = total,
        page = page,
        per_page = perPage
    }
end

-- Get single transaction with document details
function BankTransactionQueries.showWithDocument(uuid, user_id)
    local results = db.query([[
        SELECT
            bt.id as internal_id,
            bt.uuid as id,
            bt.user_id,
            bt.transaction_date,
            bt.description,
            bt.money_in,
            bt.money_out,
            bt.balance,
            bt.document_uuid,
            CASE WHEN d.uuid IS NOT NULL THEN
                json_build_object(
                    'uuid', d.uuid,
                    'title', d.title,
                    'excerpt', d.excerpt,
                    'slug', d.slug,
                    'status', d.status,
                    'content', d.content,
                    'created_at', d.created_at,
                    'updated_at', d.updated_at,
                    'cover_image', (
                        SELECT json_build_object('url', i.url, 'alt_text', i.alt_text)
                        FROM images i
                        WHERE i.document_id = d.id AND i.is_cover = true
                        LIMIT 1
                    )
                )
            ELSE NULL END as document
        FROM bank_transactions bt
        LEFT JOIN documents d ON bt.document_uuid = d.uuid
        WHERE bt.uuid = ? AND bt.user_id = ?
        LIMIT 1
    ]], uuid, user_id)

    return results[1]
end

return BankTransactionQueries
