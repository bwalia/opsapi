--[[
    Tax Reports Routes

    Aggregated report endpoints for tax analysis, category breakdowns,
    HMRC box mapping summaries, and tax scenario calculations.

    All endpoints require authentication.
    Designed to be reusable across web and mobile apps.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local TaxTools = require("lib.agent.tax-tools")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    if rows and #rows > 0 then return rows[1].id end
    return nil
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

return function(app)

    -- =========================================================================
    -- GET /api/v2/tax/reports/category-breakdown
    -- Breakdown of transactions by category for a tax year
    -- =========================================================================
    app:get("/api/v2/tax/reports/category-breakdown", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_id = getUserId(user)
        if not user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local tax_year = self.params.tax_year or getCurrentTaxYear()
        local ty_start, ty_end = getTaxYearDates(tax_year)
        if not ty_start then
            return { status = 400, json = { error = "Invalid tax_year" } }
        end

        local categories = db.query([[
            SELECT
                COALESCE(t.category, 'uncategorised') as category,
                t.transaction_type,
                COUNT(*) as transaction_count,
                COALESCE(SUM(ABS(t.amount)), 0) as total_amount,
                COALESCE(AVG(ABS(t.amount)), 0) as avg_amount,
                MIN(t.transaction_date) as first_date,
                MAX(t.transaction_date) as last_date
            FROM tax_transactions t
            JOIN tax_statements s ON s.id = t.statement_id
            WHERE t.user_id = ?
              AND t.transaction_date >= ?::date
              AND t.transaction_date <= ?::date
            GROUP BY t.category, t.transaction_type
            ORDER BY total_amount DESC
        ]], user_id, ty_start, ty_end)

        -- Separate into income and expenses
        local income_cats = {}
        local expense_cats = {}
        local total_income = 0
        local total_expenses = 0

        for _, c in ipairs(categories) do
            local entry = {
                category = c.category,
                transaction_count = tonumber(c.transaction_count),
                total_amount = tonumber(c.total_amount) or 0,
                avg_amount = math.floor((tonumber(c.avg_amount) or 0) * 100) / 100,
                first_date = c.first_date,
                last_date = c.last_date,
            }
            if c.transaction_type == "CREDIT" then
                total_income = total_income + entry.total_amount
                table.insert(income_cats, entry)
            else
                total_expenses = total_expenses + entry.total_amount
                table.insert(expense_cats, entry)
            end
        end

        return {
            status = 200,
            json = {
                tax_year = tax_year,
                total_income = math.floor(total_income * 100) / 100,
                total_expenses = math.floor(total_expenses * 100) / 100,
                income_categories = income_cats,
                expense_categories = expense_cats,
            }
        }
    end)

    -- =========================================================================
    -- GET /api/v2/tax/reports/hmrc-boxes
    -- Summary mapped to HMRC SA103F boxes
    -- =========================================================================
    app:get("/api/v2/tax/reports/hmrc-boxes", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_id = getUserId(user)
        if not user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local tax_year = self.params.tax_year or getCurrentTaxYear()
        local ty_start, ty_end = getTaxYearDates(tax_year)
        if not ty_start then
            return { status = 400, json = { error = "Invalid tax_year" } }
        end

        local boxes = db.query([[
            SELECT
                COALESCE(h.box, 'unmapped') as box,
                COALESCE(h.label, 'Unmapped') as box_label,
                COUNT(*) as transaction_count,
                COALESCE(SUM(ABS(t.amount)), 0) as total_amount
            FROM tax_transactions t
            JOIN tax_statements s ON s.id = t.statement_id
            LEFT JOIN tax_categories c ON c.key = t.category
            LEFT JOIN tax_hmrc_categories h ON h.id = c.hmrc_category_id
            WHERE t.user_id = ?
              AND t.transaction_date >= ?::date
              AND t.transaction_date <= ?::date
            GROUP BY h.box, h.label
            ORDER BY h.box
        ]], user_id, ty_start, ty_end)

        return {
            status = 200,
            json = {
                tax_year = tax_year,
                boxes = boxes or {},
            }
        }
    end)

    -- =========================================================================
    -- GET /api/v2/tax/reports/monthly-trend
    -- Monthly income/expense trend across multiple tax years
    -- =========================================================================
    app:get("/api/v2/tax/reports/monthly-trend", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_id = getUserId(user)
        if not user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Default: last 24 months
        local months = tonumber(self.params.months) or 24
        if months > 60 then months = 60 end

        local trend = db.query([[
            SELECT
                TO_CHAR(t.transaction_date, 'YYYY-MM') as month,
                COALESCE(SUM(CASE WHEN t.transaction_type = 'CREDIT' THEN t.amount ELSE 0 END), 0) as income,
                COALESCE(SUM(CASE WHEN t.transaction_type = 'DEBIT' THEN ABS(t.amount) ELSE 0 END), 0) as expenses,
                COUNT(*) as transaction_count
            FROM tax_transactions t
            JOIN tax_statements s ON s.id = t.statement_id
            WHERE t.user_id = ?
              AND t.transaction_date >= (CURRENT_DATE - INTERVAL '1 month' * ?)
            GROUP BY TO_CHAR(t.transaction_date, 'YYYY-MM')
            ORDER BY month
        ]], user_id, months)

        return {
            status = 200,
            json = {
                months_requested = months,
                data = trend or {},
            }
        }
    end)

    -- =========================================================================
    -- POST /api/v2/tax/reports/tax-calculation
    -- Full tax calculation with detailed breakdown
    -- Can be used standalone or with modified figures for scenario planning
    -- =========================================================================
    app:post("/api/v2/tax/reports/tax-calculation", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_id = getUserId(user)
        if not user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Parse JSON body
        local params = {}
        if ngx.req.get_headers()["content-type"] and
           ngx.req.get_headers()["content-type"]:find("application/json") then
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if body then
                local ok, parsed = pcall(cjson.decode, body)
                if ok and parsed then params = parsed end
            end
        end

        -- The dashboard posts form-encoded, diy posts JSON: accept both.
        for _, k in ipairs({ "tax_year", "total_income", "total_expenses", "additional_income" }) do
            if params[k] == nil and self.params[k] ~= nil and self.params[k] ~= "" then
                params[k] = self.params[k]
            end
        end

        local tax_year = params.tax_year or getCurrentTaxYear()
        if not getTaxYearDates(tostring(tax_year)) then
            return { status = 400, json = { error = "Invalid tax year format (e.g. 2025-26)" } }
        end

        -- If income/expenses provided, use those (scenario mode). Otherwise use the
        -- year's classified transactions — the same totals as the chat estimate.
        local total_income = tonumber(params.total_income)
        local total_expenses = tonumber(params.total_expenses)
        local additional_income = tonumber(params.additional_income) or 0
        local is_scenario = total_income ~= nil and total_expenses ~= nil

        if not is_scenario then
            local totals = TaxTools.year_totals(user_id, tax_year)
            total_income = totals.income
            total_expenses = totals.expenses
        end

        -- The figures come from the one UK engine (lib/tax-calc compute_full via
        -- TaxTools.estimate), shared with the chat estimate, the Calculate screens and
        -- the filing workbook. Response shape is unchanged for the web/mobile clients.
        local gross_income = total_income + additional_income
        local est = TaxTools.estimate(gross_income, total_expenses, tax_year,
            TaxTools.profile_for(user_id, tax_year))

        local function r2(v) return math.floor((tonumber(v) or 0) * 100 + 0.5) / 100 end

        return {
            status = 200,
            json = {
                tax_year = tax_year,
                is_scenario = is_scenario,
                gross_income = r2(gross_income),
                total_expenses = r2(total_expenses),
                additional_income = additional_income,
                trading_profit = r2(est.profit),
                personal_allowance = est.personal_allowance,
                taxable_income = r2(est.total_taxable),
                income_tax = r2(est.income_tax_due),
                income_tax_bands = est.income_tax_bands,
                national_insurance = r2(est.class4_nic),
                nic_bands = est.class4_bands,
                class_2_nic = r2(est.class2_nic),
                total_tax_due = r2(est.total_liability),
                effective_rate = est.effective_rate,
            }
        }
    end)

end
