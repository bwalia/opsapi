--[[
    Tax Transaction Queries

    CRUD operations for tax_transactions table.
    Transactions belong to statements and users.
]]

local Global = require "helper.global"
local TaxTransactions = require "models.TaxTransactionModel"
local TaxStatements = require "models.TaxStatementModel"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local TaxTransactionQueries = {}

-- Roles that can access any user's transactions
local ADMIN_ROLES = {
    administrative = true,
    admin = true,
    tax_admin = true,
    tax_accountant = true,
    accountant = true,
}

-- Check if user has admin/accountant privileges
local function isAdminOrAccountant(user)
    local role = user.roles or user.role or ""
    return ADMIN_ROLES[role] == true
end

-- Helper to get user's internal ID
local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local user_record
    if user.uuid then
        user_record = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        user_record = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if user_record and #user_record > 0 then
        return user_record[1].id
    end
    return nil
end

-- Bulk create transactions (for AI extraction results)
function TaxTransactionQueries.bulkCreate(statement_uuid, transactions, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil, "User not found"
    end

    -- Get statement
    local statement = TaxStatements:find({
        uuid = statement_uuid,
        user_id = user_id
    })

    if not statement then
        return nil, "Statement not found"
    end

    local created = {}
    for _, txn in ipairs(transactions) do
        local uuid = Global.generateUUID()
        local transaction = TaxTransactions:create({
            uuid = uuid,
            statement_id = statement.id,
            bank_account_id = statement.bank_account_id,
            user_id = user_id,
            transaction_date = txn.transaction_date or txn.date,
            description = txn.description,
            amount = txn.amount,
            balance = txn.balance,
            transaction_type = txn.transaction_type or (txn.amount >= 0 and "CREDIT" or "DEBIT"),
            category = txn.category,
            hmrc_category = txn.hmrc_category,
            confidence_score = txn.confidence_score,
            classified_by = txn.classified_by,
            is_tax_deductible = txn.is_tax_deductible,
            is_vat_applicable = txn.is_vat_applicable,
            vat_rate = txn.vat_rate,
            llm_response = txn.llm_response and cjson.encode(txn.llm_response) or nil,
            confirmation_status = txn.confirmation_status or "PENDING",
            classification_status = txn.classification_status or "PENDING"
        }, { returning = "uuid" })

        table.insert(created, {
            id = transaction.uuid,
            transaction_date = txn.transaction_date or txn.date,
            description = txn.description,
            amount = txn.amount
        })
    end

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "TRANSACTION",
        entity_id = statement_uuid,
        parent_entity_type = "STATEMENT",
        parent_entity_id = statement_uuid,
        action = "BULK_CREATE",
        new_values = cjson.encode({ count = #created })
    })

    return { data = created, count = #created }
end

-- Get transactions for a statement
function TaxTransactionQueries.byStatement(statement_uuid, params, user)
    local user_id = getUserId(user)
    if not user_id then
        return { data = {}, total = 0 }
    end

    -- Get statement internal ID
    local statement = TaxStatements:find({
        uuid = statement_uuid,
        user_id = user_id
    })

    if not statement then
        return { data = {}, total = 0 }
    end

    local page = tonumber(params and params.page) or 1
    local perPage = tonumber(params and params.perPage) or 100
    local offset = (page - 1) * perPage

    local order_by = "transaction_date ASC, id ASC"
    if params and params.orderBy then
        local valid_fields = { transaction_date = true, amount = true, category = true, confirmation_status = true }
        if valid_fields[params.orderBy] then
            local dir = params.orderDir == "desc" and "DESC" or "ASC"
            order_by = params.orderBy .. " " .. dir
        end
    end

    local transactions = db.query([[
        SELECT
            t.id as internal_id,
            t.uuid as id,
            t.statement_id,
            t.transaction_date,
            t.description,
            t.amount,
            t.balance,
            t.transaction_type,
            t.category,
            t.hmrc_category,
            t.confidence_score,
            t.classified_by,
            t.is_tax_deductible,
            t.is_vat_applicable,
            t.vat_rate,
            t.confirmation_status,
            t.confirmed_at,
            t.classification_status,
            t.classification_confirmed_at,
            t.is_manually_reviewed,
            t.user_notes,
            t.created_at,
            t.updated_at
        FROM tax_transactions t
        WHERE t.statement_id = ? AND t.user_id = ?
        ORDER BY ]] .. order_by .. [[
        LIMIT ? OFFSET ?
    ]], statement.id, user_id, perPage, offset)

    local count_result = db.query("SELECT COUNT(*) as total FROM tax_transactions WHERE statement_id = ?", statement.id)

    return {
        data = transactions,
        total = count_result[1] and count_result[1].total or 0,
        page = page,
        per_page = perPage,
        statement_id = statement_uuid
    }
end

-- Get single transaction
function TaxTransactionQueries.show(uuid, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil
    end

    local result
    if isAdminOrAccountant(user) then
        -- Admin/accountant can view any transaction
        result = db.query([[
            SELECT
                t.id as internal_id,
                t.uuid as id,
                s.uuid as statement_id,
                t.transaction_date,
                t.description,
                t.amount,
                t.balance,
                t.transaction_type,
                t.category,
                t.hmrc_category,
                t.confidence_score,
                t.classified_by,
                t.is_tax_deductible,
                t.is_vat_applicable,
                t.vat_rate,
                t.llm_response,
                t.confirmation_status,
                t.confirmed_at,
                t.confirmed_by,
                t.classification_status,
                t.classification_confirmed_at,
                t.classification_confirmed_by,
                t.is_manually_reviewed,
                t.reviewed_by,
                t.reviewed_at,
                t.user_notes,
                t.created_at,
                t.updated_at
            FROM tax_transactions t
            JOIN tax_statements s ON t.statement_id = s.id
            WHERE t.uuid = ?
            LIMIT 1
        ]], uuid)
    else
        -- Regular users can only view their own transactions
        result = db.query([[
            SELECT
                t.id as internal_id,
                t.uuid as id,
                s.uuid as statement_id,
                t.transaction_date,
                t.description,
                t.amount,
                t.balance,
                t.transaction_type,
                t.category,
                t.hmrc_category,
                t.confidence_score,
                t.classified_by,
                t.is_tax_deductible,
                t.is_vat_applicable,
                t.vat_rate,
                t.llm_response,
                t.confirmation_status,
                t.confirmed_at,
                t.confirmed_by,
                t.classification_status,
                t.classification_confirmed_at,
                t.classification_confirmed_by,
                t.is_manually_reviewed,
                t.reviewed_by,
                t.reviewed_at,
                t.user_notes,
                t.created_at,
                t.updated_at
            FROM tax_transactions t
            JOIN tax_statements s ON t.statement_id = s.id
            WHERE t.uuid = ? AND t.user_id = ?
            LIMIT 1
        ]], uuid, user_id)
    end

    return result and result[1] or nil
end

-- Update transaction (for user edits)
function TaxTransactionQueries.update(uuid, params, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil
    end

    local transaction
    if isAdminOrAccountant(user) then
        transaction = TaxTransactions:find({ uuid = uuid })
    else
        transaction = TaxTransactions:find({ uuid = uuid, user_id = user_id })
    end

    if not transaction then
        return nil
    end

    -- Get statement UUID for audit
    local statement = TaxStatements:find({ id = transaction.statement_id })
    local statement_uuid = statement and statement.uuid or nil

    local old_values = cjson.encode({
        transaction_date = transaction.transaction_date,
        description = transaction.description,
        amount = transaction.amount,
        category = transaction.category,
        hmrc_category = transaction.hmrc_category,
        is_tax_deductible = transaction.is_tax_deductible
    })

    -- Update allowed fields
    local update_data = {}
    local updatable_fields = {
        "transaction_date", "description", "amount", "balance",
        "transaction_type", "category", "hmrc_category",
        "is_tax_deductible", "is_vat_applicable", "vat_rate",
        "user_notes", "is_manually_reviewed"
    }

    for _, field in ipairs(updatable_fields) do
        if params[field] ~= nil then
            update_data[field] = params[field]
        end
    end

    -- If user is editing, mark as manually reviewed
    if params.category or params.description or params.amount then
        update_data.is_manually_reviewed = true
        update_data.reviewed_by = user_id
        update_data.reviewed_at = db.raw("NOW()")
    end

    update_data.updated_at = db.raw("NOW()")

    transaction:update(update_data)

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "TRANSACTION",
        entity_id = uuid,
        parent_entity_type = "STATEMENT",
        parent_entity_id = statement_uuid,
        action = "UPDATE",
        old_values = old_values,
        new_values = cjson.encode(update_data),
        change_reason = params.change_reason
    })

    return TaxTransactionQueries.show(uuid, user)
end

-- Confirm transaction extraction
function TaxTransactionQueries.confirm(uuid, params, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil
    end

    local transaction
    if isAdminOrAccountant(user) then
        transaction = TaxTransactions:find({ uuid = uuid })
    else
        transaction = TaxTransactions:find({ uuid = uuid, user_id = user_id })
    end

    if not transaction then
        return nil
    end

    -- Get statement UUID for audit
    local statement = TaxStatements:find({ id = transaction.statement_id })
    local statement_uuid = statement and statement.uuid or nil

    local old_status = transaction.confirmation_status

    transaction:update({
        confirmation_status = params.confirmation_status or "CONFIRMED",
        confirmed_at = db.raw("NOW()"),
        confirmed_by = user_id,
        updated_at = db.raw("NOW()")
    })

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "TRANSACTION",
        entity_id = uuid,
        parent_entity_type = "STATEMENT",
        parent_entity_id = statement_uuid,
        action = "CONFIRM",
        old_values = cjson.encode({ confirmation_status = old_status }),
        new_values = cjson.encode({ confirmation_status = params.confirmation_status or "CONFIRMED" }),
        change_reason = params.change_reason
    })

    return TaxTransactionQueries.show(uuid, user)
end

-- Confirm transaction classification
function TaxTransactionQueries.confirmClassification(uuid, params, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil
    end

    local transaction
    if isAdminOrAccountant(user) then
        transaction = TaxTransactions:find({ uuid = uuid })
    else
        transaction = TaxTransactions:find({ uuid = uuid, user_id = user_id })
    end

    if not transaction then
        return nil
    end

    -- Get statement UUID for audit
    local statement = TaxStatements:find({ id = transaction.statement_id })
    local statement_uuid = statement and statement.uuid or nil

    local old_status = transaction.classification_status

    transaction:update({
        classification_status = params.classification_status or "CONFIRMED",
        classification_confirmed_at = db.raw("NOW()"),
        classification_confirmed_by = user_id,
        updated_at = db.raw("NOW()")
    })

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "TRANSACTION",
        entity_id = uuid,
        parent_entity_type = "STATEMENT",
        parent_entity_id = statement_uuid,
        action = "CONFIRM_CLASSIFICATION",
        old_values = cjson.encode({ classification_status = old_status }),
        new_values = cjson.encode({ classification_status = params.classification_status or "CONFIRMED" }),
        change_reason = params.change_reason
    })

    return TaxTransactionQueries.show(uuid, user)
end

-- Bulk confirm transactions
function TaxTransactionQueries.bulkConfirm(statement_uuid, transaction_ids, params, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil, "User not found"
    end

    local statement = TaxStatements:find({
        uuid = statement_uuid,
        user_id = user_id
    })

    if not statement then
        return nil, "Statement not found"
    end

    local confirmed_count = 0
    for _, txn_uuid in ipairs(transaction_ids) do
        local transaction = TaxTransactions:find({
            uuid = txn_uuid,
            statement_id = statement.id,
            user_id = user_id
        })

        if transaction then
            transaction:update({
                confirmation_status = params.confirmation_status or "CONFIRMED",
                confirmed_at = db.raw("NOW()"),
                confirmed_by = user_id,
                updated_at = db.raw("NOW()")
            })
            confirmed_count = confirmed_count + 1
        end
    end

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "TRANSACTION",
        entity_id = statement_uuid,
        parent_entity_type = "STATEMENT",
        parent_entity_id = statement_uuid,
        action = "BULK_CONFIRM",
        new_values = cjson.encode({
            count = confirmed_count,
            confirmation_status = params.confirmation_status or "CONFIRMED"
        }),
        change_reason = params.change_reason
    })

    return { confirmed_count = confirmed_count }
end

-- Bulk confirm classification
function TaxTransactionQueries.bulkConfirmClassification(statement_uuid, transaction_ids, params, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil, "User not found"
    end

    local statement = TaxStatements:find({
        uuid = statement_uuid,
        user_id = user_id
    })

    if not statement then
        return nil, "Statement not found"
    end

    local confirmed_count = 0
    for _, txn_uuid in ipairs(transaction_ids) do
        local transaction = TaxTransactions:find({
            uuid = txn_uuid,
            statement_id = statement.id,
            user_id = user_id
        })

        if transaction then
            transaction:update({
                classification_status = params.classification_status or "CONFIRMED",
                classification_confirmed_at = db.raw("NOW()"),
                classification_confirmed_by = user_id,
                updated_at = db.raw("NOW()")
            })
            confirmed_count = confirmed_count + 1
        end
    end

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "TRANSACTION",
        entity_id = statement_uuid,
        parent_entity_type = "STATEMENT",
        parent_entity_id = statement_uuid,
        action = "BULK_CONFIRM_CLASSIFICATION",
        new_values = cjson.encode({
            count = confirmed_count,
            classification_status = params.classification_status or "CONFIRMED"
        }),
        change_reason = params.change_reason
    })

    return { confirmed_count = confirmed_count }
end

-- Update transactions from AI classification results
function TaxTransactionQueries.bulkUpdateClassification(statement_uuid, classifications, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil, "User not found"
    end

    local statement = TaxStatements:find({
        uuid = statement_uuid,
        user_id = user_id
    })

    if not statement then
        return nil, "Statement not found"
    end

    local updated_count = 0
    for _, cls in ipairs(classifications) do
        local transaction = TaxTransactions:find({
            uuid = cls.transaction_id or cls.id,
            statement_id = statement.id
        })

        if transaction then
            transaction:update({
                category = cls.category,
                hmrc_category = cls.hmrc_category,
                confidence_score = cls.confidence_score,
                classified_by = cls.classified_by or "AI",
                is_tax_deductible = cls.is_tax_deductible,
                llm_response = cls.llm_response and cjson.encode(cls.llm_response) or nil,
                classification_status = "PENDING",  -- Needs user confirmation
                updated_at = db.raw("NOW()")
            })
            updated_count = updated_count + 1
        end
    end

    return { updated_count = updated_count }
end

return TaxTransactionQueries
