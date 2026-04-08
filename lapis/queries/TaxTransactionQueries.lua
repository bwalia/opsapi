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

--- Extract the AI reasoning from the llm_response JSON field.
-- Falls back to constructing a basic reasoning from available data if the
-- LLM response doesn't contain a reasoning field (older classifications).
-- @param transaction table The transaction row
-- @return string The reasoning text
local function extractReasoning(transaction)
    -- Try to extract from llm_response JSON
    if transaction.llm_response and transaction.llm_response ~= "" then
        local ok, parsed = pcall(cjson.decode, transaction.llm_response)
        if ok and type(parsed) == "table" and parsed.reasoning and parsed.reasoning ~= "" then
            return tostring(parsed.reasoning)
        end
    end

    -- Construct a basic reasoning from available data
    local parts = {}
    if transaction.description and transaction.description ~= "" then
        parts[#parts + 1] = 'Transaction "' .. transaction.description .. '"'
    end
    if transaction.category and transaction.category ~= "" then
        parts[#parts + 1] = "classified as " .. transaction.category
    end
    if transaction.classified_by and transaction.classified_by ~= "" then
        parts[#parts + 1] = "by " .. transaction.classified_by
    end
    if transaction.confidence_score then
        parts[#parts + 1] = "with confidence " .. tostring(transaction.confidence_score)
    end
    if #parts > 0 then
        return table.concat(parts, " ")
    end
    return ""
end

--- Resolve the namespace ID for a transaction.
-- Falls back to the project namespace if the transaction's namespace is 0.
-- @param transaction table The transaction row
-- @return number The namespace ID
local function resolveNamespaceId(transaction)
    -- Use the transaction's namespace if it's set
    if transaction.namespace_id and transaction.namespace_id > 0 then
        return transaction.namespace_id
    end

    -- Fall back to the project namespace via the statement
    if transaction.statement_id then
        local stmt = db.query(
            "SELECT namespace_id FROM tax_statements WHERE id = ? AND namespace_id > 0 LIMIT 1",
            transaction.statement_id
        )
        if stmt and #stmt > 0 and stmt[1].namespace_id and stmt[1].namespace_id > 0 then
            return stmt[1].namespace_id
        end
    end

    -- Fall back to the user's default namespace
    if transaction.user_id then
        local ns = db.query(
            "SELECT default_namespace_id FROM user_namespace_settings WHERE user_id = ? AND default_namespace_id > 1 LIMIT 1",
            transaction.user_id
        )
        if ns and #ns > 0 and ns[1].default_namespace_id then
            return ns[1].default_namespace_id
        end
    end

    return 0
end

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
            t.confirmation_status,
            t.confirmed_at,
            t.classification_status,
            t.classification_confirmed_at,
            t.is_manually_reviewed,
            t.user_notes,
            t.created_at,
            t.updated_at,
            CASE WHEN ctd.id IS NOT NULL THEN true ELSE false END AS in_training
        FROM tax_transactions t
        JOIN tax_statements s ON t.statement_id = s.id
        LEFT JOIN classification_training_data ctd ON ctd.transaction_uuid = t.uuid
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
                t.updated_at,
                CASE WHEN ctd.id IS NOT NULL THEN true ELSE false END AS in_training
            FROM tax_transactions t
            JOIN tax_statements s ON t.statement_id = s.id
            LEFT JOIN classification_training_data ctd ON ctd.transaction_uuid = t.uuid
            WHERE t.uuid = ?
            LIMIT 1
        ]], uuid)
    else
        -- Regular users can only view their own transactions
        result = db.query([[
            SELECT
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
                t.updated_at,
                CASE WHEN ctd.id IS NOT NULL THEN true ELSE false END AS in_training
            FROM tax_transactions t
            JOIN tax_statements s ON t.statement_id = s.id
            LEFT JOIN classification_training_data ctd ON ctd.transaction_uuid = t.uuid
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
        "user_notes", "is_manually_reviewed", "confidence_score",
        "classification_status",
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

    -- Capture the old category BEFORE the update for correction detection
    local old_category = transaction.category

    transaction:update(update_data)

    -- ── Training data: capture expert-reviewed classifications ──
    -- Two cases that produce training data:
    -- 1. Admin/accountant CHANGES the category → source = "accountant_correction"
    -- 2. Admin/accountant CONFIRMS the AI's category → source = "ai_classification" (expert-validated)
    -- In both cases the embedding is left NULL; the FastAPI processor fills it later.
    local has_category = params.category and params.category ~= ""
    local is_confirmed = params.classification_status == "CONFIRMED"
    local category_changed = has_category and old_category and params.category ~= old_category

    if isAdminOrAccountant(user) and (category_changed or (is_confirmed and has_category)) then
        pcall(function()
            local source = category_changed and "accountant_correction" or "ai_classification"
            local final_category = params.category or old_category or ""
            local final_confidence = category_changed and 1.0 or (transaction.confidence_score or 0.85)

            -- Upsert: if training data already exists for this transaction, update it
            local existing = db.query(
                "SELECT id FROM classification_training_data WHERE transaction_uuid = ? LIMIT 1",
                uuid
            )
            local ai_reasoning = extractReasoning(transaction)
            local update_reasoning = params.change_reason or (ai_reasoning ~= "" and ai_reasoning or nil)
            local ns_id = resolveNamespaceId(transaction)

            if existing and #existing > 0 then
                db.query([[
                    UPDATE classification_training_data
                    SET source = ?,
                        original_category = ?,
                        corrected_by = ?,
                        category = ?,
                        hmrc_category = COALESCE(?, hmrc_category),
                        is_tax_deductible = COALESCE(?, is_tax_deductible),
                        confidence = ?,
                        reasoning = ?,
                        namespace_id = ?,
                        embedding = NULL,
                        minio_path = NULL,
                        updated_at = NOW()
                    WHERE transaction_uuid = ?
                ]],
                    source,
                    old_category or db.NULL,
                    user_id,
                    final_category,
                    params.hmrc_category or db.NULL,
                    params.is_tax_deductible == nil and db.NULL or params.is_tax_deductible,
                    final_confidence,
                    update_reasoning or db.NULL,
                    ns_id,
                    uuid
                )
            else
                local final_reasoning = params.change_reason or (ai_reasoning ~= "" and ai_reasoning or nil)

                db.query([[
                    INSERT INTO classification_training_data
                        (uuid, transaction_uuid, user_id, source, original_category, corrected_by,
                         description, amount, transaction_type, transaction_date,
                         category, hmrc_category, confidence, is_tax_deductible,
                         reasoning, classified_by, namespace_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, ?, ?, NOW(), NOW())
                ]],
                    Global.generateUUID(),
                    uuid,
                    transaction.user_id,
                    source,
                    old_category or db.NULL,
                    user_id,
                    transaction.description,
                    transaction.amount,
                    transaction.transaction_type or "DEBIT",
                    transaction.transaction_date or db.NULL,
                    final_category,
                    params.hmrc_category or transaction.hmrc_category or "",
                    final_confidence,
                    params.is_tax_deductible == nil and (transaction.is_tax_deductible or false) or params.is_tax_deductible,
                    final_reasoning or db.NULL,
                    transaction.classified_by or db.NULL,
                    ns_id
                )
            end
            ngx.log(ngx.NOTICE, "[TRAINING] Captured ", source, ": ",
                uuid, " ", tostring(old_category), " -> ", final_category)
        end)
    end

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

    local statement
    if isAdminOrAccountant(user) then
        statement = TaxStatements:find({ uuid = statement_uuid })
    else
        statement = TaxStatements:find({ uuid = statement_uuid, user_id = user_id })
    end

    if not statement then
        return nil, "Statement not found"
    end

    local confirmed_count = 0
    for _, txn_uuid in ipairs(transaction_ids) do
        local transaction = TaxTransactions:find({
            uuid = txn_uuid,
            statement_id = statement.id,
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

    -- Admins can confirm any user's transactions; regular users can only confirm their own
    local statement
    if isAdminOrAccountant(user) then
        statement = TaxStatements:find({ uuid = statement_uuid })
    else
        statement = TaxStatements:find({ uuid = statement_uuid, user_id = user_id })
    end

    if not statement then
        return nil, "Statement not found"
    end

    local confirmed_count = 0
    for _, txn_uuid in ipairs(transaction_ids) do
        local transaction = TaxTransactions:find({
            uuid = txn_uuid,
            statement_id = statement.id,
        })

        if transaction then
            transaction:update({
                classification_status = params.classification_status or "CONFIRMED",
                classification_confirmed_at = db.raw("NOW()"),
                classification_confirmed_by = user_id,
                updated_at = db.raw("NOW()")
            })
            confirmed_count = confirmed_count + 1

            -- Capture as expert-validated training data
            if transaction.category and transaction.category ~= "" then
                pcall(function()
                    local existing = db.query(
                        "SELECT id FROM classification_training_data WHERE transaction_uuid = ? LIMIT 1",
                        txn_uuid
                    )
                    if not existing or #existing == 0 then
                        db.query([[
                            INSERT INTO classification_training_data
                                (uuid, transaction_uuid, user_id, source, original_category, corrected_by,
                                 description, amount, transaction_type, transaction_date,
                                 category, hmrc_category, confidence, is_tax_deductible,
                                 reasoning, classified_by, namespace_id, created_at, updated_at)
                            VALUES (?, ?, ?, 'ai_classification', ?, ?,
                                    ?, ?, ?, ?,
                                    ?, ?, ?, ?,
                                    ?, ?, 0, NOW(), NOW())
                        ]],
                            Global.generateUUID(),
                            txn_uuid,
                            transaction.user_id,
                            transaction.category,
                            user_id,
                            transaction.description,
                            transaction.amount,
                            transaction.transaction_type or "DEBIT",
                            transaction.transaction_date or db.NULL,
                            transaction.category,
                            transaction.hmrc_category or "",
                            transaction.confidence_score or 0.85,
                            transaction.is_tax_deductible or false,
                            params.change_reason or db.NULL,
                            transaction.classified_by or db.NULL
                        )
                    end
                end)
            end
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

-- Send selected transactions to the training data table.
-- Admin selects transactions on the classify page and clicks "Send to AI Training".
-- This inserts them into classification_training_data (with embedding=NULL)
-- so the FastAPI processor can generate embeddings and MD files later.
function TaxTransactionQueries.sendToTraining(transaction_uuids, user)
    local user_id = getUserId(user)
    if not user_id then
        return nil, "User not found"
    end

    if not isAdminOrAccountant(user) then
        return nil, "Admin or accountant access required"
    end

    if not transaction_uuids or #transaction_uuids == 0 then
        return nil, "No transactions selected"
    end

    local inserted = 0
    local skipped = 0

    for _, txn_uuid in ipairs(transaction_uuids) do
        -- Find the transaction (admin can access any)
        local rows = db.select("* FROM tax_transactions WHERE uuid = ? LIMIT 1", tostring(txn_uuid))
        local transaction = rows and rows[1]
        if transaction and transaction.category and transaction.category ~= "" then
            -- Skip if already in training data
            local t_uuid = tostring(txn_uuid)
            local existing = db.query(
                "SELECT id FROM classification_training_data WHERE transaction_uuid = ? LIMIT 1",
                t_uuid
            )
            if existing and #existing > 0 then
                skipped = skipped + 1
            else
                local reasoning = extractReasoning(transaction)
                local ns_id = resolveNamespaceId(transaction)
                local source = transaction.is_manually_reviewed and "accountant_correction" or "ai_classification"

                local ok, err = pcall(function()
                    db.query([[
                        INSERT INTO classification_training_data
                            (uuid, transaction_uuid, user_id, source, original_category, corrected_by,
                             description, amount, transaction_type, transaction_date,
                             category, hmrc_category, confidence, is_tax_deductible,
                             reasoning, classified_by, namespace_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?,
                                ?, ?, ?, ?,
                                ?, ?, ?, ?,
                                ?, ?, ?, NOW(), NOW())
                    ]],
                        Global.generateUUID(),
                        t_uuid,
                        transaction.user_id,
                        source,
                        source == "accountant_correction" and db.NULL or transaction.category,
                        user_id,
                        transaction.description,
                        transaction.amount,
                        transaction.transaction_type or "DEBIT",
                        transaction.transaction_date or db.NULL,
                        transaction.category,
                        transaction.hmrc_category or "",
                        transaction.confidence_score or 0.85,
                        transaction.is_tax_deductible or false,
                        reasoning ~= "" and reasoning or db.NULL,
                        transaction.classified_by or db.NULL,
                        ns_id
                    )
                end)
                if ok then
                    inserted = inserted + 1
                else
                    ngx.log(ngx.ERR, "[TRAINING] Failed to insert txn ", txn_uuid, ": ", tostring(err))
                end
            end
        end
    end

    ngx.log(ngx.NOTICE, "[TRAINING] Sent to training: ", inserted, " inserted, ", skipped, " skipped (already exist)")
    return { inserted = inserted, skipped = skipped, total = #transaction_uuids }
end

return TaxTransactionQueries
