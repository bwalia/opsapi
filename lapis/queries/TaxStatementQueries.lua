--[[
    Tax Statement Queries

    CRUD operations for tax_statements table.
    Statements are linked to bank accounts and users.
]]

local Global = require "helper.global"
local TaxStatements = require "models.TaxStatementModel"
local TaxBankAccounts = require "models.TaxBankAccountModel"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local TaxStatementQueries = {}

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

-- Create a new statement
function TaxStatementQueries.create(data, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil, "User not found"
    end

    -- Verify bank account exists and belongs to user
    local bank_account = TaxBankAccounts:find({
        uuid = data.bank_account_uuid or data.bank_account_id,
        user_id = user_id
    })

    if not bank_account then
        -- Try finding by internal ID
        bank_account = TaxBankAccounts:find({
            id = tonumber(data.bank_account_id),
            user_id = user_id
        })
    end

    if not bank_account then
        return nil, "Bank account not found"
    end

    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end

    local statement = TaxStatements:create({
        uuid = data.uuid,
        bank_account_id = bank_account.id,
        user_id = user_id,
        namespace_id = data.namespace_id,
        minio_bucket = data.minio_bucket,
        minio_object_key = data.minio_object_key,
        file_name = data.file_name,
        file_size_bytes = data.file_size_bytes,
        file_type = data.file_type,
        statement_date = data.statement_date,
        period_start = data.period_start,
        period_end = data.period_end,
        opening_balance = data.opening_balance,
        closing_balance = data.closing_balance,
        processing_status = data.processing_status or "UPLOADED",
        workflow_step = data.workflow_step or "UPLOADED",
        tax_year = data.tax_year
    }, { returning = "*" })

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "STATEMENT",
        entity_id = statement.uuid,
        action = "CREATE",
        new_values = cjson.encode({
            file_name = statement.file_name,
            bank_account_id = bank_account.uuid
        })
    })

    -- Return with uuid as id
    statement.internal_id = statement.id
    statement.id = statement.uuid
    statement.bank_account_uuid = bank_account.uuid
    return { data = statement }
end

-- List statements for user
function TaxStatementQueries.all(params, user)
    local user_id = getUserId(user)
    if not user_id then
        return { data = {}, total = 0 }
    end

    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 20
    local offset = (page - 1) * perPage

    -- Build WHERE clause
    local where_parts = { "s.user_id = ?" }
    local where_values = { user_id }

    if params.bank_account_id then
        table.insert(where_parts, "ba.uuid = ?")
        table.insert(where_values, params.bank_account_id)
    end

    if params.processing_status then
        table.insert(where_parts, "s.processing_status = ?")
        table.insert(where_values, params.processing_status)
    end

    if params.workflow_step then
        table.insert(where_parts, "s.workflow_step = ?")
        table.insert(where_values, params.workflow_step)
    end

    local where_clause = table.concat(where_parts, " AND ")

    -- Get statements with bank account info
    local query = [[
        SELECT
            s.id as internal_id,
            s.uuid as id,
            s.user_id,
            ba.uuid as bank_account_id,
            ba.bank_name,
            ba.account_name,
            s.file_name,
            s.file_type,
            s.file_size_bytes,
            s.statement_date,
            s.period_start,
            s.period_end,
            s.opening_balance,
            s.closing_balance,
            s.processing_status,
            s.workflow_step,
            s.tax_year,
            s.total_income,
            s.total_expenses,
            s.tax_due,
            s.is_filed,
            s.filed_at,
            s.hmrc_submission_id,
            s.uploaded_at,
            s.processed_at,
            s.updated_at,
            (SELECT COUNT(*) FROM tax_transactions WHERE statement_id = s.id) as transaction_count,
            (SELECT COUNT(*) FROM tax_transactions WHERE statement_id = s.id AND confirmation_status = 'CONFIRMED') as confirmed_count,
            (SELECT COUNT(*) FROM tax_transactions WHERE statement_id = s.id AND classification_status = 'CONFIRMED') as classified_count
        FROM tax_statements s
        JOIN tax_bank_accounts ba ON s.bank_account_id = ba.id
        WHERE ]] .. where_clause .. [[
        ORDER BY s.uploaded_at DESC
        LIMIT ? OFFSET ?
    ]]

    table.insert(where_values, perPage)
    table.insert(where_values, offset)

    local statements = db.query(query, unpack(where_values))

    -- Get total count
    local count_query = "SELECT COUNT(*) as total FROM tax_statements s JOIN tax_bank_accounts ba ON s.bank_account_id = ba.id WHERE " .. where_clause
    local count_result = db.query(count_query, unpack(where_values, 1, #where_values - 2))

    return {
        data = statements,
        total = count_result[1] and count_result[1].total or 0,
        page = page,
        per_page = perPage
    }
end

-- Get single statement
function TaxStatementQueries.show(uuid, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil
    end

    local result = db.query([[
        SELECT
            s.id as internal_id,
            s.uuid as id,
            s.user_id,
            ba.uuid as bank_account_id,
            ba.bank_name,
            ba.account_name,
            s.minio_bucket,
            s.minio_object_key,
            s.file_name,
            s.file_type,
            s.file_size_bytes,
            s.statement_date,
            s.period_start,
            s.period_end,
            s.opening_balance,
            s.closing_balance,
            s.processing_status,
            s.validation_status,
            s.workflow_step,
            s.error_message,
            s.tax_year,
            s.total_income,
            s.total_expenses,
            s.tax_due,
            s.is_filed,
            s.filed_at,
            s.hmrc_submission_id,
            s.hmrc_response,
            s.uploaded_at,
            s.processed_at,
            s.updated_at,
            (SELECT COUNT(*) FROM tax_transactions WHERE statement_id = s.id) as transaction_count,
            (SELECT COUNT(*) FROM tax_transactions WHERE statement_id = s.id AND confirmation_status = 'CONFIRMED') as confirmed_count,
            (SELECT COUNT(*) FROM tax_transactions WHERE statement_id = s.id AND classification_status = 'CONFIRMED') as classified_count
        FROM tax_statements s
        JOIN tax_bank_accounts ba ON s.bank_account_id = ba.id
        WHERE s.uuid = ? AND s.user_id = ?
        LIMIT 1
    ]], uuid, user_id)

    return result and result[1] or nil
end

-- Update statement
function TaxStatementQueries.update(uuid, params, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil
    end

    local statement = TaxStatements:find({
        uuid = uuid,
        user_id = user_id
    })

    if not statement then
        return nil
    end

    local old_values = cjson.encode({
        processing_status = statement.processing_status,
        workflow_step = statement.workflow_step,
        total_income = statement.total_income,
        total_expenses = statement.total_expenses
    })

    -- Update allowed fields
    local update_data = {}
    local updatable_fields = {
        "statement_date", "period_start", "period_end",
        "opening_balance", "closing_balance",
        "processing_status", "validation_status", "workflow_step",
        "error_message", "tax_year",
        "total_income", "total_expenses", "tax_due",
        "is_filed", "filed_at", "hmrc_submission_id", "hmrc_response"
    }

    for _, field in ipairs(updatable_fields) do
        if params[field] ~= nil then
            update_data[field] = params[field]
        end
    end
    update_data.updated_at = db.raw("NOW()")

    if params.processing_status == "COMPLETED" and not statement.processed_at then
        update_data.processed_at = db.raw("NOW()")
    end

    statement:update(update_data)

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "STATEMENT",
        entity_id = uuid,
        action = "UPDATE",
        old_values = old_values,
        new_values = cjson.encode(update_data),
        change_reason = params.change_reason
    })

    return TaxStatementQueries.show(uuid, user)
end

-- Delete statement
function TaxStatementQueries.destroy(uuid, user)
    local user_id = getUserId(user)
    if not user_id then
        return false
    end

    local statement = TaxStatements:find({
        uuid = uuid,
        user_id = user_id
    })

    if not statement then
        return false
    end

    -- Delete associated transactions first
    db.query("DELETE FROM tax_transactions WHERE statement_id = ?", statement.id)

    -- Delete statement
    statement:delete()

    -- Audit log
    TaxAuditLogQueries.log({
        user_id = user_id,
        user_email = user.email,
        entity_type = "STATEMENT",
        entity_id = uuid,
        action = "DELETE"
    })

    return true
end

return TaxStatementQueries
