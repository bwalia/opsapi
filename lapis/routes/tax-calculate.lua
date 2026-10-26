--[[
    Tax Calculation Routes

    UK 2025-26 self-assessment tax calculation with multi-statement support.

    GET  /api/v2/tax/calculate/year-statements     — List statements by tax year
    GET  /api/v2/tax/calculate/:statement_id        — Single-statement tax calculation
    POST /api/v2/tax/calculate/multi                — Multi-statement aggregation
    GET  /api/v2/tax/calculate/summary/:statement_id — Formatted tax summary

    Tax maths + per-year rate loading live in lib/tax-calc (TaxCalc) — the single
    source of truth shared with the conversational tax agent (lib/agent/tax-tools)
    so the two can never disagree.
]]

local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")
local Global = require("helper.global")
local TaxCalc = require("lib.tax-calc")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

local function getTaxYearDates(tax_year_str)
    local start_year = tonumber(tax_year_str:sub(1, 4))
    if not start_year then return nil, nil end
    return string.format("%d-04-06", start_year), string.format("%d-04-05", start_year + 1)
end

--- Aggregate income/expenses from transactions for given statement IDs
local function aggregateStatements(statement_ids, user_id)
    if #statement_ids == 0 then return 0, 0 end

    -- Spliced into IN (...): render each id as an integer so nothing else can get in.
    local ids = {}
    for i, sid in ipairs(statement_ids) do
        local n = tonumber(sid)
        if not n or n ~= math.floor(n) then return 0, 0 end
        ids[i] = string.format("%d", n)
    end
    local id_list = table.concat(ids, ",")
    local result = db.query(string.format([[
        SELECT
            -- Credits in a non-business category (transfer, loan, drawings, personal) are
            -- not income — same rule as compute_estimate and lib/tax-report.
            COALESCE(SUM(CASE WHEN transaction_type = 'CREDIT' AND NOT EXISTS (
                SELECT 1 FROM tax_categories c WHERE c.key = tax_transactions.category AND c.hmrc_category_id IS NULL)
                THEN amount ELSE 0 END), 0) as gross_income,
            COALESCE(SUM(CASE WHEN transaction_type = 'DEBIT' AND is_tax_deductible = true THEN amount ELSE 0 END), 0) as total_expenses
        FROM tax_transactions
        WHERE statement_id IN (%s) AND user_id = ?
    ]], id_list), user_id)

    if result and result[1] then
        return tonumber(result[1].gross_income) or 0, tonumber(result[1].total_expenses) or 0
    end
    return 0, 0
end

return function(app)

    -- GET /api/v2/tax/calculate/year-statements
    app:get("/api/v2/tax/calculate/year-statements",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local tax_year = self.params.tax_year or TaxCalc.current_tax_year()
            local start_date, end_date = getTaxYearDates(tax_year)
            if not start_date then
                return { status = 400, json = { error = "Invalid tax year format (e.g. 2025-26)" } }
            end

            local statements = db.select([[
                * FROM tax_statements
                WHERE user_id = ? AND (
                    (period_start >= ? AND period_start <= ?) OR
                    (period_end >= ? AND period_end <= ?) OR
                    tax_year = ?
                )
                ORDER BY period_start ASC
            ]], user_id, start_date, end_date, start_date, end_date, tax_year)

            return {
                status = 200,
                json = {
                    data = statements,
                    tax_year = tax_year,
                    total = #statements,
                }
            }
        end)
    )

    -- GET /api/v2/tax/calculate/:statement_id
    app:get("/api/v2/tax/calculate/:statement_id",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local statements = db.select(
                "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                self.params.statement_id, user_id
            )
            if #statements == 0 then
                return { status = 404, json = { error = "Statement not found" } }
            end

            local stmt = statements[1]
            local tax_year = stmt.tax_year or TaxCalc.current_tax_year()
            local rates = TaxCalc.load_rates(tax_year)

            local gross_income, total_expenses = aggregateStatements({ self.params.statement_id }, user_id)
            local calculation = TaxCalc.compute(gross_income, total_expenses, rates)
            calculation.tax_year = tax_year
            calculation.statement_id = tonumber(self.params.statement_id)

            return { status = 200, json = { data = calculation } }
        end)
    )

    -- POST /api/v2/tax/calculate/multi
    app:post("/api/v2/tax/calculate/multi",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local statement_ids = self.params.statement_ids
            local tax_year = self.params.tax_year or TaxCalc.current_tax_year()

            if not statement_ids or type(statement_ids) ~= "table" or #statement_ids == 0 then
                return { status = 400, json = { error = "statement_ids array is required" } }
            end

            -- The ids are spliced into IN (...) below, so accept positive integers only
            -- and replace the raw params with the parsed numbers.
            local ids = {}
            for i, sid in ipairs(statement_ids) do
                local n = tostring(sid):match("^%d+$") and tonumber(sid)
                if not n then
                    return { status = 400, json = { error = "statement_ids must be numeric ids" } }
                end
                ids[i] = n
            end
            statement_ids = ids

            -- Verify all statements belong to user
            local id_list = table.concat(statement_ids, ",")
            local verified = db.query(string.format(
                "SELECT id FROM tax_statements WHERE id IN (%s) AND user_id = ?", id_list
            ), user_id)

            if not verified or #verified ~= #statement_ids then
                return { status = 403, json = { error = "Some statements not found or not owned by user" } }
            end

            local rates = TaxCalc.load_rates(tax_year)
            local gross_income, total_expenses = aggregateStatements(statement_ids, user_id)
            local calculation = TaxCalc.compute(gross_income, total_expenses, rates)
            calculation.tax_year = tax_year
            calculation.statement_ids = statement_ids

            -- Advance workflow for all included statements
            for _, sid in ipairs(statement_ids) do
                db.update("tax_statements", {
                    workflow_step = "TAX_CALCULATED",
                    updated_at = db.raw("NOW()"),
                }, { id = sid, user_id = user_id })
            end

            -- Upsert tax_returns record
            local existing = db.query(
                "SELECT id FROM tax_returns WHERE user_id = ? AND tax_year = ? LIMIT 1",
                user_id, tax_year
            )

            local return_data = {
                user_id = user_id,
                tax_year = tax_year,
                trading_income = gross_income,
                total_income = gross_income,
                total_expenses = total_expenses,
                trading_profit = calculation.trading_profit,
                personal_allowance = calculation.personal_allowance,
                taxable_income = calculation.taxable_income,
                income_tax = calculation.income_tax.total,
                national_insurance = calculation.national_insurance.total,
                total_tax_due = calculation.total_tax_due,
                status = "DRAFT",
                updated_at = db.raw("NOW()"),
            }

            if existing and #existing > 0 then
                db.update("tax_returns", return_data, { id = existing[1].id })
            else
                return_data.uuid = Global.generateStaticUUID()
                return_data.created_at = db.raw("NOW()")
                db.insert("tax_returns", return_data)
            end

            return { status = 200, json = { data = calculation } }
        end)
    )

    -- GET /api/v2/tax/calculate/summary/:statement_id
    app:get("/api/v2/tax/calculate/summary/:statement_id",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local statements = db.select(
                "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                self.params.statement_id, user_id
            )
            if #statements == 0 then
                return { status = 404, json = { error = "Statement not found" } }
            end

            local stmt = statements[1]
            local tax_year = stmt.tax_year or TaxCalc.current_tax_year()
            local rates = TaxCalc.load_rates(tax_year)

            local gross_income, total_expenses = aggregateStatements({ self.params.statement_id }, user_id)
            local calc = TaxCalc.compute(gross_income, total_expenses, rates)

            -- Category breakdown
            local categories = db.select([[
                category, hmrc_category,
                SUM(amount) as total,
                COUNT(*) as count,
                transaction_type
                FROM tax_transactions
                WHERE statement_id = ? AND classification_status != 'PENDING'
                GROUP BY category, hmrc_category, transaction_type
                ORDER BY total DESC
            ]], self.params.statement_id)

            return {
                status = 200,
                json = {
                    tax_year = tax_year,
                    statement = {
                        id = stmt.id,
                        bank_name = stmt.bank_name,
                        period_start = stmt.period_start,
                        period_end = stmt.period_end,
                        workflow_step = stmt.workflow_step,
                    },
                    calculation = calc,
                    categories = categories,
                }
            }
        end)
    )
end
