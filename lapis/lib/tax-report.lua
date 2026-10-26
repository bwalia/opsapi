--[[
    Tax calculation report — the figures a taxpayer (or our accountant) files from.

    TaxReport.build(ctx) gathers, for one user + tax year:
      * the deterministic estimate (lib/agent/tax-tools compute_estimate → lib/tax-calc),
      * per-HMRC-box totals (SA103F box + MTD field name — what you re-key into My Tax
        Digital or any other HMRC-recognised software), reconciling to the estimate,
      * the transactions behind them (the audit trail).
    TaxReport.hash(report) fingerprints the money figures, so a filing request can
    refuse to go ahead if they changed after the customer reviewed them.
    TaxReport.xlsx(report, opts) renders the workbook via lib/xlsx.

    The NINO and UTR are deliberately NOT in the report or the workbook: a spreadsheet
    gets emailed and stored around, and identity is checked separately (as in diy).

    Money in / out uses the SAME rules as compute_estimate, so every box reconciles:
      income   = credits, except those classified into a non-business category
                 (transfer, loan, drawings, personal — a category with no HMRC box)
      expenses = debits the classifier marked allowable (is_tax_deductible)
]]

local db = require("lapis.db")
local TaxTools = require("lib.agent.tax-tools")
local Xlsx = require("lib.xlsx")

local TaxReport = {}

local function num(v) return tonumber(v) or 0 end
local function r2(v)
    v = num(v)
    local s = v < 0 and -1 or 1
    return s * math.floor(math.abs(v) * 100 + 0.5) / 100
end

-- "15" < "16" < "20" < "20a" < "21" … (numeric part first, then the letter suffix).
local function box_order(box)
    box = tostring(box or "")
    local n, suffix = box:match("^(%d+)(%a*)$")
    if not n then return 9999 end
    return tonumber(n) * 10 + (suffix ~= "" and (suffix:lower():byte() - 96) or 0)
end

--- Income types the customer gave the tax agent for this year (latest chat), else
-- self-employment — the same profile compute_estimate routes income with.
function TaxReport.profile_for(namespace_id, user_id, tax_year)
    return TaxTools.profile_for(user_id, tax_year, namespace_id)
end

--- Gather the report. ctx: { namespace_id, user_id, tax_year, has_permission(m, a) }
-- @return report | nil, err
function TaxReport.build(ctx)
    local profile = TaxReport.profile_for(ctx.namespace_id, ctx.user_id, ctx.tax_year)
    local est, err = TaxTools.execute({
        namespace_id = ctx.namespace_id, user_id = ctx.user_id, tax_year = ctx.tax_year,
        _profile = profile, has_permission = ctx.has_permission,
    }, "compute_estimate", { tax_year = ctx.tax_year })
    if not est then return nil, err end

    local user = db.query("SELECT first_name, last_name, email FROM users WHERE id = ? LIMIT 1", ctx.user_id)[1] or {}
    local name = ((user.first_name or "") .. " " .. (user.last_name or "")):gsub("^%s+", ""):gsub("%s+$", "")

    local cats = {}
    for _, c in ipairs(db.query("SELECT key, label, hmrc_category_id FROM tax_categories WHERE is_active = true")) do
        if not cats[c.key] then cats[c.key] = { label = c.label, non_business = c.hmrc_category_id == nil } end
    end
    local hmrc = {}
    for _, h in ipairs(db.query([[SELECT key, box, label, mtd_field_name, mtd_section
        FROM tax_hmrc_categories WHERE is_active = true]])) do
        hmrc[h.key] = h
    end

    local txns = db.query([[
        SELECT t.transaction_date, t.description, t.amount, t.transaction_type, t.category,
               t.hmrc_category, t.is_tax_deductible, t.classification_status
        FROM tax_transactions t JOIN tax_statements s ON s.id = t.statement_id
        WHERE t.user_id = ? AND s.tax_year = ?
        ORDER BY t.transaction_date ASC, t.id ASC]], ctx.user_id, ctx.tax_year)

    local boxes, rows = {}, {}
    local other_in, excluded_in, unmapped_out, unreviewed, confirmed = 0, 0, 0, 0, 0
    local function box_row(key)
        local h = hmrc[key]
        if not boxes[key] then
            boxes[key] = { key = key, box = h.box, item = h.label, mtd_field = h.mtd_field_name,
                section = h.mtd_section, amount = 0, disallowable = 0, count = 0 }
        end
        return boxes[key]
    end

    for _, t in ipairs(txns) do
        local amt = num(t.amount)
        local credit = t.transaction_type == "CREDIT"
        local cat = cats[t.category]
        local h = t.hmrc_category and hmrc[t.hmrc_category]
        local deductible = t.is_tax_deductible == true or t.is_tax_deductible == "t"
        local treatment
        if credit then
            if cat and cat.non_business then
                excluded_in = excluded_in + amt
                treatment = "Not income (excluded)"
            elseif h and h.mtd_section == "periodIncome" then
                local b = box_row(t.hmrc_category); b.amount = b.amount + amt; b.count = b.count + 1
                treatment = "Income"
            else
                other_in = other_in + amt
                treatment = "Income (check)"
            end
        elseif deductible then
            if h then
                local b = box_row(t.hmrc_category); b.amount = b.amount + amt; b.count = b.count + 1
            else
                unmapped_out = unmapped_out + amt
            end
            treatment = "Allowable expense"
        else
            if h and h.mtd_section ~= "periodIncome" then
                local b = box_row(t.hmrc_category); b.disallowable = b.disallowable + amt; b.count = b.count + 1
            end
            treatment = "Not allowable"
        end
        if t.classification_status == "NEEDS_REVIEW" or t.classification_status == "PENDING" then
            unreviewed = unreviewed + 1
        elseif t.classification_status == "CONFIRMED" then
            confirmed = confirmed + 1
        end
        rows[#rows + 1] = {
            date = t.transaction_date and tostring(t.transaction_date):sub(1, 10) or "",
            description = t.description or "",
            money_in = credit and r2(amt) or nil,
            money_out = (not credit) and r2(amt) or nil,
            category = (cat and cat.label) or t.category or "",
            box = h and h.box or "",
            treatment = treatment,
            status = (t.classification_status == "NEEDS_REVIEW" and "Needs review")
                or (t.classification_status == "PENDING" and "Not classified") or "Classified",
        }
    end

    local box_list = {}
    for _, b in pairs(boxes) do
        b.amount, b.disallowable = r2(b.amount), r2(b.disallowable)
        box_list[#box_list + 1] = b
    end
    table.sort(box_list, function(a, b)
        local ia, ib = a.section == "periodIncome" and 0 or 1, b.section == "periodIncome" and 0 or 1
        if ia ~= ib then return ia < ib end
        return box_order(a.box) < box_order(b.box)
    end)

    local types = profile.income_types
    local property_only = #types > 0
    for _, ty in ipairs(types) do if ty ~= "uk_property" then property_only = false end end

    return {
        tax_year = ctx.tax_year,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        taxpayer = { name = name ~= "" and name or (user.email or ""), email = user.email or "" },
        income_types = types,
        property_only = property_only,
        summary = {
            income = r2(est.gross_income), expenses = r2(est.total_expenses), profit = r2(est.profit),
            total_income = r2(est.total_income), personal_allowance = r2(est.personal_allowance),
            taxable_income = r2(est.taxable_income or est.total_taxable),
            income_tax = r2(est.income_tax_due), class4_nic = r2(est.class4_nic), class2_nic = r2(est.class2_nic),
            total_tax_and_nic = r2(est.total_liability), tax_already_paid = r2(est.paye_deducted),
            balancing_payment = r2(est.balancing_payment), payment_on_account = r2(est.payment_on_account_each),
            total_due_31_jan = r2(est.total_due_31_jan),
        },
        boxes = box_list,
        totals = {
            other_money_in = r2(other_in), excluded_money_in = r2(excluded_in),
            unmapped_expenses = r2(unmapped_out), transactions = #txns, unreviewed = unreviewed,
            confirmed = confirmed,
        },
        transactions = rows,
    }
end

--- Fingerprint of the money figures (what the customer approves). Stable across
-- re-classifications that don't move any total.
function TaxReport.hash(report)
    local s, parts = report.summary or {}, { tostring(report.tax_year) }
    for _, k in ipairs({ "income", "expenses", "profit", "total_tax_and_nic", "total_due_31_jan" }) do
        parts[#parts + 1] = ("%s=%.2f"):format(k, num(s[k]))
    end
    for _, b in ipairs(report.boxes or {}) do
        parts[#parts + 1] = ("%s=%.2f/%.2f"):format(tostring(b.box), num(b.amount), num(b.disallowable))
    end
    local sha = require("resty.sha256"):new()
    sha:update(table.concat(parts, "|"))
    return require("resty.string").to_hex(sha:final())
end

-- ---------------------------------------------------------------------------
-- Workbook
-- ---------------------------------------------------------------------------

local function m(v) return { r2(v), style = "money" } end
local function mb(v) return { r2(v), style = "money_bold" } end
local function b(text) return { text, style = "bold" } end
local function h(text) return { text, style = "header" } end

local TYPE_LABEL = {
    self_employment = "Self-employment", uk_property = "UK property", employment = "Employment",
    dividends = "Dividends", savings_interest = "Savings interest", other = "Other income",
}

--- Render the report as .xlsx bytes.
-- opts: { approved_at = ISO string|nil, for_accountant = bool }
function TaxReport.xlsx(report, opts)
    opts = opts or {}
    local s, t = report.summary or {}, report.totals or {}
    local y1 = tonumber(tostring(report.tax_year):sub(1, 4)) or 0
    local types = {}
    for _, ty in ipairs(report.income_types or {}) do types[#types + 1] = TYPE_LABEL[ty] or ty end

    local summary = {
        { { "Tax return figures " .. tostring(report.tax_year), style = "title" } },
        { "Taxpayer", report.taxpayer and report.taxpayer.name or "" },
        { "Email", report.taxpayer and report.taxpayer.email or "" },
        { "Tax year", ("%s (6 April %d to 5 April %d)"):format(tostring(report.tax_year), y1, y1 + 1) },
        { "Income type(s)", table.concat(types, ", ") },
        { "Approved by the taxpayer", opts.approved_at or "Not yet approved" },
        { "Prepared", tostring(report.generated_at) .. " (UTC)" },
        {},
        { b(report.property_only and "UK property (SA105)" or "Self-employment (SA103F)") },
        { report.property_only and "Rents received" or "Turnover (money in)", m(s.income) },
        { "Allowable expenses", m(s.expenses) },
        { b(report.property_only and "Property profit" or "Net profit"), mb(s.profit) },
        {},
        { b("Tax calculation") },
        { "Total income", m(s.total_income) },
        { "Personal allowance", m(s.personal_allowance) },
        { "Taxable income", m(s.taxable_income) },
        { "Income Tax due", m(s.income_tax) },
        { "Class 4 National Insurance", m(s.class4_nic) },
        { "Class 2 National Insurance", m(s.class2_nic) },
        { b("Total Income Tax and NICs due"), mb(s.total_tax_and_nic) },
        { "Tax already paid (PAYE and at source)", m(s.tax_already_paid) },
        { "Balance due (negative = repayment)", m(s.balancing_payment) },
        { "Each payment on account", m(s.payment_on_account) },
        { b("Total due by 31 January"), mb(s.total_due_31_jan) },
        {},
        { b("Notes") },
    }
    local function note(text) summary[#summary + 1] = { text } end
    if num(t.unreviewed) > 0 then
        note(("%d transaction(s) are still flagged for review — check them before filing."):format(num(t.unreviewed)))
    end
    if num(t.other_money_in) > 0 then
        note(("£%.2f of money in is unclassified or sits in an expense category (a refund?) — it is counted "
            .. "as income; confirm before filing."):format(num(t.other_money_in)))
    end
    if num(t.excluded_money_in) > 0 then
        note(("£%.2f of money in was treated as NOT income (transfers, loans, personal) — see the "
            .. "Transactions sheet."):format(num(t.excluded_money_in)))
    end
    note("Figures are built from classified bank transactions. All amounts are in pounds sterling (£).")
    note("This is an estimate — HMRC's own calculation is the one that counts.")
    note("The National Insurance number and UTR are deliberately not included in this file.")
    if opts.for_accountant then
        note("Filing: re-key the Boxes sheet into My Tax Digital (or other HMRC-recognised software); "
            .. "each line gives the SA103F box and the MTD field name.")
    end

    local SECTION = { periodIncome = "Income", periodExpenses = "Expenses" }
    local boxes = { { h("Form"), h("Box"), h("Section"), h("Item"), h("MTD field"), h("Amount"),
        h("Disallowable"), h("Transactions") } }
    for _, bx in ipairs(report.boxes or {}) do
        boxes[#boxes + 1] = { "SA103F", tostring(bx.box or ""), SECTION[bx.section] or "Allowances",
            bx.item or "", bx.mtd_field or "", m(bx.amount), num(bx.disallowable) ~= 0 and m(bx.disallowable) or nil,
            num(bx.count) }
    end
    if num(t.other_money_in) ~= 0 then
        boxes[#boxes + 1] = { "", "", "Income", "Other money in (unclassified or refund — check)", "",
            m(t.other_money_in) }
    end
    if num(t.unmapped_expenses) ~= 0 then
        boxes[#boxes + 1] = { "", "", "Expenses", "Allowable expenses with no HMRC box (check)", "",
            m(t.unmapped_expenses) }
    end
    boxes[#boxes + 1] = {}
    boxes[#boxes + 1] = { nil, nil, nil, b("Total income"), nil, mb(s.income) }
    boxes[#boxes + 1] = { nil, nil, nil, b("Total allowable expenses"), nil, mb(s.expenses) }
    boxes[#boxes + 1] = { nil, nil, nil, b("Net profit"), nil, mb(s.profit) }

    local tx = { { h("Date"), h("Description"), h("Money in"), h("Money out"), h("Category"), h("Box"),
        h("Treatment"), h("Status") } }
    for _, r in ipairs(report.transactions or {}) do
        tx[#tx + 1] = { r.date, r.description, r.money_in and m(r.money_in) or nil,
            r.money_out and m(r.money_out) or nil, r.category, r.box, r.treatment, r.status }
    end

    return Xlsx.build({
        { name = "Summary", widths = { 46, 30 }, rows = summary },
        { name = "Boxes", widths = { 8, 6, 11, 46, 28, 14, 14, 13 }, rows = boxes },
        { name = "Transactions", widths = { 12, 46, 13, 13, 28, 6, 22, 14 }, rows = tx },
    })
end

--- A safe download filename, e.g. tax-calculation-2025-26-Jane-Smith.xlsx
function TaxReport.filename(report, who)
    local base = "tax-calculation-" .. tostring(report.tax_year)
    who = tostring(who or ""):gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return (who ~= "" and (base .. "-" .. who) or base) .. ".xlsx"
end

return TaxReport
