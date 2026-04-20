--[[
    Tax Calculation Routes

    UK 2025-26 self-assessment tax calculation with multi-statement support.

    GET  /api/v2/tax/calculate/year-statements     — List statements by tax year
    GET  /api/v2/tax/calculate/:statement_id        — Single-statement tax calculation
    POST /api/v2/tax/calculate/multi                — Multi-statement aggregation
    GET  /api/v2/tax/calculate/summary/:statement_id — Formatted tax summary
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local Global = require("helper.global")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

local function getCurrentTaxYear()
    local now = os.date("*t")
    local year = now.year
    if now.month < 4 or (now.month == 4 and now.day < 6) then
        year = year - 1
    end
    return year .. "-" .. string.format("%02d", (year + 1) % 100)
end

local function getTaxYearDates(tax_year_str)
    local start_year = tonumber(tax_year_str:sub(1, 4))
    if not start_year then return nil, nil end
    return string.format("%d-04-06", start_year), string.format("%d-04-05", start_year + 1)
end

local function loadTaxRates(tax_year)
    local rows = db.query("SELECT * FROM tax_rates WHERE tax_year = ? LIMIT 1", tax_year)
    if rows and #rows > 0 then
        local r = rows[1]
        return {
            personal_allowance = tonumber(r.personal_allowance) or 12570,
            taper_threshold = tonumber(r.personal_allowance_taper_threshold) or 100000,
            basic_rate = tonumber(r.basic_rate) or 0.20,
            basic_rate_upper = tonumber(r.basic_rate_upper) or 50270,
            higher_rate = tonumber(r.higher_rate) or 0.40,
            higher_rate_upper = tonumber(r.higher_rate_upper) or 125140,
            additional_rate = tonumber(r.additional_rate) or 0.45,
            nic_main_rate = tonumber(r.nic_class4_main_rate) or 0.06,
            nic_lower = tonumber(r.nic_class4_lower_threshold) or 12570,
            nic_upper = tonumber(r.nic_class4_upper_threshold) or 50270,
            nic_additional_rate = tonumber(r.nic_class4_additional_rate) or 0.02,
            class2_annual = tonumber(r.nic_class2_annual) or 179.40,
            class2_threshold = tonumber(r.nic_class2_threshold) or 12570,
        }
    end
    return {
        personal_allowance = 12570, taper_threshold = 100000,
        basic_rate = 0.20, basic_rate_upper = 50270,
        higher_rate = 0.40, higher_rate_upper = 125140,
        additional_rate = 0.45,
        nic_main_rate = 0.06, nic_lower = 12570, nic_upper = 50270,
        nic_additional_rate = 0.02,
        class2_annual = 179.40, class2_threshold = 12570,
    }
end

--- Calculate full UK tax breakdown from gross income and expenses
local function calculateTax(gross_income, total_expenses, rates)
    local trading_profit = math.max(0, gross_income - total_expenses)

    -- Personal allowance (tapered for income > 100k)
    local pa = rates.personal_allowance
    if trading_profit > rates.taper_threshold then
        local excess = trading_profit - rates.taper_threshold
        pa = math.max(0, pa - math.floor(excess / 2))
    end

    local taxable_income = math.max(0, trading_profit - pa)

    -- Income tax bands
    local basic_tax = 0
    local higher_tax = 0
    local additional_tax = 0

    local remaining = taxable_income

    -- Basic rate band
    local basic_band = rates.basic_rate_upper - pa
    if basic_band > 0 then
        local basic_amount = math.min(remaining, basic_band)
        basic_tax = basic_amount * rates.basic_rate
        remaining = remaining - basic_amount
    end

    -- Higher rate band
    if remaining > 0 then
        local higher_band = rates.higher_rate_upper - rates.basic_rate_upper
        local higher_amount = math.min(remaining, higher_band)
        higher_tax = higher_amount * rates.higher_rate
        remaining = remaining - higher_amount
    end

    -- Additional rate
    if remaining > 0 then
        additional_tax = remaining * rates.additional_rate
    end

    local income_tax = basic_tax + higher_tax + additional_tax

    -- National Insurance Class 4
    local nic4 = 0
    if trading_profit > rates.nic_lower then
        local main_band = math.min(trading_profit, rates.nic_upper) - rates.nic_lower
        nic4 = main_band * rates.nic_main_rate
        if trading_profit > rates.nic_upper then
            nic4 = nic4 + (trading_profit - rates.nic_upper) * rates.nic_additional_rate
        end
    end

    -- Class 2 NIC
    local nic2 = 0
    if trading_profit >= rates.class2_threshold then
        nic2 = rates.class2_annual
    end

    local total_tax = income_tax + nic4 + nic2
    local effective_rate = trading_profit > 0 and (total_tax / trading_profit * 100) or 0

    return {
        gross_income = gross_income,
        total_expenses = total_expenses,
        trading_profit = trading_profit,
        personal_allowance = pa,
        taxable_income = taxable_income,
        income_tax = {
            basic = { amount = basic_tax, rate = rates.basic_rate },
            higher = { amount = higher_tax, rate = rates.higher_rate },
            additional = { amount = additional_tax, rate = rates.additional_rate },
            total = income_tax,
        },
        national_insurance = {
            class4 = nic4,
            class2 = nic2,
            total = nic4 + nic2,
        },
        total_tax_due = math.floor(total_tax * 100 + 0.5) / 100,
        effective_rate = math.floor(effective_rate * 100) / 100,
    }
end

--- Aggregate income/expenses from transactions for given statement IDs
local function aggregateStatements(statement_ids, user_id)
    if #statement_ids == 0 then return 0, 0 end

    local id_list = table.concat(statement_ids, ",")
    local result = db.query(string.format([[
        SELECT
            COALESCE(SUM(CASE WHEN transaction_type = 'CREDIT' AND is_tax_deductible IS NOT FALSE THEN amount ELSE 0 END), 0) as gross_income,
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

            local tax_year = self.params.tax_year or getCurrentTaxYear()
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
            local tax_year = stmt.tax_year or getCurrentTaxYear()
            local rates = loadTaxRates(tax_year)

            local gross_income, total_expenses = aggregateStatements({ self.params.statement_id }, user_id)
            local calculation = calculateTax(gross_income, total_expenses, rates)
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
            local tax_year = self.params.tax_year or getCurrentTaxYear()

            if not statement_ids or type(statement_ids) ~= "table" or #statement_ids == 0 then
                return { status = 400, json = { error = "statement_ids array is required" } }
            end

            -- Verify all statements belong to user
            local id_list = table.concat(statement_ids, ",")
            local verified = db.query(string.format(
                "SELECT id FROM tax_statements WHERE id IN (%s) AND user_id = ?", id_list
            ), user_id)

            if not verified or #verified ~= #statement_ids then
                return { status = 403, json = { error = "Some statements not found or not owned by user" } }
            end

            local rates = loadTaxRates(tax_year)
            local gross_income, total_expenses = aggregateStatements(statement_ids, user_id)
            local calculation = calculateTax(gross_income, total_expenses, rates)
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
            local tax_year = stmt.tax_year or getCurrentTaxYear()
            local rates = loadTaxRates(tax_year)

            local gross_income, total_expenses = aggregateStatements({ self.params.statement_id }, user_id)
            local calc = calculateTax(gross_income, total_expenses, rates)

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
