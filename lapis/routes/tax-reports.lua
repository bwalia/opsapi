--[[
    Tax Reports Routes

    Aggregated report endpoints for tax analysis, category breakdowns,
    HMRC box mapping summaries, and tax scenario calculations.

    All endpoints require authentication.
    Designed to be reusable across web and mobile apps.
]]

local db = require("lapis.db")
local cjson = require("cjson")

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

-- Load tax rates from DB for a given tax year, with hardcoded fallback
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
    -- Fallback defaults (2025-26 HMRC rates)
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

local function buildTaxBands(rates)
    return {
        { name = "Personal Allowance", lower = 0, upper = rates.personal_allowance, rate = 0 },
        { name = "Basic Rate", lower = rates.personal_allowance, upper = rates.basic_rate_upper, rate = rates.basic_rate },
        { name = "Higher Rate", lower = rates.basic_rate_upper, upper = rates.higher_rate_upper, rate = rates.higher_rate },
        { name = "Additional Rate", lower = rates.higher_rate_upper, upper = math.huge, rate = rates.additional_rate },
    }
end

local function buildNICBands(rates)
    return {
        { name = "Below threshold", lower = 0, upper = rates.nic_lower, rate = 0 },
        { name = "Main rate", lower = rates.nic_lower, upper = rates.nic_upper, rate = rates.nic_main_rate },
        { name = "Upper rate", lower = rates.nic_upper, upper = math.huge, rate = rates.nic_additional_rate },
    }
end

local function calculateTaxBreakdown(taxable_income, tax_bands)
    local bands = {}
    local total_tax = 0
    local remaining = taxable_income

    for _, band in ipairs(tax_bands) do
        local band_width = band.upper - band.lower
        local taxable_in_band = math.min(math.max(remaining - band.lower, 0), band_width)
        if taxable_in_band <= 0 and remaining <= band.lower then break end
        local tax = taxable_in_band * band.rate
        total_tax = total_tax + tax
        table.insert(bands, {
            name = band.name,
            lower = band.lower,
            upper = band.upper == math.huge and nil or band.upper,
            rate = band.rate,
            taxable_amount = math.floor(taxable_in_band * 100) / 100,
            tax = math.floor(tax * 100) / 100,
        })
    end

    return bands, math.floor(total_tax * 100) / 100
end

local function calculateNIC(profit, nic_bands)
    local total_nic = 0
    local bands = {}

    for _, band in ipairs(nic_bands) do
        local band_width = band.upper - band.lower
        local in_band = math.min(math.max(profit - band.lower, 0), band_width)
        if in_band <= 0 and profit <= band.lower then break end
        local nic = in_band * band.rate
        total_nic = total_nic + nic
        table.insert(bands, {
            name = band.name,
            rate = band.rate,
            amount = math.floor(in_band * 100) / 100,
            nic = math.floor(nic * 100) / 100,
        })
    end

    return bands, math.floor(total_nic * 100) / 100
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

        local tax_year = params.tax_year or getCurrentTaxYear()
        local ty_start, ty_end = getTaxYearDates(tax_year)

        -- If income/expenses provided, use those (scenario mode)
        -- Otherwise fetch from database (real mode)
        local total_income = tonumber(params.total_income)
        local total_expenses = tonumber(params.total_expenses)
        local additional_income = tonumber(params.additional_income) or 0

        if not total_income or not total_expenses then
            -- Fetch real data
            local totals = db.query([[
                SELECT
                    COALESCE(SUM(total_income), 0) as income,
                    COALESCE(SUM(total_expenses), 0) as expenses
                FROM tax_statements
                WHERE user_id = ?
                  AND (tax_year = ? OR (tax_year IS NULL AND period_end >= ?::date AND period_end <= ?::date))
            ]], user_id, tax_year, ty_start, ty_end)

            local t = totals[1] or {}
            total_income = tonumber(t.income) or 0
            total_expenses = tonumber(t.expenses) or 0
        end

        -- Load configurable rates from DB
        local rates = loadTaxRates(tax_year)
        local nic_band_config = buildNICBands(rates)

        local gross_income = total_income + additional_income
        local trading_profit = math.max(gross_income - total_expenses, 0)
        local personal_allowance = rates.personal_allowance
        -- Taper: reduce by £1 for every £2 over threshold
        if trading_profit > rates.taper_threshold then
            local reduction = math.floor((trading_profit - rates.taper_threshold) / 2)
            personal_allowance = math.max(personal_allowance - reduction, 0)
        end
        local taxable_income = math.max(trading_profit - personal_allowance, 0)

        -- Build tax bands with actual PA (may be tapered)
        local tax_band_config = {
            { name = "Personal Allowance", lower = 0, upper = personal_allowance, rate = 0 },
            { name = "Basic Rate", lower = personal_allowance, upper = rates.basic_rate_upper, rate = rates.basic_rate },
            { name = "Higher Rate", lower = rates.basic_rate_upper, upper = rates.higher_rate_upper, rate = rates.higher_rate },
            { name = "Additional Rate", lower = rates.higher_rate_upper, upper = math.huge, rate = rates.additional_rate },
        }

        -- Pass trading_profit (pre-PA) so the PA band correctly absorbs the allowance
        local tax_bands, income_tax = calculateTaxBreakdown(trading_profit, tax_band_config)
        local nic_bands, national_insurance = calculateNIC(trading_profit, nic_band_config)

        -- Class 2 NIC: annual amount if profit exceeds threshold
        local class_2_nic = 0
        if trading_profit > rates.class2_threshold then
            class_2_nic = rates.class2_annual
        end

        local total_tax = income_tax + national_insurance + class_2_nic

        return {
            status = 200,
            json = {
                tax_year = tax_year,
                is_scenario = params.total_income ~= nil,
                gross_income = math.floor(gross_income * 100) / 100,
                total_expenses = math.floor(total_expenses * 100) / 100,
                additional_income = additional_income,
                trading_profit = math.floor(trading_profit * 100) / 100,
                personal_allowance = personal_allowance,
                taxable_income = math.floor(taxable_income * 100) / 100,
                income_tax = income_tax,
                income_tax_bands = tax_bands,
                national_insurance = national_insurance,
                nic_bands = nic_bands,
                class_2_nic = math.floor(class_2_nic * 100) / 100,
                total_tax_due = math.floor(total_tax * 100) / 100,
                effective_rate = trading_profit > 0
                    and math.floor((total_tax / trading_profit) * 10000) / 100
                    or 0,
            }
        }
    end)

end
