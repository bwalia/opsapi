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

    -- Resolve namespace_id: inherit from bank account, or from user's default namespace
    local namespace_id = data.namespace_id
    if not namespace_id or namespace_id == 0 then
        namespace_id = bank_account.namespace_id
    end
    if not namespace_id or namespace_id == 0 then
        local ns = db.query("SELECT default_namespace_id FROM user_namespace_settings WHERE user_id = ? LIMIT 1", user_id)
        if ns and #ns > 0 and ns[1].default_namespace_id then
            namespace_id = ns[1].default_namespace_id
        end
    end

    local statement = TaxStatements:create({
        uuid = data.uuid,
        bank_account_id = bank_account.id,
        user_id = user_id,
        namespace_id = namespace_id or 0,
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

    -- Return with uuid as id (never expose numeric PKs)
    statement.id = statement.uuid
    statement.bank_account_uuid = bank_account.uuid
    statement.user_id = nil
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

    -- Namespace isolation: filter by user's default namespace if available
    local ns_rows = db.query("SELECT default_namespace_id FROM user_namespace_settings WHERE user_id = ? LIMIT 1", user_id)
    if ns_rows and #ns_rows > 0 and ns_rows[1].default_namespace_id and tonumber(ns_rows[1].default_namespace_id) > 0 then
        table.insert(where_parts, "s.namespace_id = ?")
        table.insert(where_values, tonumber(ns_rows[1].default_namespace_id))
    end

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

    if params.tax_year then
        table.insert(where_parts, "s.tax_year = ?")
        table.insert(where_values, params.tax_year)
    end

    if params.search and params.search ~= "" then
        table.insert(where_parts, "(s.file_name ILIKE ? OR ba.bank_name ILIKE ? OR ba.account_name ILIKE ? OR s.uuid::text ILIKE ?)")
        local pattern = "%" .. params.search .. "%"
        table.insert(where_values, pattern)
        table.insert(where_values, pattern)
        table.insert(where_values, pattern)
        table.insert(where_values, pattern)
    end

    local where_clause = table.concat(where_parts, " AND ")

    -- Historically statements only existed as tax_statements rows,
    -- created by the /api/v2/tax/upload path used by /upload and
    -- /bank-accounts. The DMS (dms_documents) is a second store the
    -- newer income-page upload flow writes to: uploading a bank
    -- statement from /my-income/self_employment/business/[id] (or
    -- rental/property/[id], or salary/employment/[id]) lands the file
    -- in dms_documents with doc_type_key='bank_statement' AND
    -- bank_account_uuid set — but never in tax_statements. So
    -- /bank-accounts previously showed 0 statements for accounts
    -- whose files were uploaded via that newer path.
    --
    -- This query UNIONs both tables so /bank-accounts sees every
    -- statement regardless of upload path. The two rows shape into
    -- the same columns; dms_document rows carry the income-type +
    -- linked-entity linkage (via the LEFT JOIN to
    -- user_profile_entities for a display label) so the UI can
    -- surface "Linked to Self-employment · Acme Ltd" chips.
    --
    -- Filters unique to tax_statements (processing_status,
    -- workflow_step) simply produce no dms rows when set to
    -- anything other than 'UPLOADED' — dms bank statements are
    -- always raw uploads until the classify/extract pipeline lifts
    -- one into tax_statements. Same for tax_year (dms doesn't have
    -- one) — a tax_year filter excludes dms rows entirely.

    -- Build the dms_documents branch's WHERE parts. It shares user_id
    -- and the two bank/search filters with the primary branch, but
    -- has to re-alias `s.` → `d.` and `ba.` stays `ba.`.
    local dms_include = true
    local dms_where_parts = { "d.user_id = ?", "d.doc_type_key = 'bank_statement'", "d.bank_account_uuid IS NOT NULL" }
    local dms_where_values = { user_id }
    if ns_rows and #ns_rows > 0 and ns_rows[1].default_namespace_id and tonumber(ns_rows[1].default_namespace_id) > 0 then
        table.insert(dms_where_parts, "d.namespace_id = ?")
        table.insert(dms_where_values, tonumber(ns_rows[1].default_namespace_id))
    end
    if params.bank_account_id then
        table.insert(dms_where_parts, "ba.uuid = ?")
        table.insert(dms_where_values, params.bank_account_id)
    end
    -- Any processing_status filter other than 'UPLOADED' excludes dms
    -- rows — they don't have workflow state. Same for workflow_step
    -- and tax_year (columns absent on dms_documents).
    if params.processing_status and params.processing_status ~= "UPLOADED" then
        dms_include = false
    end
    if params.workflow_step and params.workflow_step ~= "UPLOADED" then
        dms_include = false
    end
    if params.tax_year then
        dms_include = false
    end
    if params.search and params.search ~= "" then
        table.insert(dms_where_parts, "(d.file_name ILIKE ? OR ba.bank_name ILIKE ? OR ba.account_name ILIKE ? OR d.uuid ILIKE ?)")
        local pattern = "%" .. params.search .. "%"
        table.insert(dms_where_values, pattern)
        table.insert(dms_where_values, pattern)
        table.insert(dms_where_values, pattern)
        table.insert(dms_where_values, pattern)
    end
    local dms_where_clause = table.concat(dms_where_parts, " AND ")

    -- The two SELECTs share every column position + type; unshared
    -- fields are NULL::<type> on the side that doesn't have them.
    -- Column count: 30 including the four new linkage columns and
    -- the discriminator `source` at the end.
    local ts_select = [[
        SELECT
            s.uuid as id,
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
            (SELECT COUNT(*) FROM tax_transactions WHERE statement_id = s.id AND classification_status = 'CONFIRMED') as classified_count,
            NULL::varchar as income_type_key,
            NULL::varchar as linked_entity_type,
            NULL::text    as linked_entity_uuid,
            NULL::varchar as linked_entity_label,
            'tax_statement' as source
        FROM tax_statements s
        JOIN tax_bank_accounts ba ON s.bank_account_id = ba.id
        WHERE ]] .. where_clause

    local dms_select = [[
        SELECT
            d.uuid as id,
            ba.uuid as bank_account_id,
            ba.bank_name,
            ba.account_name,
            d.file_name,
            d.file_type,
            d.file_size_bytes,
            NULL::date    as statement_date,
            NULL::date    as period_start,
            NULL::date    as period_end,
            NULL::numeric as opening_balance,
            NULL::numeric as closing_balance,
            'UPLOADED'::varchar as processing_status,
            'UPLOADED'::varchar as workflow_step,
            NULL::varchar as tax_year,
            NULL::numeric as total_income,
            NULL::numeric as total_expenses,
            NULL::numeric as tax_due,
            false         as is_filed,
            NULL::timestamp as filed_at,
            NULL::varchar as hmrc_submission_id,
            d.uploaded_at,
            NULL::timestamp as processed_at,
            d.updated_at,
            0 as transaction_count,
            0 as confirmed_count,
            0 as classified_count,
            d.income_type_key,
            d.linked_entity_type,
            d.linked_entity_uuid,
            upe.label as linked_entity_label,
            'dms_document' as source
        FROM dms_documents d
        JOIN tax_bank_accounts ba ON ba.uuid = d.bank_account_uuid
        LEFT JOIN user_profile_entities upe ON upe.uuid = d.linked_entity_uuid
        WHERE ]] .. dms_where_clause

    local query, all_values
    if dms_include then
        query = "(" .. ts_select .. ") UNION ALL (" .. dms_select ..
                ") ORDER BY uploaded_at DESC LIMIT ? OFFSET ?"
        all_values = {}
        for _, v in ipairs(where_values) do table.insert(all_values, v) end
        for _, v in ipairs(dms_where_values) do table.insert(all_values, v) end
        table.insert(all_values, perPage)
        table.insert(all_values, offset)
    else
        -- Filter chose an option dms rows can't satisfy — fall back to
        -- the original single-source query so we don't pay the union cost.
        query = ts_select .. " ORDER BY s.uploaded_at DESC LIMIT ? OFFSET ?"
        all_values = {}
        for _, v in ipairs(where_values) do table.insert(all_values, v) end
        table.insert(all_values, perPage)
        table.insert(all_values, offset)
    end

    local statements = db.query(query, table.unpack(all_values))

    -- Total counts — count each source, sum. Same filter shape as the
    -- SELECTs above; do NOT include the LIMIT/OFFSET tail.
    local ts_count = db.query(
        "SELECT COUNT(*) as n FROM tax_statements s JOIN tax_bank_accounts ba ON s.bank_account_id = ba.id WHERE " .. where_clause,
        table.unpack(where_values))
    local total = (ts_count and ts_count[1] and tonumber(ts_count[1].n)) or 0
    if dms_include then
        local dms_count = db.query(
            "SELECT COUNT(*) as n FROM dms_documents d JOIN tax_bank_accounts ba ON ba.uuid = d.bank_account_uuid WHERE " .. dms_where_clause,
            table.unpack(dms_where_values))
        total = total + ((dms_count and dms_count[1] and tonumber(dms_count[1].n)) or 0)
    end
    local count_result = { { total = total } }

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
            s.uuid as id,
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
