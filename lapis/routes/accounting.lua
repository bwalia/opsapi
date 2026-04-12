--[[
    Accounting API Routes
    =====================

    RESTful API for the double-entry accounting system.

    Endpoints:
    -- Chart of Accounts
    - GET    /api/v2/accounting/accounts              - List chart of accounts
    - POST   /api/v2/accounting/accounts              - Create account
    - GET    /api/v2/accounting/accounts/:uuid        - Get account
    - PUT    /api/v2/accounting/accounts/:uuid        - Update account
    - DELETE /api/v2/accounting/accounts/:uuid        - Delete account

    -- Journal Entries
    - GET    /api/v2/accounting/journal-entries            - List journal entries
    - POST   /api/v2/accounting/journal-entries            - Create journal entry
    - GET    /api/v2/accounting/journal-entries/:uuid      - Get with lines
    - POST   /api/v2/accounting/journal-entries/:uuid/void - Void entry

    -- Bank Transactions
    - GET    /api/v2/accounting/bank-transactions              - List transactions
    - POST   /api/v2/accounting/bank-transactions/import       - Bulk import
    - GET    /api/v2/accounting/bank-transactions/:uuid        - Get single
    - PUT    /api/v2/accounting/bank-transactions/:uuid        - Update
    - POST   /api/v2/accounting/bank-transactions/:uuid/reconcile - Reconcile

    -- Expenses
    - GET    /api/v2/accounting/expenses              - List expenses
    - POST   /api/v2/accounting/expenses              - Create expense
    - GET    /api/v2/accounting/expenses/:uuid        - Get expense
    - PUT    /api/v2/accounting/expenses/:uuid        - Update expense
    - DELETE /api/v2/accounting/expenses/:uuid        - Delete expense
    - POST   /api/v2/accounting/expenses/:uuid/approve - Approve
    - POST   /api/v2/accounting/expenses/:uuid/reject  - Reject

    -- VAT Returns
    - GET    /api/v2/accounting/vat-returns            - List VAT returns
    - POST   /api/v2/accounting/vat-returns            - Create VAT return
    - GET    /api/v2/accounting/vat-returns/:uuid      - Get VAT return
    - POST   /api/v2/accounting/vat-returns/:uuid/submit - Submit

    -- Reports
    - GET    /api/v2/accounting/reports/trial-balance   - Trial balance
    - GET    /api/v2/accounting/reports/balance-sheet    - Balance sheet
    - GET    /api/v2/accounting/reports/profit-loss      - Profit & loss
    - GET    /api/v2/accounting/reports/expense-summary  - Expense summary
    - GET    /api/v2/accounting/dashboard/stats          - Dashboard stats

    -- AI
    - POST   /api/v2/accounting/ai/categorize   - Auto-categorise
    - POST   /api/v2/accounting/ai/vat-suggest  - VAT suggestion
    - POST   /api/v2/accounting/ai/query        - Natural language query
    - GET    /api/v2/accounting/ai/status        - AI service availability
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local AccountingQueries = require("queries.AccountingQueries")

return function(app)
    -- Helper to parse JSON body
    local function parse_json_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, data = pcall(cjson.decode, body)
        return ok and data or {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    -- Helper to parse CSV content into transactions array
    local function parse_csv_transactions(csv_content)
        if not csv_content or csv_content == "" then
            return nil, "csv_content is empty"
        end

        local lines = {}
        for line in csv_content:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end

        if #lines < 2 then
            return nil, "CSV must have at least a header row and one data row"
        end

        -- Simple CSV field splitter (handles quoted fields)
        local function split_csv(line)
            local fields = {}
            local field = ""
            local in_quotes = false
            for i = 1, #line do
                local c = line:sub(i, i)
                if c == '"' then
                    in_quotes = not in_quotes
                elseif c == ',' and not in_quotes then
                    table.insert(fields, field:match("^%s*(.-)%s*$"))
                    field = ""
                else
                    field = field .. c
                end
            end
            table.insert(fields, field:match("^%s*(.-)%s*$"))
            return fields
        end

        -- Parse UK date string (DD/MM/YYYY or YYYY-MM-DD) to YYYY-MM-DD
        local function parse_date(s)
            if not s then return nil end
            s = s:match("^%s*(.-)%s*$")
            local d, m, y = s:match("^(%d%d?)/(%d%d?)/(%d%d%d%d)$")
            if d then
                return string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
            end
            if s:match("^%d%d%d%d%-%d%d%-%d%d$") then
                return s
            end
            return s
        end

        -- Detect columns from header
        local header = lines[1]:lower()
        local header_fields = split_csv(header)
        local date_idx, desc_idx, amount_idx, balance_idx

        for k, v in ipairs(header_fields) do
            local lv = v:lower()
            if lv:find("date") and not date_idx then date_idx = k end
            if (lv:find("desc") or lv:find("narrative") or lv:find("memo") or lv:find("reference")) and not desc_idx then desc_idx = k end
            if lv == "amount" and not amount_idx then amount_idx = k end
            if lv:find("balance") and not balance_idx then balance_idx = k end
        end

        if not date_idx then
            return nil, "Could not detect date column in CSV header"
        end
        if not amount_idx then
            return nil, "Could not detect amount column in CSV header"
        end
        desc_idx = desc_idx or (date_idx + 1)

        local transactions = {}
        for i = 2, #lines do
            local fields = split_csv(lines[i])
            if #fields >= amount_idx then
                table.insert(transactions, {
                    date = parse_date(fields[date_idx]),
                    description = fields[desc_idx] or "",
                    amount = tonumber(fields[amount_idx]) or 0,
                    balance = balance_idx and tonumber(fields[balance_idx])
                })
            end
        end

        return transactions
    end

    ---------------------------------------------------------------------------
    -- Chart of Accounts
    ---------------------------------------------------------------------------

    -- GET /api/v2/accounting/accounts - List chart of accounts
    app:get("/api/v2/accounting/accounts", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = AccountingQueries.getAccounts(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                type = self.params.type,
                is_active = self.params.is_active
            })

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.items,
                    meta = result.meta
                }
            }
        end)
    ))

    -- POST /api/v2/accounting/accounts - Create account
    app:post("/api/v2/accounting/accounts", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.code or data.code == "" then
                return api_response(400, nil, "code is required")
            end

            if not data.name or data.name == "" then
                return api_response(400, nil, "name is required")
            end

            if not data.account_type or data.account_type == "" then
                return api_response(400, nil, "account_type is required")
            end

            local account = AccountingQueries.createAccount({
                namespace_id = self.namespace.id,
                code = data.code,
                name = data.name,
                account_type = data.account_type,
                description = data.description,
                parent_account_id = data.parent_account_id,
                is_active = data.is_active ~= false,
                tax_rate = data.tax_rate,
                currency = data.currency or "GBP"
            })

            if not account then
                return api_response(500, nil, "Failed to create account")
            end

            return api_response(201, account)
        end)
    ))

    -- GET /api/v2/accounting/accounts/:uuid - Get account
    app:get("/api/v2/accounting/accounts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local account = AccountingQueries.getAccount(self.params.uuid)
            if not account then
                return api_response(404, nil, "Account not found")
            end

            if tonumber(account.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, account)
        end)
    ))

    -- PUT /api/v2/accounting/accounts/:uuid - Update account
    app:put("/api/v2/accounting/accounts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local account = AccountingQueries.getAccount(self.params.uuid)
            if not account then
                return api_response(404, nil, "Account not found")
            end

            if tonumber(account.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = {
                "code", "name", "account_type", "description",
                "parent_account_id", "is_active", "tax_rate", "currency"
            }

            for _, field in ipairs(allowed_fields) do
                if data[field] ~= nil then
                    update_params[field] = data[field]
                end
            end

            if next(update_params) == nil then
                return api_response(400, nil, "No valid fields to update")
            end

            local updated = AccountingQueries.updateAccount(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update account")
            end

            return api_response(200, updated)
        end)
    ))

    -- DELETE /api/v2/accounting/accounts/:uuid - Delete account
    app:delete("/api/v2/accounting/accounts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local account = AccountingQueries.getAccount(self.params.uuid)
            if not account then
                return api_response(404, nil, "Account not found")
            end

            if tonumber(account.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local deleted, err = AccountingQueries.deleteAccount(self.params.uuid)
            if not deleted then
                return api_response(400, nil, err or "Failed to delete account")
            end

            return api_response(200, deleted)
        end)
    ))

    ---------------------------------------------------------------------------
    -- Journal Entries
    ---------------------------------------------------------------------------

    -- GET /api/v2/accounting/journal-entries - List journal entries
    app:get("/api/v2/accounting/journal-entries", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = AccountingQueries.getJournalEntries(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                status = self.params.status,
                start_date = self.params.start_date,
                end_date = self.params.end_date
            })

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.items,
                    meta = result.meta
                }
            }
        end)
    ))

    -- POST /api/v2/accounting/journal-entries - Create journal entry
    app:post("/api/v2/accounting/journal-entries", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.description or data.description == "" then
                return api_response(400, nil, "description is required")
            end

            if not data.entry_date or data.entry_date == "" then
                return api_response(400, nil, "entry_date is required")
            end

            if not data.lines or type(data.lines) ~= "table" or #data.lines == 0 then
                return api_response(400, nil, "lines array is required with at least one entry")
            end

            local entry, err = AccountingQueries.createJournalEntry({
                namespace_id = self.namespace.id,
                description = data.description,
                entry_date = data.entry_date,
                reference = data.reference,
                status = data.status,
                lines = data.lines,
                created_by_user_uuid = self.current_user.uuid
            })

            if not entry then
                return api_response(400, nil, err or "Failed to create journal entry")
            end

            return api_response(201, entry)
        end)
    ))

    -- GET /api/v2/accounting/journal-entries/:uuid - Get journal entry with lines
    app:get("/api/v2/accounting/journal-entries/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local entry = AccountingQueries.getJournalEntry(self.params.uuid)
            if not entry then
                return api_response(404, nil, "Journal entry not found")
            end

            if tonumber(entry.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, entry)
        end)
    ))

    -- POST /api/v2/accounting/journal-entries/:uuid/void - Void journal entry
    app:post("/api/v2/accounting/journal-entries/:uuid/void", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.reason or data.reason == "" then
                return api_response(400, nil, "reason is required")
            end

            local entry = AccountingQueries.getJournalEntry(self.params.uuid)
            if not entry then
                return api_response(404, nil, "Journal entry not found")
            end

            if tonumber(entry.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local voided, err = AccountingQueries.voidJournalEntry(
                self.params.uuid,
                data.reason,
                self.current_user.uuid
            )

            if not voided then
                return api_response(400, nil, err or "Failed to void journal entry")
            end

            return api_response(200, voided)
        end)
    ))

    ---------------------------------------------------------------------------
    -- Bank Transactions
    ---------------------------------------------------------------------------

    -- GET /api/v2/accounting/bank-transactions - List bank transactions
    app:get("/api/v2/accounting/bank-transactions", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = AccountingQueries.getBankTransactions(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                is_reconciled = self.params.is_reconciled,
                start_date = self.params.start_date,
                end_date = self.params.end_date,
                search = self.params.search
            })

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.items,
                    meta = result.meta
                }
            }
        end)
    ))

    -- POST /api/v2/accounting/bank-transactions/import - Bulk import
    app:post("/api/v2/accounting/bank-transactions/import", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            local transactions = data.transactions
            local import_source = data.import_source or "manual"

            -- If csv_content is provided, parse it into transactions
            if data.csv_content and data.csv_content ~= "" then
                -- Try AI-powered parsing first, fall back to basic CSV parsing
                local ok_ai, AIService = pcall(require, "lib.ai-service")
                if ok_ai then
                    local parsed, ai_err = AIService.parseBankStatement(data.csv_content)
                    if parsed and #parsed > 0 then
                        transactions = parsed
                        import_source = parsed[1] and parsed[1].source or "csv"
                    else
                        -- Fall back to basic CSV parsing
                        local csv_txns, csv_err = parse_csv_transactions(data.csv_content)
                        if not csv_txns then
                            return api_response(400, nil, csv_err or "Failed to parse CSV content")
                        end
                        transactions = csv_txns
                        import_source = "csv"
                    end
                else
                    local csv_txns, csv_err = parse_csv_transactions(data.csv_content)
                    if not csv_txns then
                        return api_response(400, nil, csv_err or "Failed to parse CSV content")
                    end
                    transactions = csv_txns
                    import_source = "csv"
                end
            end

            if not transactions or type(transactions) ~= "table" or #transactions == 0 then
                return api_response(400, nil, "transactions array or csv_content is required")
            end

            local result = AccountingQueries.importBankTransactions(
                self.namespace.id,
                transactions,
                import_source,
                self.current_user.uuid
            )

            return api_response(201, result)
        end)
    ))

    -- GET /api/v2/accounting/bank-transactions/:uuid - Get single
    app:get("/api/v2/accounting/bank-transactions/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local txn = AccountingQueries.getBankTransaction(self.params.uuid)
            if not txn then
                return api_response(404, nil, "Bank transaction not found")
            end

            if tonumber(txn.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, txn)
        end)
    ))

    -- PUT /api/v2/accounting/bank-transactions/:uuid - Update
    app:put("/api/v2/accounting/bank-transactions/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local txn = AccountingQueries.getBankTransaction(self.params.uuid)
            if not txn then
                return api_response(404, nil, "Bank transaction not found")
            end

            if tonumber(txn.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = {
                "category", "description", "vat_rate", "vat_amount", "notes"
            }

            for _, field in ipairs(allowed_fields) do
                if data[field] ~= nil then
                    update_params[field] = data[field]
                end
            end

            if next(update_params) == nil then
                return api_response(400, nil, "No valid fields to update")
            end

            local updated = AccountingQueries.updateBankTransaction(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update bank transaction")
            end

            return api_response(200, updated)
        end)
    ))

    -- POST /api/v2/accounting/bank-transactions/:uuid/reconcile - Reconcile
    app:post("/api/v2/accounting/bank-transactions/:uuid/reconcile", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.account_id then
                return api_response(400, nil, "account_id is required")
            end

            local txn = AccountingQueries.getBankTransaction(self.params.uuid)
            if not txn then
                return api_response(404, nil, "Bank transaction not found")
            end

            if tonumber(txn.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local reconciled, err = AccountingQueries.reconcileBankTransaction(
                self.params.uuid,
                data.account_id,
                self.current_user.uuid
            )

            if not reconciled then
                return api_response(400, nil, err or "Failed to reconcile transaction")
            end

            return api_response(200, reconciled)
        end)
    ))

    ---------------------------------------------------------------------------
    -- Expenses
    ---------------------------------------------------------------------------

    -- GET /api/v2/accounting/expenses - List expenses
    app:get("/api/v2/accounting/expenses", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = AccountingQueries.getExpenses(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                category = self.params.category,
                status = self.params.status,
                start_date = self.params.start_date,
                end_date = self.params.end_date,
                submitted_by = self.params.submitted_by
            })

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.items,
                    meta = result.meta
                }
            }
        end)
    ))

    -- POST /api/v2/accounting/expenses - Create expense
    app:post("/api/v2/accounting/expenses", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.description or data.description == "" then
                return api_response(400, nil, "description is required")
            end

            if not data.amount then
                return api_response(400, nil, "amount is required")
            end

            local expense = AccountingQueries.createExpense({
                namespace_id = self.namespace.id,
                expense_date = data.expense_date or os.date("%Y-%m-%d"),
                description = data.description,
                amount = tonumber(data.amount),
                category = data.category,
                vat_rate = data.vat_rate,
                vat_amount = data.vat_amount,
                supplier = data.supplier,
                receipt_url = data.receipt_url,
                notes = data.notes,
                status = data.status or "pending",
                submitted_by_user_uuid = self.current_user.uuid
            })

            if not expense then
                return api_response(500, nil, "Failed to create expense")
            end

            return api_response(201, expense)
        end)
    ))

    -- GET /api/v2/accounting/expenses/:uuid - Get expense
    app:get("/api/v2/accounting/expenses/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local expense = AccountingQueries.getExpense(self.params.uuid)
            if not expense then
                return api_response(404, nil, "Expense not found")
            end

            if tonumber(expense.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, expense)
        end)
    ))

    -- PUT /api/v2/accounting/expenses/:uuid - Update expense
    app:put("/api/v2/accounting/expenses/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local expense = AccountingQueries.getExpense(self.params.uuid)
            if not expense then
                return api_response(404, nil, "Expense not found")
            end

            if tonumber(expense.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = {
                "expense_date", "description", "amount", "category",
                "vat_rate", "vat_amount", "supplier", "receipt_url", "notes"
            }

            for _, field in ipairs(allowed_fields) do
                if data[field] ~= nil then
                    update_params[field] = data[field]
                end
            end

            if next(update_params) == nil then
                return api_response(400, nil, "No valid fields to update")
            end

            local updated = AccountingQueries.updateExpense(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update expense")
            end

            return api_response(200, updated)
        end)
    ))

    -- DELETE /api/v2/accounting/expenses/:uuid - Delete expense
    app:delete("/api/v2/accounting/expenses/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local expense = AccountingQueries.getExpense(self.params.uuid)
            if not expense then
                return api_response(404, nil, "Expense not found")
            end

            if tonumber(expense.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local deleted, err = AccountingQueries.deleteExpense(self.params.uuid)
            if not deleted then
                return api_response(400, nil, err or "Failed to delete expense")
            end

            return api_response(200, deleted)
        end)
    ))

    -- POST /api/v2/accounting/expenses/:uuid/approve - Approve expense
    app:post("/api/v2/accounting/expenses/:uuid/approve", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local expense = AccountingQueries.getExpense(self.params.uuid)
            if not expense then
                return api_response(404, nil, "Expense not found")
            end

            if tonumber(expense.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local approved, err = AccountingQueries.approveExpense(
                self.params.uuid,
                self.current_user.uuid
            )

            if not approved then
                return api_response(400, nil, err or "Failed to approve expense")
            end

            return api_response(200, approved)
        end)
    ))

    -- POST /api/v2/accounting/expenses/:uuid/reject - Reject expense
    app:post("/api/v2/accounting/expenses/:uuid/reject", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.reason or data.reason == "" then
                return api_response(400, nil, "reason is required")
            end

            local expense = AccountingQueries.getExpense(self.params.uuid)
            if not expense then
                return api_response(404, nil, "Expense not found")
            end

            if tonumber(expense.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local rejected, err = AccountingQueries.rejectExpense(
                self.params.uuid,
                self.current_user.uuid,
                data.reason
            )

            if not rejected then
                return api_response(400, nil, err or "Failed to reject expense")
            end

            return api_response(200, rejected)
        end)
    ))

    ---------------------------------------------------------------------------
    -- VAT Returns
    ---------------------------------------------------------------------------

    -- GET /api/v2/accounting/vat-returns - List VAT returns
    app:get("/api/v2/accounting/vat-returns", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vat_returns = AccountingQueries.getVatReturns(self.namespace.id)

            return {
                status = 200,
                json = {
                    success = true,
                    data = vat_returns
                }
            }
        end)
    ))

    -- POST /api/v2/accounting/vat-returns - Calculate and create VAT return
    app:post("/api/v2/accounting/vat-returns", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.period_start or data.period_start == "" then
                return api_response(400, nil, "period_start is required")
            end

            if not data.period_end or data.period_end == "" then
                return api_response(400, nil, "period_end is required")
            end

            local vat_return = AccountingQueries.createVatReturn(
                self.namespace.id,
                data.period_start,
                data.period_end,
                self.current_user.uuid
            )

            if not vat_return then
                return api_response(500, nil, "Failed to create VAT return")
            end

            return api_response(201, vat_return)
        end)
    ))

    -- GET /api/v2/accounting/vat-returns/:uuid - Get VAT return
    app:get("/api/v2/accounting/vat-returns/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vat_return = AccountingQueries.getVatReturn(self.params.uuid)
            if not vat_return then
                return api_response(404, nil, "VAT return not found")
            end

            if tonumber(vat_return.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, vat_return)
        end)
    ))

    -- POST /api/v2/accounting/vat-returns/:uuid/submit - Submit VAT return
    app:post("/api/v2/accounting/vat-returns/:uuid/submit", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vat_return = AccountingQueries.getVatReturn(self.params.uuid)
            if not vat_return then
                return api_response(404, nil, "VAT return not found")
            end

            if tonumber(vat_return.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local submitted, err = AccountingQueries.submitVatReturn(
                self.params.uuid,
                self.current_user.uuid
            )

            if not submitted then
                return api_response(400, nil, err or "Failed to submit VAT return")
            end

            return api_response(200, submitted)
        end)
    ))

    ---------------------------------------------------------------------------
    -- Reports
    ---------------------------------------------------------------------------

    -- GET /api/v2/accounting/reports/trial-balance - Trial balance
    app:get("/api/v2/accounting/reports/trial-balance", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = AccountingQueries.getTrialBalance(
                self.namespace.id,
                self.params.as_of_date
            )

            return api_response(200, result)
        end)
    ))

    -- GET /api/v2/accounting/reports/balance-sheet - Balance sheet
    app:get("/api/v2/accounting/reports/balance-sheet", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = AccountingQueries.getBalanceSheet(
                self.namespace.id,
                self.params.as_of_date
            )

            return api_response(200, result)
        end)
    ))

    -- GET /api/v2/accounting/reports/profit-loss - Profit & loss
    app:get("/api/v2/accounting/reports/profit-loss", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = AccountingQueries.getProfitAndLoss(
                self.namespace.id,
                self.params.start_date,
                self.params.end_date
            )

            return api_response(200, result)
        end)
    ))

    -- GET /api/v2/accounting/reports/expense-summary - Expense summary
    app:get("/api/v2/accounting/reports/expense-summary", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = AccountingQueries.getExpenseSummary(
                self.namespace.id,
                self.params.start_date,
                self.params.end_date
            )

            return api_response(200, result)
        end)
    ))

    -- GET /api/v2/accounting/dashboard/stats - Dashboard statistics
    app:get("/api/v2/accounting/dashboard/stats", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local stats = AccountingQueries.getDashboardStats(self.namespace.id)
            return api_response(200, stats)
        end)
    ))

    ---------------------------------------------------------------------------
    -- AI Integration
    ---------------------------------------------------------------------------

    -- POST /api/v2/accounting/ai/categorize - Auto-categorise transaction
    app:post("/api/v2/accounting/ai/categorize", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.description or data.description == "" then
                return api_response(400, nil, "description is required")
            end

            if not data.amount then
                return api_response(400, nil, "amount is required")
            end

            local ok, result_or_err = pcall(function()
                return AccountingQueries.aiCategorize(
                    data.description,
                    tonumber(data.amount),
                    self.namespace.id
                )
            end)

            if not ok then
                return api_response(503, nil, "AI service unavailable: " .. tostring(result_or_err))
            end

            local result, err = result_or_err, nil
            if type(result_or_err) == "nil" then
                return api_response(503, nil, "AI service unavailable")
            end

            return api_response(200, result)
        end)
    ))

    -- POST /api/v2/accounting/ai/vat-suggest - VAT suggestion
    app:post("/api/v2/accounting/ai/vat-suggest", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.description or data.description == "" then
                return api_response(400, nil, "description is required")
            end

            if not data.amount then
                return api_response(400, nil, "amount is required")
            end

            local ok, result_or_err = pcall(function()
                return AccountingQueries.aiSuggestVat(
                    data.description,
                    tonumber(data.amount),
                    data.category
                )
            end)

            if not ok then
                return api_response(503, nil, "AI service unavailable: " .. tostring(result_or_err))
            end

            if not result_or_err then
                return api_response(503, nil, "AI service unavailable")
            end

            return api_response(200, result_or_err)
        end)
    ))

    -- POST /api/v2/accounting/ai/query - Natural language query
    app:post("/api/v2/accounting/ai/query", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.question or data.question == "" then
                return api_response(400, nil, "question is required")
            end

            local ok, result_or_err = pcall(function()
                return AccountingQueries.aiQuery(
                    data.question,
                    self.namespace.id
                )
            end)

            if not ok then
                return api_response(503, nil, "AI service unavailable: " .. tostring(result_or_err))
            end

            if not result_or_err then
                return api_response(503, nil, "AI service unavailable")
            end

            return api_response(200, result_or_err)
        end)
    ))

    -- GET /api/v2/accounting/ai/status - Check AI service availability
    app:get("/api/v2/accounting/ai/status", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ok_require, AIService = pcall(require, "lib.ai-service")
            if not ok_require then
                return api_response(200, {
                    available = false,
                    reason = "AI service module not loaded"
                })
            end

            local ok, is_available = pcall(function()
                return AIService.isAvailable()
            end)

            return api_response(200, {
                available = ok and is_available or false,
                reason = not ok and "AI service check failed" or (is_available and "operational" or "AI service unreachable")
            })
        end)
    ))
end
