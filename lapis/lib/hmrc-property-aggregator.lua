-- HMRC MTD UK property aggregator
-- Rolls a landlord's classified bank transactions for a UK tax year into the body of
-- HMRC's "Create or Amend a UK Property Cumulative Period Summary" (Property Business
-- API v6, tax years from 2025-26):
--   { fromDate, toDate, ukProperty = { income = {...}, expenses = {...} } }
--
-- The figures match the File My Tax estimate (lib/agent/tax-tools.lua TaxTools.estimate):
--   * income  = rents (rental_income → periodAmount) + other property income;
--   * expenses = transactions marked tax-deductible, by their HMRC box;
--   * mortgage payments are never deducted (capital + interest in one line). Interest
--     comes from what the landlord told the assistant: residential interest goes in
--     residentialFinancialCost (HMRC gives the 20% credit), commercial interest is an
--     ordinary expense (financialCosts).
-- Only CLASSIFIED and CONFIRMED rows count; PENDING / NEEDS_REVIEW are left out and
-- counted so filing can refuse until they are reviewed.

local db = require("lapis.db")
local Aggregator = require("lib.hmrc-aggregator")

local Property = {}

-- tax_hmrc_categories.key → UK property expense field. Boxes not listed (other than
-- the excluded ones) go to `other`.
local EXPENSE_FIELD = {
    rent_rates = "premisesRunningCosts",
    repairs_maintenance = "repairsAndMaintenance",
    interest_finance = "financialCosts",
    accountancy_legal = "professionalFees",
    wages_staff = "costOfServices",
    car_van_travel = "travelCosts",
}
-- Not part of the period summary (capital allowances are an annual adjustment;
-- use-of-home is a self-employment idea).
local EXCLUDED_BOX = { capital_allowances = true, use_of_home = true }
-- Income categories that are not property income (bank interest is savings income).
local NOT_PROPERTY_INCOME = { interest_income = true }

Property.EXPENSE_FIELD = EXPENSE_FIELD

local function round2(x)
    x = tonumber(x) or 0
    if x >= 0 then return math.floor(x * 100 + 0.5) / 100 end
    return -math.floor(-x * 100 + 0.5) / 100
end

--- Pure: turn grouped rows + the landlord's stated interest into the HMRC body.
-- rows: list of { transaction_type, category, hmrc_category, is_income, deductible, amount }
-- profile: { property_finance_costs, commercial_finance_costs }
-- Returns { income = {...}, expenses = {...}, residential = n, commercial_added = n,
--           negative_income = { field = value } }
function Property.fold(rows, profile, commercial_interest)
    profile = profile or {}
    local income, expenses = {}, {}
    local classified_interest = 0
    for _, r in ipairs(rows or {}) do
        local amt = tonumber(r.amount) or 0
        local credit = r.transaction_type == "CREDIT"
        if r.is_income and r.is_income ~= "f" then
            if not NOT_PROPERTY_INCOME[r.category] then
                local f = (r.category == "rental_income") and "periodAmount" or "otherIncome"
                income[f] = (income[f] or 0) + (credit and amt or -amt)
            end
        elseif (r.deductible == true or r.deductible == "t") and r.hmrc_category
            and not EXCLUDED_BOX[r.hmrc_category] then
            local f = EXPENSE_FIELD[r.hmrc_category] or "other"
            local v = credit and -amt or amt
            expenses[f] = (expenses[f] or 0) + v
            if r.hmrc_category == "interest_finance" then classified_interest = classified_interest + v end
        end
    end

    -- Residential interest: never an expense. If an older classification still claimed
    -- interest from the statements, take the residential part back out (as the estimate does).
    local fin = math.max(0, tonumber(profile.property_finance_costs) or 0)
    local moved = math.min(fin, math.max(0, classified_interest))
    local added = commercial_interest and commercial_interest(profile,
        { finance_interest = classified_interest }, fin) or 0
    if moved ~= 0 or added ~= 0 then
        expenses.financialCosts = (expenses.financialCosts or 0) - moved + added
    end

    local out = { income = {}, expenses = {}, residential = round2(fin), commercial_added = round2(added),
        negative_income = {} }
    for k, v in pairs(income) do
        v = round2(v)
        if v < 0 then out.negative_income[k] = v end
        if v ~= 0 then out.income[k] = v end
    end
    for k, v in pairs(expenses) do
        v = round2(v)
        if v ~= 0 then out.expenses[k] = v end
    end
    if out.residential > 0 then out.expenses.residentialFinancialCost = out.residential end
    return out
end

--- Build the UK property cumulative body for a user + tax year.
-- opts: { user_id, tax_year, profile (the File My Tax profile: finance costs) }
-- Returns { body, stats, tax_year_start, tax_year_end, empty, negative_fields } or nil, err
function Property.build_cumulative_body(opts)
    opts = opts or {}
    if not opts.user_id then return nil, "user_id is required" end
    local start_date, end_date, err = Aggregator.tax_year_bounds(opts.tax_year)
    if not start_date then return nil, err end

    -- A statement belongs to the year stamped on it, like the estimate.
    local rows = db.query([[
        SELECT t.transaction_type, t.category, t.hmrc_category, t.is_tax_deductible AS deductible,
               (h.mtd_section = 'periodIncome') AS is_income,
               SUM(t.amount) AS amount, COUNT(*) AS n
        FROM tax_transactions t
        JOIN tax_statements s ON s.id = t.statement_id
        LEFT JOIN tax_hmrc_categories h ON h.key = t.hmrc_category
        WHERE t.user_id = ? AND s.tax_year = ?
          AND t.classification_status IN ('CLASSIFIED', 'CONFIRMED')
        GROUP BY 1, 2, 3, 4, 5
    ]], opts.user_id, opts.tax_year) or {}

    local ok_tools, TaxTools = pcall(require, "lib.agent.tax-tools")
    local folded = Property.fold(rows, opts.profile, ok_tools and TaxTools._commercial_interest or nil)

    local counts = db.query([[
        SELECT COUNT(*) FILTER (WHERE t.classification_status IN ('PENDING','NEEDS_REVIEW')) AS unreviewed,
               COUNT(*) FILTER (WHERE t.classification_status IN ('CLASSIFIED','CONFIRMED')) AS applied,
               COUNT(*) AS total
        FROM tax_transactions t JOIN tax_statements s ON s.id = t.statement_id
        WHERE t.user_id = ? AND s.tax_year = ?]], opts.user_id, opts.tax_year)
    local c = (counts and counts[1]) or {}

    local uk = {}
    if next(folded.income) then uk.income = folded.income end
    if next(folded.expenses) then uk.expenses = folded.expenses end

    local negative_fields = {}
    for k, v in pairs(folded.negative_income) do
        negative_fields[#negative_fields + 1] = { field = k, section = "income", value = v }
    end

    return {
        body = { fromDate = start_date, toDate = end_date, ukProperty = uk },
        stats = {
            rows = tonumber(c.total) or 0,
            applied = tonumber(c.applied) or 0,
            excluded_unreviewed = tonumber(c.unreviewed) or 0,
            excluded_no_mtd_field = 0,
            residential_finance_costs = folded.residential,
            commercial_finance_costs_added = folded.commercial_added,
        },
        negative_fields = negative_fields,
        tax_year_start = start_date,
        tax_year_end = end_date,
        empty = (uk.income == nil and uk.expenses == nil),
    }, nil
end

return Property
