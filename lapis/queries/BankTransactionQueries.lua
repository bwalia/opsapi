local Global = require "helper.global"
local BankTransactions = require "models.BankTransactionModel"

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
            fields = 'id as internal_id, uuid as id, user_id, transaction_date, description, money_in, money_out, balance'
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

return BankTransactionQueries
