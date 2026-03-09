--[[
    Tax Dashboard Routes

    Aggregated dashboard endpoints for the Tax CoPilot frontend.
    Returns real-time summary data from tax_statements, tax_transactions,
    and tax_returns tables.

    All endpoints require authentication.
    Users can only access their own data.
]]

local db = require("lapis.db")
local cjson = require("cjson")

-- Load tax rates from DB for a given tax year
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

-- Quick tax calculation on combined totals (for dashboard summary)
local function calculateEstimatedTax(total_income, total_expenses, rates)
    local trading_profit = math.max(total_income - total_expenses, 0)
    local pa = rates.personal_allowance
    if trading_profit > rates.taper_threshold then
        pa = math.max(pa - math.floor((trading_profit - rates.taper_threshold) / 2), 0)
    end
    local taxable = math.max(trading_profit - pa, 0)

    -- Income tax (progressive bands on taxable income)
    local income_tax = 0
    local remaining = taxable
    -- Basic rate band width
    local basic_width = rates.basic_rate_upper - rates.personal_allowance
    local basic = math.min(remaining, basic_width)
    income_tax = income_tax + basic * rates.basic_rate
    remaining = remaining - basic
    if remaining > 0 then
        local higher_width = rates.higher_rate_upper - rates.basic_rate_upper
        local higher = math.min(remaining, higher_width)
        income_tax = income_tax + higher * rates.higher_rate
        remaining = remaining - higher
    end
    if remaining > 0 then
        income_tax = income_tax + remaining * rates.additional_rate
    end

    -- Class 4 NIC (on trading profit)
    local nic = 0
    if trading_profit > rates.nic_lower then
        if trading_profit <= rates.nic_upper then
            nic = (trading_profit - rates.nic_lower) * rates.nic_main_rate
        else
            nic = (rates.nic_upper - rates.nic_lower) * rates.nic_main_rate
            nic = nic + (trading_profit - rates.nic_upper) * rates.nic_additional_rate
        end
    end

    -- Class 2 NIC
    local class2 = 0
    if trading_profit > rates.class2_threshold then
        class2 = rates.class2_annual
    end

    return math.floor((income_tax + nic + class2) * 100) / 100
end

-- Helper to get user's internal ID from JWT user object
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

-- Get the current UK tax year string (e.g. "2025-26")
-- UK tax year runs 6 April to 5 April
local function getCurrentTaxYear()
    local now = os.date("*t")
    local year = now.year
    local month = now.month
    local day = now.day

    -- Before 6 April → previous tax year
    if month < 4 or (month == 4 and day < 6) then
        year = year - 1
    end

    local next_year_short = string.format("%02d", (year + 1) % 100)
    return year .. "-" .. next_year_short
end

-- Get tax year date boundaries
local function getTaxYearDates(tax_year_str)
    -- Parse "2025-26" → start=2025-04-06, end=2026-04-05
    local start_year = tonumber(tax_year_str:sub(1, 4))
    if not start_year then return nil, nil end
    local end_year = start_year + 1
    return string.format("%d-04-06", start_year), string.format("%d-04-05", end_year)
end

return function(app)

    -- =========================================================================
    -- GET /api/v2/tax/dashboard/summary
    --
    -- Returns aggregated dashboard data for the current (or specified) tax year:
    --   - total_income, total_expenses, estimated_tax_due
    --   - statement counts by workflow step
    --   - MTD readiness percentage
    --   - monthly income/expense breakdown for chart
    --   - upcoming tax deadlines
    -- =========================================================================
    app:get("/api/v2/tax/dashboard/summary", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_id = getUserId(user)
        if not user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Determine tax year (from query param or current)
        local tax_year = self.params.tax_year or getCurrentTaxYear()
        local ty_start, ty_end = getTaxYearDates(tax_year)
        if not ty_start then
            return { status = 400, json = { error = "Invalid tax_year format. Use YYYY-YY (e.g. 2025-26)" } }
        end

        -- ── 1. Statement summary ─────────────────────────────────────────────
        local statements = db.query([[
            SELECT
                COUNT(*) as total_statements,
                COUNT(*) FILTER (WHERE workflow_step = 'FILED') as filed_count,
                COUNT(*) FILTER (WHERE workflow_step = 'TAX_CALCULATED') as calculated_count,
                COUNT(*) FILTER (WHERE workflow_step = 'RECONCILED') as reconciled_count,
                COUNT(*) FILTER (WHERE workflow_step IN ('UPLOADED','EXTRACTED','EXTRACT_CONFIRMED','CLASSIFIED','CLASSIFY_CONFIRMED')) as in_progress_count,
                COALESCE(SUM(total_income), 0) as total_income,
                COALESCE(SUM(total_expenses), 0) as total_expenses,
                COALESCE(SUM(tax_due), 0) as estimated_tax_due
            FROM tax_statements
            WHERE user_id = ?
              AND (
                  tax_year = ?
                  OR (tax_year IS NULL AND period_end IS NOT NULL
                      AND period_end >= ?::date AND period_end <= ?::date)
              )
        ]], user_id, tax_year, ty_start, ty_end)

        local summary = statements[1] or {}
        local total = tonumber(summary.total_statements) or 0
        local filed = tonumber(summary.filed_count) or 0
        local calculated = tonumber(summary.calculated_count) or 0
        local reconciled = tonumber(summary.reconciled_count) or 0
        local in_progress = tonumber(summary.in_progress_count) or 0

        -- Calculate estimated tax on COMBINED totals (not per-statement sum)
        local combined_income = tonumber(summary.total_income) or 0
        local combined_expenses = tonumber(summary.total_expenses) or 0
        local rates = loadTaxRates(tax_year)
        local estimated_tax_due = calculateEstimatedTax(combined_income, combined_expenses, rates)

        -- ── 2. MTD Readiness (percentage of statements that are RECONCILED or beyond)
        local ready_count = filed + calculated + reconciled
        local mtd_readiness = 0
        if total > 0 then
            mtd_readiness = math.floor((ready_count / total) * 100)
        end

        -- ── 3. Monthly income/expenses breakdown for chart ────────────────────
        local monthly = db.query([[
            SELECT
                TO_CHAR(t.transaction_date, 'YYYY-MM') as month,
                COALESCE(SUM(CASE WHEN t.transaction_type = 'CREDIT' THEN t.amount ELSE 0 END), 0) as income,
                COALESCE(SUM(CASE WHEN t.transaction_type = 'DEBIT' THEN ABS(t.amount) ELSE 0 END), 0) as expenses
            FROM tax_transactions t
            JOIN tax_statements s ON s.id = t.statement_id
            WHERE t.user_id = ?
              AND t.transaction_date >= ?::date
              AND t.transaction_date <= ?::date
            GROUP BY TO_CHAR(t.transaction_date, 'YYYY-MM')
            ORDER BY month
        ]], user_id, ty_start, ty_end)

        -- ── 4. Top expense categories ─────────────────────────────────────────
        local categories = db.query([[
            SELECT
                COALESCE(t.category, 'uncategorised') as category,
                COUNT(*) as transaction_count,
                COALESCE(SUM(ABS(t.amount)), 0) as total_amount
            FROM tax_transactions t
            JOIN tax_statements s ON s.id = t.statement_id
            WHERE t.user_id = ?
              AND t.transaction_type = 'DEBIT'
              AND t.transaction_date >= ?::date
              AND t.transaction_date <= ?::date
            GROUP BY t.category
            ORDER BY total_amount DESC
            LIMIT 8
        ]], user_id, ty_start, ty_end)

        -- ── 5. Recent activity (last 5 statements) ───────────────────────────
        local recent = db.query([[
            SELECT uuid, file_name, workflow_step, processing_status,
                   total_income, total_expenses, uploaded_at, updated_at
            FROM tax_statements
            WHERE user_id = ?
            ORDER BY updated_at DESC
            LIMIT 5
        ]], user_id)

        -- ── 6. Pending receipts (transactions needing classification confirmation)
        local pending = db.query([[
            SELECT COUNT(*) as pending_count
            FROM tax_transactions t
            JOIN tax_statements s ON s.id = t.statement_id
            WHERE t.user_id = ?
              AND t.classification_status = 'PENDING'
              AND t.transaction_date >= ?::date
              AND t.transaction_date <= ?::date
        ]], user_id, ty_start, ty_end)

        local pending_count = tonumber((pending[1] or {}).pending_count) or 0

        -- ── 7. Tax deadlines ──────────────────────────────────────────────────
        local start_year = tonumber(tax_year:sub(1, 4))
        local end_year = start_year + 1
        local now_str = os.date("%Y-%m-%d")

        local deadlines = {}
        local all_deadlines = {
            {
                date = string.format("%d-07-31", end_year),
                title = "Second Payment on Account",
                description = "Second instalment payment for " .. tax_year .. " tax year"
            },
            {
                date = string.format("%d-10-05", end_year),
                title = "Register for Self Assessment",
                description = "Deadline to register if filing for the first time"
            },
            {
                date = string.format("%d-10-31", end_year),
                title = "Paper Tax Return Deadline",
                description = "Last day to submit a paper " .. tax_year .. " tax return"
            },
            {
                date = string.format("%d-01-31", end_year + 1),
                title = "Online Tax Return Deadline",
                description = "Last day to file online and pay tax owed for " .. tax_year
            },
        }

        -- Only include future deadlines
        for _, d in ipairs(all_deadlines) do
            if d.date >= now_str then
                table.insert(deadlines, d)
            end
        end

        -- ── Build response ────────────────────────────────────────────────────
        return {
            status = 200,
            json = {
                tax_year = tax_year,
                total_income = combined_income,
                total_expenses = combined_expenses,
                estimated_tax_due = estimated_tax_due,
                statements = {
                    total = total,
                    filed = filed,
                    calculated = calculated,
                    reconciled = reconciled,
                    in_progress = in_progress,
                },
                mtd_readiness = mtd_readiness,
                pending_receipts = pending_count,
                monthly_breakdown = monthly or {},
                top_expense_categories = categories or {},
                recent_activity = recent or {},
                upcoming_deadlines = deadlines,
            }
        }
    end)

    -- =========================================================================
    -- GET /api/v2/tax/dashboard/year-comparison
    --
    -- Compare current tax year to previous year for trend indicators
    -- =========================================================================
    app:get("/api/v2/tax/dashboard/year-comparison", function(self)
        local user = self.current_user
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_id = getUserId(user)
        if not user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local tax_year = self.params.tax_year or getCurrentTaxYear()
        local start_year = tonumber(tax_year:sub(1, 4))
        if not start_year then
            return { status = 400, json = { error = "Invalid tax_year" } }
        end

        local prev_year_str = (start_year - 1) .. "-" .. string.format("%02d", start_year % 100)
        local ty_start, ty_end = getTaxYearDates(tax_year)
        local prev_start, prev_end = getTaxYearDates(prev_year_str)

        -- Get current year totals
        local current = db.query([[
            SELECT
                COALESCE(SUM(total_income), 0) as income,
                COALESCE(SUM(total_expenses), 0) as expenses,
                COALESCE(SUM(tax_due), 0) as tax_due
            FROM tax_statements
            WHERE user_id = ?
              AND (tax_year = ? OR (tax_year IS NULL AND period_end >= ?::date AND period_end <= ?::date))
        ]], user_id, tax_year, ty_start, ty_end)

        -- Get previous year totals
        local previous = db.query([[
            SELECT
                COALESCE(SUM(total_income), 0) as income,
                COALESCE(SUM(total_expenses), 0) as expenses,
                COALESCE(SUM(tax_due), 0) as tax_due
            FROM tax_statements
            WHERE user_id = ?
              AND (tax_year = ? OR (tax_year IS NULL AND period_end >= ?::date AND period_end <= ?::date))
        ]], user_id, prev_year_str, prev_start, prev_end)

        local cur = current[1] or {}
        local prev = previous[1] or {}

        -- Calculate percentage changes
        local function pct_change(cur_val, prev_val)
            cur_val = tonumber(cur_val) or 0
            prev_val = tonumber(prev_val) or 0
            if prev_val == 0 then
                return cur_val > 0 and 100 or 0
            end
            return math.floor(((cur_val - prev_val) / prev_val) * 100)
        end

        return {
            status = 200,
            json = {
                current_year = tax_year,
                previous_year = prev_year_str,
                income_change_pct = pct_change(cur.income, prev.income),
                expenses_change_pct = pct_change(cur.expenses, prev.expenses),
                tax_due_change_pct = pct_change(cur.tax_due, prev.tax_due),
            }
        }
    end)

end
