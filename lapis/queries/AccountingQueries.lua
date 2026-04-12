--[[
    Accounting Queries
    ==================

    Query helpers for the double-entry accounting system: chart of accounts,
    journal entries, bank transactions, expenses, VAT returns, reports, and
    AI-assisted categorisation.
]]

local AccountingAccountModel = require("models.AccountingAccountModel")
local AccountingJournalEntryModel = require("models.AccountingJournalEntryModel")
local AccountingBankTransactionModel = require("models.AccountingBankTransactionModel")
local AccountingExpenseModel = require("models.AccountingExpenseModel")
local AccountingVatReturnModel = require("models.AccountingVatReturnModel")
local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

local AccountingQueries = {}

--------------------------------------------------------------------------------
-- Chart of Accounts
--------------------------------------------------------------------------------

--- List accounts for a namespace with optional filtering
-- @param namespace_id number Namespace ID
-- @param params table Filter params (type, is_active, page, per_page)
-- @return table Accounts list with meta
function AccountingQueries.getAccounts(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 50

    local offset = (page - 1) * per_page

    local where_parts = { "namespace_id = ? AND deleted_at IS NULL" }
    local where_values = { namespace_id }

    if params.type and params.type ~= "" then
        table.insert(where_parts, "account_type = ?")
        table.insert(where_values, params.type)
    end

    if params.is_active ~= nil and params.is_active ~= "" then
        table.insert(where_parts, "is_active = ?")
        table.insert(where_values, params.is_active == "true" or params.is_active == true)
    end

    local where_clause = table.concat(where_parts, " AND ")

    -- Count
    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM accounting_accounts WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    -- Data (hierarchical ordering by code)
    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT * FROM accounting_accounts
        WHERE %s
        ORDER BY code ASC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local accounts = db.query(data_sql, unpack(data_values))

    return {
        items = accounts,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single account by UUID with current balance
-- @param uuid string Account UUID
-- @return table|nil Account
function AccountingQueries.getAccount(uuid)
    local result = db.query([[
        SELECT a.*,
            COALESCE(SUM(jl.debit_amount), 0) as total_debits,
            COALESCE(SUM(jl.credit_amount), 0) as total_credits
        FROM accounting_accounts a
        LEFT JOIN accounting_journal_lines jl ON jl.account_id = a.id
        LEFT JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id AND je.status = 'posted'
        WHERE a.uuid = ? AND a.deleted_at IS NULL
        GROUP BY a.id
    ]], uuid)
    return result and result[1] or nil
end

--- Create a new account
-- @param params table Account parameters
-- @return table|nil Created account
function AccountingQueries.createAccount(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return AccountingAccountModel:create(params, { returning = "*" })
end

--- Update an account
-- @param uuid string Account UUID
-- @param params table Update parameters
-- @return table|nil Updated account
function AccountingQueries.updateAccount(uuid, params)
    local account = AccountingAccountModel:find({ uuid = uuid })
    if not account then return nil end

    params.updated_at = db.raw("NOW()")
    return account:update(params, { returning = "*" })
end

--- Soft-delete an account (only if no journal lines reference it)
-- @param uuid string Account UUID
-- @return table|nil Deleted account, or nil with error
-- @return string|nil Error message
function AccountingQueries.deleteAccount(uuid)
    local account = AccountingAccountModel:find({ uuid = uuid })
    if not account then return nil, "Account not found" end

    -- Check for referencing journal lines
    local refs = db.query([[
        SELECT COUNT(*) as cnt FROM accounting_journal_lines
        WHERE account_id = ?
    ]], account.id)

    if refs and refs[1] and tonumber(refs[1].cnt) > 0 then
        return nil, "Cannot delete account with existing journal entries"
    end

    return account:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--------------------------------------------------------------------------------
-- Journal Entries
--------------------------------------------------------------------------------

--- List journal entries for a namespace
-- @param namespace_id number Namespace ID
-- @param params table Filter/pagination params (page, per_page, status, start_date, end_date)
-- @return table Journal entries with meta
function AccountingQueries.getJournalEntries(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local where_parts = { "namespace_id = ?" }
    local where_values = { namespace_id }

    if params.status and params.status ~= "" then
        table.insert(where_parts, "status = ?")
        table.insert(where_values, params.status)
    end

    if params.start_date and params.start_date ~= "" then
        table.insert(where_parts, "entry_date >= ?")
        table.insert(where_values, params.start_date)
    end

    if params.end_date and params.end_date ~= "" then
        table.insert(where_parts, "entry_date <= ?")
        table.insert(where_values, params.end_date)
    end

    local where_clause = table.concat(where_parts, " AND ")

    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM accounting_journal_entries WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT * FROM accounting_journal_entries
        WHERE %s
        ORDER BY entry_date DESC, entry_number DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local entries = db.query(data_sql, unpack(data_values))

    return {
        items = entries,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single journal entry with its lines
-- @param uuid string Journal entry UUID
-- @return table|nil Journal entry with lines
function AccountingQueries.getJournalEntry(uuid)
    local result = db.query([[
        SELECT * FROM accounting_journal_entries WHERE uuid = ?
    ]], uuid)

    if not result or not result[1] then return nil end

    local entry = result[1]

    local lines = db.query([[
        SELECT jl.*, aa.code as account_code, aa.name as account_name
        FROM accounting_journal_lines jl
        JOIN accounting_accounts aa ON aa.id = jl.account_id
        WHERE jl.journal_entry_id = ?
        ORDER BY jl.id ASC
    ]], entry.id)

    entry.lines = lines or {}
    return entry
end

--- Create a journal entry with balanced debit/credit lines
-- @param params table Entry params (namespace_id, description, entry_date, reference, lines[])
-- @return table|nil Created entry with lines
-- @return string|nil Error message
function AccountingQueries.createJournalEntry(params)
    if not params.lines or #params.lines == 0 then
        return nil, "Journal entry must have at least one line"
    end

    -- Validate that debits equal credits
    local total_debits = 0
    local total_credits = 0
    for _, line in ipairs(params.lines) do
        total_debits = total_debits + (tonumber(line.debit_amount) or 0)
        total_credits = total_credits + (tonumber(line.credit_amount) or 0)
    end

    if math.abs(total_debits - total_credits) > 0.01 then
        return nil, string.format("Journal entry is unbalanced: debits=%.2f credits=%.2f", total_debits, total_credits)
    end

    -- Generate entry number
    local last_entry = db.query([[
        SELECT entry_number FROM accounting_journal_entries
        WHERE namespace_id = ?
        ORDER BY entry_number DESC LIMIT 1
    ]], params.namespace_id)

    local next_number = 1
    if last_entry and last_entry[1] then
        next_number = (tonumber(last_entry[1].entry_number) or 0) + 1
    end

    local entry_uuid = Global.generateUUID()

    local entry = AccountingJournalEntryModel:create({
        uuid = entry_uuid,
        namespace_id = params.namespace_id,
        entry_number = next_number,
        entry_date = params.entry_date,
        description = params.description,
        reference = params.reference,
        status = params.status or "posted",
        total_amount = total_debits,
        created_by_user_uuid = params.created_by_user_uuid,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    if not entry then
        return nil, "Failed to create journal entry"
    end

    -- Create lines
    local AccountingJournalLineModel = require("models.AccountingJournalLineModel")
    for _, line in ipairs(params.lines) do
        AccountingJournalLineModel:create({
            journal_entry_id = entry.id,
            account_id = line.account_id,
            debit_amount = tonumber(line.debit_amount) or 0,
            credit_amount = tonumber(line.credit_amount) or 0,
            description = line.description
        })
    end

    -- Update account balances
    for _, line in ipairs(params.lines) do
        local debit = tonumber(line.debit_amount) or 0
        local credit = tonumber(line.credit_amount) or 0
        if debit > 0 or credit > 0 then
            db.query([[
                UPDATE accounting_accounts
                SET current_balance = current_balance + ? - ?,
                    updated_at = NOW()
                WHERE id = ?
            ]], debit, credit, line.account_id)
        end
    end

    return AccountingQueries.getJournalEntry(entry_uuid)
end

--- Void a journal entry (reverse its effect)
-- @param uuid string Journal entry UUID
-- @param reason string Void reason
-- @param user_uuid string User performing the void
-- @return table|nil Voided entry
-- @return string|nil Error message
function AccountingQueries.voidJournalEntry(uuid, reason, user_uuid)
    local entry = AccountingQueries.getJournalEntry(uuid)
    if not entry then return nil, "Journal entry not found" end

    if entry.status == "voided" then
        return nil, "Journal entry is already voided"
    end

    -- Reverse account balances
    for _, line in ipairs(entry.lines) do
        local debit = tonumber(line.debit_amount) or 0
        local credit = tonumber(line.credit_amount) or 0
        if debit > 0 or credit > 0 then
            db.query([[
                UPDATE accounting_accounts
                SET current_balance = current_balance - ? + ?,
                    updated_at = NOW()
                WHERE id = ?
            ]], debit, credit, line.account_id)
        end
    end

    -- Mark as voided
    db.query([[
        UPDATE accounting_journal_entries
        SET status = 'voided',
            void_reason = ?,
            voided_by_user_uuid = ?,
            voided_at = NOW(),
            updated_at = NOW()
        WHERE uuid = ?
    ]], reason, user_uuid, uuid)

    return AccountingQueries.getJournalEntry(uuid)
end

--------------------------------------------------------------------------------
-- Bank Transactions
--------------------------------------------------------------------------------

--- Bulk import bank transactions
-- @param namespace_id number Namespace ID
-- @param transactions table Array of {date, description, amount, balance}
-- @param import_source string Source identifier (e.g., "csv", "monzo")
-- @param user_uuid string User performing the import
-- @return table Import result with count and batch_id
function AccountingQueries.importBankTransactions(namespace_id, transactions, import_source, user_uuid)
    if not transactions or #transactions == 0 then
        return { count = 0, batch_id = nil }
    end

    local import_batch_id = Global.generateUUID()
    local imported = 0

    for _, txn in ipairs(transactions) do
        local amount = tonumber(txn.amount) or 0
        local debit_amount = 0
        local credit_amount = 0

        if amount < 0 then
            debit_amount = math.abs(amount)
        else
            credit_amount = amount
        end

        AccountingBankTransactionModel:create({
            uuid = Global.generateUUID(),
            namespace_id = namespace_id,
            transaction_date = txn.date,
            description = txn.description or "",
            amount = amount,
            debit_amount = debit_amount,
            credit_amount = credit_amount,
            balance = txn.balance,
            category = txn.category,
            import_source = import_source or "manual",
            import_batch_id = import_batch_id,
            is_reconciled = false,
            imported_by_user_uuid = user_uuid,
            created_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()")
        })

        imported = imported + 1
    end

    return {
        count = imported,
        batch_id = import_batch_id,
        import_source = import_source
    }
end

--- List bank transactions with pagination and filters
-- @param namespace_id number Namespace ID
-- @param params table Filter params (page, per_page, is_reconciled, start_date, end_date, search)
-- @return table Transactions with meta
function AccountingQueries.getBankTransactions(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local where_parts = { "namespace_id = ?" }
    local where_values = { namespace_id }

    if params.is_reconciled ~= nil and params.is_reconciled ~= "" then
        table.insert(where_parts, "is_reconciled = ?")
        table.insert(where_values, params.is_reconciled == "true" or params.is_reconciled == true)
    end

    if params.start_date and params.start_date ~= "" then
        table.insert(where_parts, "transaction_date >= ?")
        table.insert(where_values, params.start_date)
    end

    if params.end_date and params.end_date ~= "" then
        table.insert(where_parts, "transaction_date <= ?")
        table.insert(where_values, params.end_date)
    end

    if params.search and params.search ~= "" then
        table.insert(where_parts, "description ILIKE ?")
        table.insert(where_values, "%" .. params.search .. "%")
    end

    local where_clause = table.concat(where_parts, " AND ")

    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM accounting_bank_transactions WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT * FROM accounting_bank_transactions
        WHERE %s
        ORDER BY transaction_date DESC, id DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local txns = db.query(data_sql, unpack(data_values))

    return {
        items = txns,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single bank transaction by UUID
-- @param uuid string Transaction UUID
-- @return table|nil Transaction
function AccountingQueries.getBankTransaction(uuid)
    local result = db.query([[
        SELECT * FROM accounting_bank_transactions WHERE uuid = ?
    ]], uuid)
    return result and result[1] or nil
end

--- Update a bank transaction
-- @param uuid string Transaction UUID
-- @param params table Update parameters
-- @return table|nil Updated transaction
function AccountingQueries.updateBankTransaction(uuid, params)
    local txn = AccountingBankTransactionModel:find({ uuid = uuid })
    if not txn then return nil end

    params.updated_at = db.raw("NOW()")
    return txn:update(params, { returning = "*" })
end

--- Reconcile a bank transaction by creating a journal entry
-- @param uuid string Transaction UUID
-- @param account_id number Account ID to reconcile against
-- @param user_uuid string User performing reconciliation
-- @return table|nil Reconciled transaction
-- @return string|nil Error message
function AccountingQueries.reconcileBankTransaction(uuid, account_id, user_uuid)
    local txn = AccountingQueries.getBankTransaction(uuid)
    if not txn then return nil, "Bank transaction not found" end

    if txn.is_reconciled then
        return nil, "Transaction is already reconciled"
    end

    -- Determine debit/credit based on amount
    local amount = math.abs(tonumber(txn.amount) or 0)
    local lines = {}

    -- Get or find the bank account (assume account type 'asset' with code starting with '1')
    local bank_account = db.query([[
        SELECT id FROM accounting_accounts
        WHERE namespace_id = ? AND account_type = 'asset' AND code LIKE '1%' AND deleted_at IS NULL
        ORDER BY code ASC LIMIT 1
    ]], txn.namespace_id)

    local bank_account_id = bank_account and bank_account[1] and bank_account[1].id

    if tonumber(txn.amount) >= 0 then
        -- Money in: debit bank, credit the target account
        table.insert(lines, { account_id = bank_account_id or account_id, debit_amount = amount, credit_amount = 0 })
        table.insert(lines, { account_id = account_id, debit_amount = 0, credit_amount = amount })
    else
        -- Money out: credit bank, debit the target account
        table.insert(lines, { account_id = bank_account_id or account_id, debit_amount = 0, credit_amount = amount })
        table.insert(lines, { account_id = account_id, debit_amount = amount, credit_amount = 0 })
    end

    local entry, err = AccountingQueries.createJournalEntry({
        namespace_id = txn.namespace_id,
        description = "Bank reconciliation: " .. (txn.description or ""),
        entry_date = txn.transaction_date,
        reference = "BANK-" .. uuid,
        status = "posted",
        lines = lines,
        created_by_user_uuid = user_uuid
    })

    if not entry then
        return nil, "Failed to create journal entry: " .. (err or "unknown error")
    end

    -- Mark as reconciled
    db.query([[
        UPDATE accounting_bank_transactions
        SET is_reconciled = true,
            reconciled_journal_entry_id = ?,
            reconciled_at = NOW(),
            updated_at = NOW()
        WHERE uuid = ?
    ]], entry.id, uuid)

    return AccountingQueries.getBankTransaction(uuid)
end

--- Count unreconciled bank transactions for a namespace
-- @param namespace_id number Namespace ID
-- @return number Count
function AccountingQueries.getUnreconciledCount(namespace_id)
    local result = db.query([[
        SELECT COUNT(*) as cnt FROM accounting_bank_transactions
        WHERE namespace_id = ? AND is_reconciled = false
    ]], namespace_id)
    return tonumber(result[1].cnt) or 0
end

--------------------------------------------------------------------------------
-- Expenses
--------------------------------------------------------------------------------

--- Create a new expense
-- @param params table Expense parameters
-- @return table|nil Created expense
function AccountingQueries.createExpense(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return AccountingExpenseModel:create(params, { returning = "*" })
end

--- List expenses with pagination and filters
-- @param namespace_id number Namespace ID
-- @param params table Filter params (page, per_page, category, status, start_date, end_date, submitted_by)
-- @return table Expenses with meta
function AccountingQueries.getExpenses(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local where_parts = { "namespace_id = ? AND deleted_at IS NULL" }
    local where_values = { namespace_id }

    if params.category and params.category ~= "" then
        table.insert(where_parts, "category = ?")
        table.insert(where_values, params.category)
    end

    if params.status and params.status ~= "" then
        table.insert(where_parts, "status = ?")
        table.insert(where_values, params.status)
    end

    if params.start_date and params.start_date ~= "" then
        table.insert(where_parts, "expense_date >= ?")
        table.insert(where_values, params.start_date)
    end

    if params.end_date and params.end_date ~= "" then
        table.insert(where_parts, "expense_date <= ?")
        table.insert(where_values, params.end_date)
    end

    if params.submitted_by and params.submitted_by ~= "" then
        table.insert(where_parts, "submitted_by_user_uuid = ?")
        table.insert(where_values, params.submitted_by)
    end

    local where_clause = table.concat(where_parts, " AND ")

    local count_values = { unpack(where_values) }
    local count_sql = string.format("SELECT COUNT(*) as total FROM accounting_expenses WHERE %s", where_clause)
    local count_result = db.query(count_sql, unpack(count_values))
    local total = tonumber(count_result[1].total) or 0

    local data_values = { unpack(where_values) }
    table.insert(data_values, per_page)
    table.insert(data_values, offset)
    local data_sql = string.format([[
        SELECT * FROM accounting_expenses
        WHERE %s
        ORDER BY expense_date DESC, id DESC
        LIMIT ? OFFSET ?
    ]], where_clause)
    local expenses = db.query(data_sql, unpack(data_values))

    return {
        items = expenses,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = math.ceil(total / per_page)
        }
    }
end

--- Get a single expense by UUID
-- @param uuid string Expense UUID
-- @return table|nil Expense
function AccountingQueries.getExpense(uuid)
    local result = db.query([[
        SELECT * FROM accounting_expenses
        WHERE uuid = ? AND deleted_at IS NULL
    ]], uuid)
    return result and result[1] or nil
end

--- Update an expense
-- @param uuid string Expense UUID
-- @param params table Update parameters
-- @return table|nil Updated expense
function AccountingQueries.updateExpense(uuid, params)
    local expense = AccountingExpenseModel:find({ uuid = uuid })
    if not expense then return nil end

    params.updated_at = db.raw("NOW()")
    return expense:update(params, { returning = "*" })
end

--- Soft-delete an expense
-- @param uuid string Expense UUID
-- @return table|nil Deleted expense
-- @return string|nil Error message
function AccountingQueries.deleteExpense(uuid)
    local expense = AccountingExpenseModel:find({ uuid = uuid })
    if not expense then return nil, "Expense not found" end

    return expense:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Approve an expense and create a journal entry
-- @param uuid string Expense UUID
-- @param approver_uuid string Approver user UUID
-- @return table|nil Approved expense
-- @return string|nil Error message
function AccountingQueries.approveExpense(uuid, approver_uuid)
    local expense = AccountingQueries.getExpense(uuid)
    if not expense then return nil, "Expense not found" end

    if expense.status == "approved" then
        return nil, "Expense is already approved"
    end

    -- Find the expense account
    local expense_account = db.query([[
        SELECT id FROM accounting_accounts
        WHERE namespace_id = ? AND account_type = 'expense' AND deleted_at IS NULL
        ORDER BY code ASC LIMIT 1
    ]], expense.namespace_id)

    -- Find accounts payable / liability account
    local liability_account = db.query([[
        SELECT id FROM accounting_accounts
        WHERE namespace_id = ? AND account_type = 'liability' AND deleted_at IS NULL
        ORDER BY code ASC LIMIT 1
    ]], expense.namespace_id)

    if expense_account and expense_account[1] and liability_account and liability_account[1] then
        local amount = tonumber(expense.amount) or 0
        local lines = {
            { account_id = expense_account[1].id, debit_amount = amount, credit_amount = 0, description = expense.description },
            { account_id = liability_account[1].id, debit_amount = 0, credit_amount = amount, description = expense.description }
        }

        AccountingQueries.createJournalEntry({
            namespace_id = expense.namespace_id,
            description = "Expense approved: " .. (expense.description or ""),
            entry_date = expense.expense_date,
            reference = "EXP-" .. uuid,
            status = "posted",
            lines = lines,
            created_by_user_uuid = approver_uuid
        })
    end

    -- Update expense status
    db.query([[
        UPDATE accounting_expenses
        SET status = 'approved',
            approved_by_user_uuid = ?,
            approved_at = NOW(),
            updated_at = NOW()
        WHERE uuid = ?
    ]], approver_uuid, uuid)

    return AccountingQueries.getExpense(uuid)
end

--- Reject an expense
-- @param uuid string Expense UUID
-- @param approver_uuid string Rejector user UUID
-- @param reason string Rejection reason
-- @return table|nil Rejected expense
-- @return string|nil Error message
function AccountingQueries.rejectExpense(uuid, approver_uuid, reason)
    local expense = AccountingQueries.getExpense(uuid)
    if not expense then return nil, "Expense not found" end

    db.query([[
        UPDATE accounting_expenses
        SET status = 'rejected',
            approved_by_user_uuid = ?,
            rejection_reason = ?,
            updated_at = NOW()
        WHERE uuid = ?
    ]], approver_uuid, reason, uuid)

    return AccountingQueries.getExpense(uuid)
end

--------------------------------------------------------------------------------
-- VAT Returns
--------------------------------------------------------------------------------

--- Calculate and create a VAT return for a period
-- @param namespace_id number Namespace ID
-- @param period_start string Start date (YYYY-MM-DD)
-- @param period_end string End date (YYYY-MM-DD)
-- @param user_uuid string User creating the return
-- @return table|nil Created VAT return
function AccountingQueries.createVatReturn(namespace_id, period_start, period_end, user_uuid)
    -- Calculate VAT from expenses in the period
    local vat_data = db.query([[
        SELECT
            COALESCE(SUM(CASE WHEN amount > 0 THEN amount ELSE 0 END), 0) as total_sales,
            COALESCE(SUM(CASE WHEN amount > 0 THEN vat_amount ELSE 0 END), 0) as output_vat,
            COALESCE(SUM(CASE WHEN amount < 0 OR account_type = 'expense' THEN vat_amount ELSE 0 END), 0) as input_vat
        FROM (
            SELECT e.amount, e.vat_amount, 'expense' as account_type
            FROM accounting_expenses e
            WHERE e.namespace_id = ? AND e.expense_date >= ? AND e.expense_date <= ?
                AND e.deleted_at IS NULL AND e.status = 'approved'
            UNION ALL
            SELECT bt.amount, bt.vat_amount, 'bank' as account_type
            FROM accounting_bank_transactions bt
            WHERE bt.namespace_id = ? AND bt.transaction_date >= ? AND bt.transaction_date <= ?
        ) combined
    ]], namespace_id, period_start, period_end, namespace_id, period_start, period_end)

    local output_vat = tonumber(vat_data[1].output_vat) or 0
    local input_vat = tonumber(vat_data[1].input_vat) or 0
    local net_vat = output_vat - input_vat

    local vat_return = AccountingVatReturnModel:create({
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        period_start = period_start,
        period_end = period_end,
        output_vat = output_vat,
        input_vat = input_vat,
        net_vat = net_vat,
        total_sales = tonumber(vat_data[1].total_sales) or 0,
        status = "draft",
        created_by_user_uuid = user_uuid,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    return vat_return
end

--- List VAT returns for a namespace
-- @param namespace_id number Namespace ID
-- @return table Array of VAT returns
function AccountingQueries.getVatReturns(namespace_id)
    local result = db.query([[
        SELECT * FROM accounting_vat_returns
        WHERE namespace_id = ?
        ORDER BY period_start DESC
    ]], namespace_id)
    return result or {}
end

--- Get a single VAT return by UUID
-- @param uuid string VAT return UUID
-- @return table|nil VAT return
function AccountingQueries.getVatReturn(uuid)
    local result = db.query([[
        SELECT * FROM accounting_vat_returns WHERE uuid = ?
    ]], uuid)
    return result and result[1] or nil
end

--- Submit a VAT return (mark as submitted)
-- @param uuid string VAT return UUID
-- @param user_uuid string User submitting the return
-- @return table|nil Submitted VAT return
-- @return string|nil Error message
function AccountingQueries.submitVatReturn(uuid, user_uuid)
    local vat_return = AccountingQueries.getVatReturn(uuid)
    if not vat_return then return nil, "VAT return not found" end

    if vat_return.status == "submitted" then
        return nil, "VAT return is already submitted"
    end

    db.query([[
        UPDATE accounting_vat_returns
        SET status = 'submitted',
            submitted_at = NOW(),
            submitted_by_user_uuid = ?,
            updated_at = NOW()
        WHERE uuid = ?
    ]], user_uuid, uuid)

    return AccountingQueries.getVatReturn(uuid)
end

--------------------------------------------------------------------------------
-- Reports
--------------------------------------------------------------------------------

--- Generate a trial balance as of a given date
-- @param namespace_id number Namespace ID
-- @param as_of_date string Date (YYYY-MM-DD), defaults to today
-- @return table Trial balance rows
function AccountingQueries.getTrialBalance(namespace_id, as_of_date)
    as_of_date = as_of_date or os.date("%Y-%m-%d")

    local result = db.query([[
        SELECT
            aa.code,
            aa.name,
            aa.account_type,
            COALESCE(SUM(jl.debit_amount), 0) as total_debits,
            COALESCE(SUM(jl.credit_amount), 0) as total_credits,
            COALESCE(SUM(jl.debit_amount), 0) - COALESCE(SUM(jl.credit_amount), 0) as balance
        FROM accounting_accounts aa
        LEFT JOIN accounting_journal_lines jl ON jl.account_id = aa.id
        LEFT JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id
            AND je.status = 'posted' AND je.entry_date <= ?
        WHERE aa.namespace_id = ? AND aa.deleted_at IS NULL AND aa.is_active = true
        GROUP BY aa.id, aa.code, aa.name, aa.account_type
        HAVING COALESCE(SUM(jl.debit_amount), 0) != 0 OR COALESCE(SUM(jl.credit_amount), 0) != 0
        ORDER BY aa.code ASC
    ]], as_of_date, namespace_id)

    -- Calculate totals
    local total_debits = 0
    local total_credits = 0
    for _, row in ipairs(result) do
        total_debits = total_debits + (tonumber(row.total_debits) or 0)
        total_credits = total_credits + (tonumber(row.total_credits) or 0)
    end

    return {
        accounts = result,
        totals = {
            total_debits = total_debits,
            total_credits = total_credits,
            is_balanced = math.abs(total_debits - total_credits) < 0.01
        },
        as_of_date = as_of_date
    }
end

--- Generate a balance sheet as of a given date
-- @param namespace_id number Namespace ID
-- @param as_of_date string Date (YYYY-MM-DD)
-- @return table Balance sheet data
function AccountingQueries.getBalanceSheet(namespace_id, as_of_date)
    as_of_date = as_of_date or os.date("%Y-%m-%d")

    local result = db.query([[
        SELECT
            aa.account_type,
            aa.code,
            aa.name,
            COALESCE(SUM(jl.debit_amount), 0) - COALESCE(SUM(jl.credit_amount), 0) as balance
        FROM accounting_accounts aa
        LEFT JOIN accounting_journal_lines jl ON jl.account_id = aa.id
        LEFT JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id
            AND je.status = 'posted' AND je.entry_date <= ?
        WHERE aa.namespace_id = ? AND aa.deleted_at IS NULL AND aa.is_active = true
            AND aa.account_type IN ('asset', 'liability', 'equity')
        GROUP BY aa.id, aa.account_type, aa.code, aa.name
        HAVING COALESCE(SUM(jl.debit_amount), 0) - COALESCE(SUM(jl.credit_amount), 0) != 0
        ORDER BY aa.account_type, aa.code ASC
    ]], as_of_date, namespace_id)

    local assets = {}
    local liabilities = {}
    local equity = {}
    local total_assets = 0
    local total_liabilities = 0
    local total_equity = 0

    for _, row in ipairs(result) do
        local balance = tonumber(row.balance) or 0
        if row.account_type == "asset" then
            table.insert(assets, row)
            total_assets = total_assets + balance
        elseif row.account_type == "liability" then
            table.insert(liabilities, row)
            total_liabilities = total_liabilities + math.abs(balance)
        elseif row.account_type == "equity" then
            table.insert(equity, row)
            total_equity = total_equity + math.abs(balance)
        end
    end

    return {
        assets = { accounts = assets, total = total_assets },
        liabilities = { accounts = liabilities, total = total_liabilities },
        equity = { accounts = equity, total = total_equity },
        as_of_date = as_of_date
    }
end

--- Generate a profit and loss report for a period
-- @param namespace_id number Namespace ID
-- @param start_date string Start date (YYYY-MM-DD)
-- @param end_date string End date (YYYY-MM-DD)
-- @return table P&L data
function AccountingQueries.getProfitAndLoss(namespace_id, start_date, end_date)
    start_date = start_date or os.date("%Y-%m-01")
    end_date = end_date or os.date("%Y-%m-%d")

    local result = db.query([[
        SELECT
            aa.account_type,
            aa.code,
            aa.name,
            COALESCE(SUM(jl.credit_amount), 0) - COALESCE(SUM(jl.debit_amount), 0) as balance
        FROM accounting_accounts aa
        LEFT JOIN accounting_journal_lines jl ON jl.account_id = aa.id
        LEFT JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id
            AND je.status = 'posted'
            AND je.entry_date >= ? AND je.entry_date <= ?
        WHERE aa.namespace_id = ? AND aa.deleted_at IS NULL AND aa.is_active = true
            AND aa.account_type IN ('revenue', 'expense')
        GROUP BY aa.id, aa.account_type, aa.code, aa.name
        HAVING COALESCE(SUM(jl.debit_amount), 0) != 0 OR COALESCE(SUM(jl.credit_amount), 0) != 0
        ORDER BY aa.account_type, aa.code ASC
    ]], start_date, end_date, namespace_id)

    local revenue = {}
    local expenses = {}
    local total_revenue = 0
    local total_expenses = 0

    for _, row in ipairs(result) do
        local balance = tonumber(row.balance) or 0
        if row.account_type == "revenue" then
            table.insert(revenue, row)
            total_revenue = total_revenue + balance
        elseif row.account_type == "expense" then
            table.insert(expenses, row)
            total_expenses = total_expenses + math.abs(balance)
        end
    end

    return {
        revenue = { accounts = revenue, total = total_revenue },
        expenses = { accounts = expenses, total = total_expenses },
        net_profit = total_revenue - total_expenses,
        start_date = start_date,
        end_date = end_date
    }
end

--- Get expense summary grouped by category and month
-- @param namespace_id number Namespace ID
-- @param start_date string Start date (YYYY-MM-DD)
-- @param end_date string End date (YYYY-MM-DD)
-- @return table Expense summary
function AccountingQueries.getExpenseSummary(namespace_id, start_date, end_date)
    start_date = start_date or os.date("%Y-01-01")
    end_date = end_date or os.date("%Y-%m-%d")

    local by_category = db.query([[
        SELECT
            COALESCE(category, 'Uncategorised') as category,
            COUNT(*) as transaction_count,
            SUM(amount) as total_amount,
            SUM(vat_amount) as total_vat
        FROM accounting_expenses
        WHERE namespace_id = ? AND expense_date >= ? AND expense_date <= ?
            AND deleted_at IS NULL AND status != 'rejected'
        GROUP BY category
        ORDER BY total_amount DESC
    ]], namespace_id, start_date, end_date)

    local by_month = db.query([[
        SELECT
            TO_CHAR(expense_date, 'YYYY-MM') as month,
            COUNT(*) as transaction_count,
            SUM(amount) as total_amount,
            SUM(vat_amount) as total_vat
        FROM accounting_expenses
        WHERE namespace_id = ? AND expense_date >= ? AND expense_date <= ?
            AND deleted_at IS NULL AND status != 'rejected'
        GROUP BY TO_CHAR(expense_date, 'YYYY-MM')
        ORDER BY month ASC
    ]], namespace_id, start_date, end_date)

    return {
        by_category = by_category or {},
        by_month = by_month or {},
        start_date = start_date,
        end_date = end_date
    }
end

--- Get dashboard statistics
-- @param namespace_id number Namespace ID
-- @return table Dashboard stats
function AccountingQueries.getDashboardStats(namespace_id)
    -- Cash balance (sum of asset accounts)
    local cash_result = db.query([[
        SELECT COALESCE(SUM(current_balance), 0) as cash_balance
        FROM accounting_accounts
        WHERE namespace_id = ? AND account_type = 'asset' AND is_active = true AND deleted_at IS NULL
    ]], namespace_id)
    local cash_balance = tonumber(cash_result[1].cash_balance) or 0

    -- Expenses this month
    local month_start = os.date("%Y-%m-01")
    local expenses_result = db.query([[
        SELECT COALESCE(SUM(amount), 0) as total_expenses
        FROM accounting_expenses
        WHERE namespace_id = ? AND expense_date >= ? AND deleted_at IS NULL AND status != 'rejected'
    ]], namespace_id, month_start)
    local expenses_this_month = tonumber(expenses_result[1].total_expenses) or 0

    -- VAT owed (latest draft VAT return)
    local vat_result = db.query([[
        SELECT net_vat FROM accounting_vat_returns
        WHERE namespace_id = ? AND status = 'draft'
        ORDER BY period_end DESC LIMIT 1
    ]], namespace_id)
    local vat_owed = vat_result and vat_result[1] and tonumber(vat_result[1].net_vat) or 0

    -- Unreconciled count
    local unreconciled = AccountingQueries.getUnreconciledCount(namespace_id)

    -- Total accounts
    local accounts_result = db.query([[
        SELECT COUNT(*) as cnt FROM accounting_accounts
        WHERE namespace_id = ? AND is_active = true AND deleted_at IS NULL
    ]], namespace_id)
    local total_accounts = tonumber(accounts_result[1].cnt) or 0

    return {
        cash_balance = cash_balance,
        expenses_this_month = expenses_this_month,
        vat_owed = vat_owed,
        unreconciled_transactions = unreconciled,
        total_accounts = total_accounts,
        period = os.date("%B %Y")
    }
end

--------------------------------------------------------------------------------
-- AI Integration
--------------------------------------------------------------------------------

--- Auto-categorise a transaction using AI
-- @param description string Transaction description
-- @param amount number Transaction amount
-- @param namespace_id number Namespace ID
-- @return table|nil Categorisation result
-- @return string|nil Error message
function AccountingQueries.aiCategorize(description, amount, namespace_id)
    local AIService = require("lib.ai-service")

    -- Get expense accounts for this namespace
    local chart_of_accounts = db.query([[
        SELECT code, name, account_type FROM accounting_accounts
        WHERE namespace_id = ? AND is_active = true AND deleted_at IS NULL
        ORDER BY code ASC
    ]], namespace_id)

    return AIService.categorizeExpense(description, amount, chart_of_accounts or {})
end

--- Suggest VAT treatment for a transaction using AI
-- @param description string Transaction description
-- @param amount number Transaction amount
-- @param category string Expense category
-- @return table|nil VAT suggestion
-- @return string|nil Error message
function AccountingQueries.aiSuggestVat(description, amount, category)
    local AIService = require("lib.ai-service")
    return AIService.suggestVatTreatment(description, amount, category)
end

--- Natural language accounting query using AI
-- @param question string User's question
-- @param namespace_id number Namespace ID
-- @return table|nil Query interpretation
-- @return string|nil Error message
function AccountingQueries.aiQuery(question, namespace_id)
    local AIService = require("lib.ai-service")
    return AIService.naturalLanguageQuery(question, namespace_id)
end

return AccountingQueries
