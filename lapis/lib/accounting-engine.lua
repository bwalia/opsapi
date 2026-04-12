-- Accounting Engine: Core Double-Entry Bookkeeping
-- Provides journal entry management, trial balance, balance sheet, P&L,
-- UK VAT return calculation, bank reconciliation, and expense summaries.
-- All monetary operations use DECIMAL(15,2) precision via PostgreSQL.

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local AccountingEngine = {}

-- ============================================================================
-- Internal Helpers
-- ============================================================================

--- Round a number to 2 decimal places.
-- @param n number
-- @return number
local function round2(n)
    return math.floor(n * 100 + 0.5) / 100
end

--- Validate that a date string is in YYYY-MM-DD format.
-- @param d string
-- @return boolean
local function is_valid_date(d)
    if not d or type(d) ~= "string" then return false end
    return d:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

-- ============================================================================
-- Journal Entry Number Generation
-- ============================================================================

--- Generate the next sequential journal entry number for a namespace.
-- Format: JE-YYYY-NNNN
-- @param namespace_id number
-- @return string
function AccountingEngine.getNextEntryNumber(namespace_id)
    local year = os.date("%Y")
    local prefix = "JE-" .. year .. "-"

    local result = db.query([[
        SELECT entry_number FROM accounting_journal_entries
        WHERE namespace_id = ? AND entry_number LIKE ?
        ORDER BY entry_number DESC
        LIMIT 1
    ]], namespace_id, prefix .. "%")

    if result and #result > 0 then
        local last = result[1].entry_number
        local seq_str = last:match("JE%-%d%d%d%d%-(%d+)$")
        local seq = tonumber(seq_str) or 0
        return string.format("%s%04d", prefix, seq + 1)
    end

    return prefix .. "0001"
end

-- ============================================================================
-- Create Journal Entry (Double-Entry)
-- ============================================================================

--- Create a balanced double-entry journal entry with lines.
-- Validates that total debits equal total credits before committing.
--
-- @param params table {
--   namespace_id: number (required),
--   description: string (required),
--   entry_date: string YYYY-MM-DD (required),
--   lines: table array of { account_id, debit, credit, description } (required, min 2),
--   reference: string (optional),
--   source_type: string (optional),
--   source_id: string (optional),
--   created_by_uuid: string (required),
-- }
-- @return table|nil journal_entry with lines, string|nil error
function AccountingEngine.createJournalEntry(params)
    -- Validate required fields
    if not params then return nil, "params is required" end
    if not params.namespace_id then return nil, "namespace_id is required" end
    if not params.description or params.description == "" then return nil, "description is required" end
    if not is_valid_date(params.entry_date) then return nil, "entry_date must be YYYY-MM-DD" end
    if not params.lines or type(params.lines) ~= "table" or #params.lines < 2 then
        return nil, "at least 2 journal lines are required"
    end
    if not params.created_by_uuid or params.created_by_uuid == "" then
        return nil, "created_by_uuid is required"
    end

    -- Validate balance: sum of debits must equal sum of credits
    local total_debits = 0
    local total_credits = 0
    for i, line in ipairs(params.lines) do
        if not line.account_id then
            return nil, string.format("line %d: account_id is required", i)
        end
        local debit = tonumber(line.debit) or 0
        local credit = tonumber(line.credit) or 0
        if debit < 0 or credit < 0 then
            return nil, string.format("line %d: amounts must not be negative", i)
        end
        if debit > 0 and credit > 0 then
            return nil, string.format("line %d: a line cannot have both debit and credit", i)
        end
        if debit == 0 and credit == 0 then
            return nil, string.format("line %d: a line must have a debit or credit amount", i)
        end
        total_debits = total_debits + debit
        total_credits = total_credits + credit
    end

    total_debits = round2(total_debits)
    total_credits = round2(total_credits)

    if total_debits ~= total_credits then
        return nil, string.format(
            "journal entry does not balance: debits=%.2f credits=%.2f (difference=%.2f)",
            total_debits, total_credits, math.abs(total_debits - total_credits)
        )
    end

    -- Generate entry number and UUID
    local entry_number = AccountingEngine.getNextEntryNumber(params.namespace_id)
    local entry_uuid = Global.generateUUID()

    -- Execute everything inside a database transaction
    local journal_entry, je_err = db.query("BEGIN")
    if not journal_entry then
        return nil, "Failed to begin transaction: " .. tostring(je_err)
    end

    local ok, result = pcall(function()
        -- Insert journal entry header
        db.query([[
            INSERT INTO accounting_journal_entries
                (uuid, namespace_id, entry_number, entry_date, description, reference,
                 source_type, source_id, status, total_amount, created_by_uuid, posted_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'posted', ?, ?, NOW(), NOW(), NOW())
        ]],
            entry_uuid,
            params.namespace_id,
            entry_number,
            params.entry_date,
            params.description,
            params.reference or db.NULL,
            params.source_type or db.NULL,
            params.source_id or db.NULL,
            total_debits,
            params.created_by_uuid
        )

        -- Fetch the inserted entry to get its id
        local entry_rows = db.query(
            "SELECT id FROM accounting_journal_entries WHERE uuid = ?",
            entry_uuid
        )
        if not entry_rows or #entry_rows == 0 then
            error("Failed to retrieve created journal entry")
        end
        local entry_id = entry_rows[1].id

        -- Insert each journal line and update account balances
        local created_lines = {}
        for _, line in ipairs(params.lines) do
            local line_uuid = Global.generateUUID()
            local debit = round2(tonumber(line.debit) or 0)
            local credit = round2(tonumber(line.credit) or 0)

            db.query([[
                INSERT INTO accounting_journal_lines
                    (uuid, journal_entry_id, account_id, debit_amount, credit_amount, description, created_at)
                VALUES (?, ?, ?, ?, ?, ?, NOW())
            ]],
                line_uuid,
                entry_id,
                line.account_id,
                debit,
                credit,
                line.description or db.NULL
            )

            -- Update account current_balance
            -- Assets and Expenses increase with debits, decrease with credits
            -- Liabilities, Equity, and Revenue increase with credits, decrease with debits
            local balance_change = debit - credit
            db.query([[
                UPDATE accounting_accounts
                SET current_balance = current_balance + ?,
                    updated_at = NOW()
                WHERE id = ?
            ]], balance_change, line.account_id)

            table.insert(created_lines, {
                uuid = line_uuid,
                account_id = line.account_id,
                debit_amount = debit,
                credit_amount = credit,
                description = line.description,
            })
        end

        return {
            id = entry_id,
            uuid = entry_uuid,
            entry_number = entry_number,
            entry_date = params.entry_date,
            description = params.description,
            reference = params.reference,
            source_type = params.source_type,
            source_id = params.source_id,
            status = "posted",
            total_amount = total_debits,
            created_by_uuid = params.created_by_uuid,
            lines = created_lines,
        }
    end)

    if not ok then
        pcall(function() db.query("ROLLBACK") end)
        return nil, "Failed to create journal entry: " .. tostring(result)
    end

    db.query("COMMIT")
    return result, nil
end

-- ============================================================================
-- Void Journal Entry
-- ============================================================================

--- Void a journal entry by creating an equal and opposite reversing entry.
-- Marks the original entry as 'void' with a reason.
--
-- @param journal_entry_id number
-- @param reason string
-- @param user_uuid string
-- @return table|nil reversing_entry, string|nil error
function AccountingEngine.voidJournalEntry(journal_entry_id, reason, user_uuid)
    if not journal_entry_id then return nil, "journal_entry_id is required" end
    if not reason or reason == "" then return nil, "reason is required" end
    if not user_uuid or user_uuid == "" then return nil, "user_uuid is required" end

    -- Fetch original entry
    local entries = db.query(
        "SELECT * FROM accounting_journal_entries WHERE id = ?",
        journal_entry_id
    )
    if not entries or #entries == 0 then
        return nil, "journal entry not found"
    end
    local original = entries[1]

    if original.status == "void" then
        return nil, "journal entry is already voided"
    end

    -- Fetch original lines
    local lines = db.query(
        "SELECT * FROM accounting_journal_lines WHERE journal_entry_id = ? ORDER BY id",
        journal_entry_id
    )
    if not lines or #lines == 0 then
        return nil, "no journal lines found for this entry"
    end

    -- Build reversing lines (swap debits and credits)
    local reversing_lines = {}
    for _, line in ipairs(lines) do
        table.insert(reversing_lines, {
            account_id = line.account_id,
            debit = tonumber(line.credit_amount) or 0,
            credit = tonumber(line.debit_amount) or 0,
            description = "Reversal: " .. (line.description or ""),
        })
    end

    -- Create the reversing entry
    local reversing_entry, create_err = AccountingEngine.createJournalEntry({
        namespace_id = original.namespace_id,
        description = string.format("VOID reversal of %s: %s", original.entry_number, reason),
        entry_date = os.date("%Y-%m-%d"),
        lines = reversing_lines,
        reference = "VOID-" .. original.entry_number,
        source_type = "void_reversal",
        source_id = tostring(journal_entry_id),
        created_by_uuid = user_uuid,
    })

    if not reversing_entry then
        return nil, "Failed to create reversing entry: " .. tostring(create_err)
    end

    -- Mark original as void
    db.query([[
        UPDATE accounting_journal_entries
        SET status = 'void', voided_at = NOW(), void_reason = ?, updated_at = NOW()
        WHERE id = ?
    ]], reason, journal_entry_id)

    return reversing_entry, nil
end

-- ============================================================================
-- Trial Balance
-- ============================================================================

--- Generate a trial balance as of a given date.
-- @param namespace_id number
-- @param as_of_date string YYYY-MM-DD
-- @return table { accounts, total_debits, total_credits, is_balanced }
function AccountingEngine.getTrialBalance(namespace_id, as_of_date)
    if not namespace_id then return nil, "namespace_id is required" end
    if not is_valid_date(as_of_date) then return nil, "as_of_date must be YYYY-MM-DD" end

    local accounts = db.query([[
        SELECT a.code, a.name, a.account_type, a.normal_balance,
               COALESCE(SUM(jl.debit_amount), 0) as total_debits,
               COALESCE(SUM(jl.credit_amount), 0) as total_credits,
               COALESCE(SUM(jl.debit_amount), 0) - COALESCE(SUM(jl.credit_amount), 0) as net_balance
        FROM accounting_accounts a
        LEFT JOIN accounting_journal_lines jl ON jl.account_id = a.id
        LEFT JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id
            AND je.status = 'posted'
            AND je.entry_date <= ?
        WHERE a.namespace_id = ?
            AND a.is_active = true
            AND a.deleted_at IS NULL
        GROUP BY a.id, a.code, a.name, a.account_type, a.normal_balance
        HAVING COALESCE(SUM(jl.debit_amount), 0) > 0 OR COALESCE(SUM(jl.credit_amount), 0) > 0
        ORDER BY a.code
    ]], as_of_date, namespace_id)

    local sum_debits = 0
    local sum_credits = 0
    for _, acct in ipairs(accounts or {}) do
        acct.total_debits = tonumber(acct.total_debits) or 0
        acct.total_credits = tonumber(acct.total_credits) or 0
        acct.net_balance = tonumber(acct.net_balance) or 0
        sum_debits = sum_debits + acct.total_debits
        sum_credits = sum_credits + acct.total_credits
    end

    return {
        accounts = accounts or {},
        total_debits = round2(sum_debits),
        total_credits = round2(sum_credits),
        is_balanced = round2(sum_debits) == round2(sum_credits),
        as_of_date = as_of_date,
    }, nil
end

-- ============================================================================
-- Balance Sheet
-- ============================================================================

--- Generate a balance sheet as of a given date.
-- @param namespace_id number
-- @param as_of_date string YYYY-MM-DD
-- @return table { assets, liabilities, equity, total_assets, total_liabilities_equity, is_balanced }
function AccountingEngine.getBalanceSheet(namespace_id, as_of_date)
    if not namespace_id then return nil, "namespace_id is required" end
    if not is_valid_date(as_of_date) then return nil, "as_of_date must be YYYY-MM-DD" end

    local accounts = db.query([[
        SELECT a.code, a.name, a.account_type, a.normal_balance,
               COALESCE(SUM(jl.debit_amount), 0) - COALESCE(SUM(jl.credit_amount), 0) as net_balance
        FROM accounting_accounts a
        LEFT JOIN accounting_journal_lines jl ON jl.account_id = a.id
        LEFT JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id
            AND je.status = 'posted'
            AND je.entry_date <= ?
        WHERE a.namespace_id = ?
            AND a.is_active = true
            AND a.deleted_at IS NULL
            AND a.account_type IN ('asset', 'liability', 'equity')
        GROUP BY a.id, a.code, a.name, a.account_type, a.normal_balance
        HAVING COALESCE(SUM(jl.debit_amount), 0) != 0 OR COALESCE(SUM(jl.credit_amount), 0) != 0
        ORDER BY a.code
    ]], as_of_date, namespace_id)

    local assets = {}
    local liabilities = {}
    local equity = {}
    local total_assets = 0
    local total_liabilities = 0
    local total_equity = 0

    for _, acct in ipairs(accounts or {}) do
        acct.net_balance = tonumber(acct.net_balance) or 0
        -- For display: assets have debit normal balance (positive = debit excess)
        -- Liabilities and equity have credit normal balance (balance = credits - debits)
        if acct.account_type == "asset" then
            acct.balance = acct.net_balance -- debit - credit
            total_assets = total_assets + acct.balance
            table.insert(assets, acct)
        elseif acct.account_type == "liability" then
            acct.balance = -acct.net_balance -- credit - debit (invert for display)
            total_liabilities = total_liabilities + acct.balance
            table.insert(liabilities, acct)
        elseif acct.account_type == "equity" then
            acct.balance = -acct.net_balance -- credit - debit (invert for display)
            total_equity = total_equity + acct.balance
            table.insert(equity, acct)
        end
    end

    -- Calculate retained earnings (net profit) to include in equity
    local pnl = AccountingEngine.getProfitAndLoss(namespace_id, "1970-01-01", as_of_date)
    local retained_earnings = 0
    if pnl then
        retained_earnings = tonumber(pnl.net_profit) or 0
    end

    local total_liabilities_equity = round2(total_liabilities + total_equity + retained_earnings)

    return {
        assets = assets,
        liabilities = liabilities,
        equity = equity,
        retained_earnings = round2(retained_earnings),
        total_assets = round2(total_assets),
        total_liabilities = round2(total_liabilities),
        total_equity = round2(total_equity),
        total_liabilities_equity = total_liabilities_equity,
        is_balanced = round2(total_assets) == total_liabilities_equity,
        as_of_date = as_of_date,
    }, nil
end

-- ============================================================================
-- Profit & Loss (Income Statement)
-- ============================================================================

--- Generate a profit and loss statement for a given period.
-- @param namespace_id number
-- @param start_date string YYYY-MM-DD
-- @param end_date string YYYY-MM-DD
-- @return table { revenue, expenses, total_revenue, total_expenses, net_profit }
function AccountingEngine.getProfitAndLoss(namespace_id, start_date, end_date)
    if not namespace_id then return nil, "namespace_id is required" end
    if not is_valid_date(start_date) then return nil, "start_date must be YYYY-MM-DD" end
    if not is_valid_date(end_date) then return nil, "end_date must be YYYY-MM-DD" end

    local accounts = db.query([[
        SELECT a.code, a.name, a.account_type, a.normal_balance,
               COALESCE(SUM(jl.debit_amount), 0) as total_debits,
               COALESCE(SUM(jl.credit_amount), 0) as total_credits,
               COALESCE(SUM(jl.debit_amount), 0) - COALESCE(SUM(jl.credit_amount), 0) as net_balance
        FROM accounting_accounts a
        LEFT JOIN accounting_journal_lines jl ON jl.account_id = a.id
        LEFT JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id
            AND je.status = 'posted'
            AND je.entry_date >= ?
            AND je.entry_date <= ?
        WHERE a.namespace_id = ?
            AND a.is_active = true
            AND a.deleted_at IS NULL
            AND a.account_type IN ('revenue', 'expense')
        GROUP BY a.id, a.code, a.name, a.account_type, a.normal_balance
        HAVING COALESCE(SUM(jl.debit_amount), 0) != 0 OR COALESCE(SUM(jl.credit_amount), 0) != 0
        ORDER BY a.code
    ]], start_date, end_date, namespace_id)

    local revenue = {}
    local expenses = {}
    local total_revenue = 0
    local total_expenses = 0

    for _, acct in ipairs(accounts or {}) do
        acct.total_debits = tonumber(acct.total_debits) or 0
        acct.total_credits = tonumber(acct.total_credits) or 0
        acct.net_balance = tonumber(acct.net_balance) or 0

        if acct.account_type == "revenue" then
            -- Revenue normal balance is credit; amount = credits - debits
            acct.amount = acct.total_credits - acct.total_debits
            total_revenue = total_revenue + acct.amount
            table.insert(revenue, acct)
        elseif acct.account_type == "expense" then
            -- Expense normal balance is debit; amount = debits - credits
            acct.amount = acct.total_debits - acct.total_credits
            total_expenses = total_expenses + acct.amount
            table.insert(expenses, acct)
        end
    end

    return {
        revenue = revenue,
        expenses = expenses,
        total_revenue = round2(total_revenue),
        total_expenses = round2(total_expenses),
        net_profit = round2(total_revenue - total_expenses),
        start_date = start_date,
        end_date = end_date,
    }, nil
end

-- ============================================================================
-- UK VAT Return Calculation (Boxes 1-9)
-- ============================================================================

--- Calculate a UK VAT return for the given period.
-- @param namespace_id number
-- @param start_date string YYYY-MM-DD
-- @param end_date string YYYY-MM-DD
-- @return table { box1..box9, period_start, period_end }
function AccountingEngine.calculateVatReturn(namespace_id, start_date, end_date)
    if not namespace_id then return nil, "namespace_id is required" end
    if not is_valid_date(start_date) then return nil, "start_date must be YYYY-MM-DD" end
    if not is_valid_date(end_date) then return nil, "end_date must be YYYY-MM-DD" end

    -- Box 1: VAT due on sales (output VAT from revenue-related journal lines)
    -- We look at the VAT Payable account (liability, code 2100) for credits in the period
    local box1_result = db.query([[
        SELECT COALESCE(SUM(jl.credit_amount), 0) - COALESCE(SUM(jl.debit_amount), 0) as vat_on_sales
        FROM accounting_journal_lines jl
        JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id
        JOIN accounting_accounts a ON a.id = jl.account_id
        WHERE je.namespace_id = ?
            AND je.status = 'posted'
            AND je.entry_date >= ?
            AND je.entry_date <= ?
            AND a.code = '2100'
            AND a.namespace_id = ?
    ]], namespace_id, start_date, end_date, namespace_id)

    local box1 = round2(tonumber(box1_result and box1_result[1] and box1_result[1].vat_on_sales) or 0)
    if box1 < 0 then box1 = 0 end

    -- Box 2: VAT due on EU acquisitions (placeholder, 0 for now)
    local box2 = 0

    -- Box 3: Total VAT due
    local box3 = round2(box1 + box2)

    -- Box 4: VAT reclaimed on purchases (from expenses where is_vat_reclaimable)
    local box4_result = db.query([[
        SELECT COALESCE(SUM(e.vat_amount), 0) as vat_reclaimed
        FROM accounting_expenses e
        WHERE e.namespace_id = ?
            AND e.expense_date >= ?
            AND e.expense_date <= ?
            AND e.is_vat_reclaimable = true
            AND e.status IN ('approved', 'posted')
            AND e.deleted_at IS NULL
    ]], namespace_id, start_date, end_date)

    local box4 = round2(tonumber(box4_result and box4_result[1] and box4_result[1].vat_reclaimed) or 0)

    -- Box 5: Net VAT (positive = owe HMRC, negative = refund)
    local box5 = round2(box3 - box4)

    -- Box 6: Total value of sales excl VAT
    local box6_result = db.query([[
        SELECT COALESCE(SUM(jl.credit_amount), 0) - COALESCE(SUM(jl.debit_amount), 0) as total_sales
        FROM accounting_journal_lines jl
        JOIN accounting_journal_entries je ON je.id = jl.journal_entry_id
        JOIN accounting_accounts a ON a.id = jl.account_id
        WHERE je.namespace_id = ?
            AND je.status = 'posted'
            AND je.entry_date >= ?
            AND je.entry_date <= ?
            AND a.account_type = 'revenue'
            AND a.namespace_id = ?
    ]], namespace_id, start_date, end_date, namespace_id)

    local box6 = round2(tonumber(box6_result and box6_result[1] and box6_result[1].total_sales) or 0)

    -- Box 7: Total value of purchases excl VAT
    local box7_result = db.query([[
        SELECT COALESCE(SUM(e.amount - e.vat_amount), 0) as total_purchases
        FROM accounting_expenses e
        WHERE e.namespace_id = ?
            AND e.expense_date >= ?
            AND e.expense_date <= ?
            AND e.status IN ('approved', 'posted')
            AND e.deleted_at IS NULL
    ]], namespace_id, start_date, end_date)

    local box7 = round2(tonumber(box7_result and box7_result[1] and box7_result[1].total_purchases) or 0)

    -- Box 8: Total value of supplies to EU (placeholder)
    local box8 = 0

    -- Box 9: Total value of acquisitions from EU (placeholder)
    local box9 = 0

    return {
        box1_vat_due_sales = box1,
        box2_vat_due_acquisitions = box2,
        box3_total_vat_due = box3,
        box4_vat_reclaimed = box4,
        box5_net_vat = box5,
        box6_total_sales = box6,
        box7_total_purchases = box7,
        box8_total_supplies_eu = box8,
        box9_total_acquisitions_eu = box9,
        period_start = start_date,
        period_end = end_date,
    }, nil
end

-- ============================================================================
-- Bank Transaction Reconciliation
-- ============================================================================

--- Reconcile a bank transaction by creating a journal entry and marking it reconciled.
-- @param bank_txn_id number accounting_bank_transactions.id
-- @param account_id number The expense/revenue account to post against
-- @param namespace_id number
-- @param user_uuid string
-- @return table|nil journal_entry, string|nil error
function AccountingEngine.reconcileBankTransaction(bank_txn_id, account_id, namespace_id, user_uuid)
    if not bank_txn_id then return nil, "bank_txn_id is required" end
    if not account_id then return nil, "account_id is required" end
    if not namespace_id then return nil, "namespace_id is required" end
    if not user_uuid then return nil, "user_uuid is required" end

    -- Fetch the bank transaction
    local txns = db.query(
        "SELECT * FROM accounting_bank_transactions WHERE id = ? AND namespace_id = ? AND deleted_at IS NULL",
        bank_txn_id, namespace_id
    )
    if not txns or #txns == 0 then
        return nil, "bank transaction not found"
    end
    local txn = txns[1]

    if txn.is_reconciled then
        return nil, "bank transaction is already reconciled"
    end

    -- Fetch the target account to validate it exists
    local target_accounts = db.query(
        "SELECT * FROM accounting_accounts WHERE id = ? AND namespace_id = ? AND deleted_at IS NULL",
        account_id, namespace_id
    )
    if not target_accounts or #target_accounts == 0 then
        return nil, "target account not found"
    end

    -- Find the bank account in the chart of accounts (code 1000 by default)
    local bank_accounts = db.query([[
        SELECT id FROM accounting_accounts
        WHERE namespace_id = ? AND code = '1000' AND is_active = true AND deleted_at IS NULL
        LIMIT 1
    ]], namespace_id)
    if not bank_accounts or #bank_accounts == 0 then
        return nil, "bank account (code 1000) not found in chart of accounts"
    end
    local bank_account_id = bank_accounts[1].id

    local amount = math.abs(tonumber(txn.amount) or 0)
    if amount == 0 then
        return nil, "transaction amount is zero"
    end

    -- Determine debit/credit based on transaction type
    local lines
    if txn.transaction_type == "debit" or (tonumber(txn.amount) or 0) < 0 then
        -- Money out: debit expense/target, credit bank
        lines = {
            { account_id = account_id, debit = amount, credit = 0, description = txn.description },
            { account_id = bank_account_id, debit = 0, credit = amount, description = txn.description },
        }
    else
        -- Money in: debit bank, credit revenue/target
        lines = {
            { account_id = bank_account_id, debit = amount, credit = 0, description = txn.description },
            { account_id = account_id, debit = 0, credit = amount, description = txn.description },
        }
    end

    -- Create the journal entry
    local journal_entry, je_err = AccountingEngine.createJournalEntry({
        namespace_id = namespace_id,
        description = "Bank reconciliation: " .. (txn.description or ""),
        entry_date = txn.transaction_date or os.date("%Y-%m-%d"),
        lines = lines,
        reference = txn.reference or txn.uuid,
        source_type = "bank_reconciliation",
        source_id = tostring(bank_txn_id),
        created_by_uuid = user_uuid,
    })

    if not journal_entry then
        return nil, "Failed to create reconciliation entry: " .. tostring(je_err)
    end

    -- Mark the bank transaction as reconciled
    db.query([[
        UPDATE accounting_bank_transactions
        SET is_reconciled = true,
            reconciled_journal_id = ?,
            updated_at = NOW()
        WHERE id = ?
    ]], journal_entry.id, bank_txn_id)

    return journal_entry, nil
end

-- ============================================================================
-- Expense Summary
-- ============================================================================

--- Get a monthly expense breakdown grouped by category.
-- @param namespace_id number
-- @param start_date string YYYY-MM-DD
-- @param end_date string YYYY-MM-DD
-- @return table { months, totals }
function AccountingEngine.getExpenseSummary(namespace_id, start_date, end_date)
    if not namespace_id then return nil, "namespace_id is required" end
    if not is_valid_date(start_date) then return nil, "start_date must be YYYY-MM-DD" end
    if not is_valid_date(end_date) then return nil, "end_date must be YYYY-MM-DD" end

    -- Query expenses grouped by month and category
    local rows = db.query([[
        SELECT
            TO_CHAR(e.expense_date, 'YYYY-MM') as month,
            e.category,
            SUM(e.amount) as total
        FROM accounting_expenses e
        WHERE e.namespace_id = ?
            AND e.expense_date >= ?
            AND e.expense_date <= ?
            AND e.status IN ('approved', 'posted')
            AND e.deleted_at IS NULL
        GROUP BY TO_CHAR(e.expense_date, 'YYYY-MM'), e.category
        ORDER BY month, e.category
    ]], namespace_id, start_date, end_date)

    -- Organise into { months: [{month, categories: [{name, total}]}], totals: {category: total} }
    local months_map = {}
    local category_totals = {}
    local months_order = {}

    for _, row in ipairs(rows or {}) do
        local month = row.month
        local cat = row.category
        local total = tonumber(row.total) or 0

        if not months_map[month] then
            months_map[month] = {}
            table.insert(months_order, month)
        end

        table.insert(months_map[month], {
            name = cat,
            total = round2(total),
        })

        category_totals[cat] = round2((category_totals[cat] or 0) + total)
    end

    local months = {}
    for _, month in ipairs(months_order) do
        table.insert(months, {
            month = month,
            categories = months_map[month],
        })
    end

    return {
        months = months,
        totals = category_totals,
        start_date = start_date,
        end_date = end_date,
    }, nil
end

return AccountingEngine
