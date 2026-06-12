-- HMRC MTD Aggregator
-- Rolls a user's classified bank transactions for a UK tax year up into the JSON body
-- HMRC's "self-employment cumulative" endpoint expects (periodIncome / periodExpenses /
-- periodDisallowableExpenses). This is the bridge between opsApi's classified data and
-- the HMRC submission — the same mapping diy-tax-return-uk's hmrc_aggregator proved.
--
-- The mapping is data-driven, not hardcoded:
--   tax_transactions.hmrc_category  → tax_hmrc_categories.key
--     → mtd_field_name (e.g. "carVanTravelExpenses") + mtd_section ("periodIncome"/"periodExpenses")
--   tax_transactions.category       → tax_categories.key → deduction_rate (disallowable portion)
-- Categories with a NULL mtd_field_name (capital_allowances, use_of_home, drawings, …)
-- are intentionally excluded from the period body — they are handled via separate HMRC
-- allowances/adjustments endpoints, never the period summary.

local db = require("lapis.db")

local Aggregator = {}

-- Statuses that are eligible to roll into a submission. PENDING and NEEDS_REVIEW are
-- deliberately excluded — nothing un-reviewed should reach an HMRC body.
local DEFAULT_STATUSES = { "CLASSIFIED", "CONFIRMED" }

-- Round to 2 decimal places, HALF_UP, sign-aware (HMRC monetary values are max 2dp).
local function round2(x)
    x = tonumber(x) or 0
    if x >= 0 then
        return math.floor(x * 100 + 0.5) / 100
    end
    return -math.floor(-x * 100 + 0.5) / 100
end

--- Convert "2025-26" → "2025-04-06", "2026-04-05". Returns nil + error on bad input.
function Aggregator.tax_year_bounds(tax_year)
    if type(tax_year) ~= "string" then
        return nil, nil, "tax_year must be a string like '2025-26'"
    end
    local y1, y2 = tax_year:match("^(%d%d%d%d)%-(%d%d)$")
    if not y1 then
        return nil, nil, "tax_year must be formatted 'YYYY-YY' (e.g. 2025-26)"
    end
    local start_year = tonumber(y1)
    -- The two-digit end must be exactly the next calendar year.
    if tonumber(y2) ~= (start_year + 1) % 100 then
        return nil, nil, "tax_year end must be the year after the start (e.g. 2025-26)"
    end
    return string.format("%04d-04-06", start_year),
           string.format("%04d-04-05", start_year + 1), nil
end

--- Load the MTD field catalogue (active income/expense fields) once. Returns:
--   fields  = list of { field, section } (mtd_field_name, mtd_section)
-- Used to pre-populate every field in a present section with 0.00, which HMRC requires
-- (it rejects a section that omits any of its fields).
local function load_field_catalogue()
    local rows = db.select(
        "DISTINCT mtd_field_name AS field, mtd_section AS section "
        .. "FROM tax_hmrc_categories WHERE is_active = true AND mtd_field_name IS NOT NULL")
    return rows or {}
end

--- Build the cumulative MTD body for a user + tax year from their classified transactions.
-- @param opts table { user_id (required), tax_year (required, "YYYY-YY"),
--                     statuses (optional list, default {CLASSIFIED, CONFIRMED}) }
-- @return table {
--   body = { periodIncome=?, periodExpenses=?, periodDisallowableExpenses=? },  -- trimmed
--   stats = { rows, applied, excluded_no_mtd_field, excluded_zero_amount,
--             excluded_unreviewed, by_field={...} },
--   tax_year_start, tax_year_end,
-- } or nil, err
function Aggregator.build_cumulative_body(opts)
    opts = opts or {}
    if not opts.user_id then return nil, "user_id is required" end

    local start_date, end_date, err = Aggregator.tax_year_bounds(opts.tax_year)
    if not start_date then return nil, err end

    local statuses = opts.statuses or DEFAULT_STATUSES
    local status_list = {}
    for _, s in ipairs(statuses) do
        table.insert(status_list, db.escape_literal(s))
    end
    local status_clause = table.concat(status_list, ", ")

    -- Catalogue → empty body (every field 0.0; disallowable mirror for each expense field).
    local catalogue = load_field_catalogue()
    local income, expenses, disallowable = {}, {}, {}
    local section_of = {}
    for _, c in ipairs(catalogue) do
        section_of[c.field] = c.section
        if c.section == "periodIncome" then
            income[c.field] = 0.0
        else
            expenses[c.field] = 0.0
            disallowable[c.field .. "Disallowable"] = 0.0
        end
    end

    -- Pull every classifiable transaction for the year, joined to its MTD field and the
    -- system category's deduction_rate (for the disallowable portion). Rows whose
    -- hmrc_category has no mtd_field_name are excluded by the JOIN — counted separately.
    local rows = db.query([[
        SELECT t.transaction_type, t.amount,
               h.mtd_field_name AS field, h.mtd_section AS section,
               COALESCE(c.deduction_rate, 1.0) AS deduction_rate
        FROM tax_transactions t
        JOIN tax_hmrc_categories h ON t.hmrc_category = h.key AND h.is_active = true
        LEFT JOIN tax_categories c ON t.category = c.key
        WHERE t.user_id = ?
          AND t.transaction_date >= ?  AND t.transaction_date <= ?
          AND h.mtd_field_name IS NOT NULL
          AND t.classification_status IN (]] .. status_clause .. [[)
    ]], opts.user_id, start_date, end_date)
    rows = rows or {}

    local stats = { rows = 0, applied = 0, excluded_zero_amount = 0, by_field = {} }

    for _, r in ipairs(rows) do
        stats.rows = stats.rows + 1
        local amount = tonumber(r.amount) or 0
        if amount == 0 then
            stats.excluded_zero_amount = stats.excluded_zero_amount + 1
        else
            local field = r.field
            -- Sign convention: income is CREDIT-positive, expenses are DEBIT-positive.
            -- A CREDIT against an expense (a refund) therefore reduces that expense.
            local is_credit = (r.transaction_type == "CREDIT")
            if r.section == "periodIncome" then
                local v = is_credit and amount or -amount
                income[field] = (income[field] or 0) + v
            else
                local v = is_credit and -amount or amount
                expenses[field] = (expenses[field] or 0) + v
                -- Disallowable portion = amount × (1 − deduction_rate).
                local rate = tonumber(r.deduction_rate) or 1.0
                disallowable[field .. "Disallowable"] =
                    (disallowable[field .. "Disallowable"] or 0) + (v * (1 - rate))
            end
            stats.applied = stats.applied + 1
            stats.by_field[field] = (stats.by_field[field] or 0) + 1
        end
    end

    -- Count unreviewed rows (excluded from the body) so the caller can warn the user.
    local unreviewed = db.query([[
        SELECT COUNT(*) AS n FROM tax_transactions t
        JOIN tax_hmrc_categories h ON t.hmrc_category = h.key
        WHERE t.user_id = ? AND t.transaction_date >= ? AND t.transaction_date <= ?
          AND t.classification_status IN (']] .. "PENDING" .. [[', ']] .. "NEEDS_REVIEW" .. [[')
    ]], opts.user_id, start_date, end_date)
    stats.excluded_unreviewed = (unreviewed and unreviewed[1] and tonumber(unreviewed[1].n)) or 0

    -- Rows with a category that maps to no MTD field (capital_allowances etc.).
    local no_field = db.query([[
        SELECT COUNT(*) AS n FROM tax_transactions t
        JOIN tax_hmrc_categories h ON t.hmrc_category = h.key
        WHERE t.user_id = ? AND t.transaction_date >= ? AND t.transaction_date <= ?
          AND h.mtd_field_name IS NULL
          AND t.classification_status IN (]] .. status_clause .. [[)
    ]], opts.user_id, start_date, end_date)
    stats.excluded_no_mtd_field = (no_field and no_field[1] and tonumber(no_field[1].n)) or 0

    -- Quantise everything to 2dp; detect all-zero sections and any negative values.
    -- HMRC rejects negative income/expense values, so a negative field is a hard filing
    -- blocker (usually a CREDIT — money in / a refund — miscategorised into an expense).
    local negative_fields = {}
    local function finalise(tbl, section)
        local all_zero = true
        for k, v in pairs(tbl) do
            tbl[k] = round2(v)
            if tbl[k] ~= 0 then all_zero = false end
            if tbl[k] < 0 then
                table.insert(negative_fields, { field = k, section = section, value = tbl[k] })
            end
        end
        return all_zero
    end
    local income_zero = finalise(income, "periodIncome")
    local expenses_zero = finalise(expenses, "periodExpenses")
    local disallowable_zero = finalise(disallowable, "periodDisallowableExpenses")

    -- HMRC rejects a section that is entirely zero ("empty or non-matching body"), so
    -- trim them. Disallowable only travels with a present expenses section.
    local body = {}
    if not income_zero then body.periodIncome = income end
    if not expenses_zero then
        body.periodExpenses = expenses
        if not disallowable_zero then body.periodDisallowableExpenses = disallowable end
    end

    return {
        body = body,
        stats = stats,
        negative_fields = negative_fields,
        tax_year_start = start_date,
        tax_year_end = end_date,
        empty = (income_zero and expenses_zero),
    }, nil
end

--- Return the CREDIT transactions pulling an expense field negative, so the UI can show
--- (and let the user fix) exactly which rows block the filing. `fields` is a list of
--- mtd_field_name strings (the `field` values from negative_fields, with any trailing
--- "Disallowable" already stripped by the caller).
-- @return list of { uuid, transaction_date, description, amount, category, hmrc_category, field }
function Aggregator.credit_offenders(opts, fields)
    opts = opts or {}
    if not opts.user_id or type(fields) ~= "table" or #fields == 0 then return {} end
    local start_date, end_date = Aggregator.tax_year_bounds(opts.tax_year)
    if not start_date then return {} end

    local field_list = {}
    for _, f in ipairs(fields) do
        if f and f ~= "" then table.insert(field_list, db.escape_literal(f)) end
    end
    if #field_list == 0 then return {} end

    local rows = db.query([[
        SELECT t.uuid, t.transaction_date, t.description, t.amount,
               t.category, t.hmrc_category, h.mtd_field_name AS field
        FROM tax_transactions t
        JOIN tax_hmrc_categories h ON t.hmrc_category = h.key AND h.is_active = true
        WHERE t.user_id = ?
          AND t.transaction_date >= ? AND t.transaction_date <= ?
          AND t.transaction_type = 'CREDIT'
          AND h.mtd_section = 'periodExpenses'
          AND h.mtd_field_name IN (]] .. table.concat(field_list, ", ") .. [[)
          AND t.classification_status IN (']] .. "CLASSIFIED" .. [[', ']] .. "CONFIRMED" .. [[')
        ORDER BY t.amount DESC
    ]], opts.user_id, start_date, end_date)
    return rows or {}
end

return Aggregator
