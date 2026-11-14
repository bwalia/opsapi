-- Our estimate vs HMRC's calculation, line by line.
--
-- OpsAPI shows its own estimate (lib/tax-calc via TaxTools.estimate) from the first
-- statement; HMRC calculates the official figure (Individual Calculations API) once
-- the figures are sent. They can differ: HMRC holds things we may not (a job, a
-- pension, savings, losses or finance costs carried forward, tax already deducted),
-- or our calculator can be wrong. compare() lines the two up so the person (or their
-- accountant) can see where and why. HMRC's figure is the one the return is filed on.
--
-- HMRC paths are from the Individual Calculations API v8 retrieve response
-- (calculation.taxCalculation.incomeTax.*, calculation.incomeSummaryTotals.*,
-- calculation.allowancesAndDeductions.*, calculation.reliefs.residentialFinanceCosts.*).

local Delta = {}

-- A difference smaller than this is rounding.
Delta.TOLERANCE = 1.0

-- HMRC's test service fills some fields with -99999999999.99: a placeholder, not a
-- figure. Treat it as missing so it's shown as "—", never compared.
Delta.PLACEHOLDER = -99999999999

local function num(x)
    local n = tonumber(x)
    if n == nil or n ~= n or n <= Delta.PLACEHOLDER then return nil end
    return n
end

-- dig(t, "a", "b") or dig(t, { "a", "b" })
local function dig(t, ...)
    local path = { ... }
    if type(path[1]) == "table" then path = path[1] end
    for _, k in ipairs(path) do
        if type(t) ~= "table" then return nil end
        t = t[k]
    end
    return t
end

local function first(...)
    for i = 1, select("#", ...) do
        local v = num((select(i, ...)))
        if v ~= nil then return v end
    end
    return nil
end

local REASON = {
    income = "HMRC may hold income we don't: a job or pension (PAYE), bank interest, dividends, "
        .. "or different business/property figures from another submission. See HMRC's income "
        .. "sources below.",
    property = "HMRC works out the property profit from the figures submitted for the UK property "
        .. "business; a difference usually means a different set of rents or expenses was sent, "
        .. "or HMRC applied the property allowance or losses brought forward.",
    trading = "HMRC works out the self-employment profit from the business submissions, after any "
        .. "adjustments or losses brought forward.",
    employment = "Employment income comes from your employer's PAYE records, which we don't see.",
    allowance = "The Personal Allowance falls by £1 for every £2 of income over £100,000 (gone at "
        .. "£125,140). HMRC may also apply Marriage Allowance or Blind Person's Allowance.",
    taxable = "Taxable income is income minus allowances, so it follows the lines above.",
    tax_charged = "Different taxable income, or different rates (Scottish or Welsh taxpayers), or "
        .. "Gift Aid / pension contributions extending the basic-rate band.",
    finance = "The 20% credit is on the lowest of: residential finance costs, property profit, and "
        .. "income above the Personal Allowance. HMRC also adds finance costs carried forward from "
        .. "earlier years.",
    tax_due = "Income tax after reliefs: follows the tax charged and the finance-cost credit.",
    class4 = "Class 4 National Insurance is on self-employment profit only (not rent).",
    class2 = "Class 2 National Insurance: voluntary from 2024-25 for most people.",
    total = "The total also includes anything HMRC adds that we don't estimate: student loan "
        .. "repayments, the High Income Child Benefit Charge, pension savings charges, or tax "
        .. "already paid at source.",
}

--- Pull the comparable lines out of HMRC's retrieved calculation (the full response).
function Delta.hmrc_lines(calc)
    local c = (type(calc) == "table" and (calc.calculation or calc)) or {}
    local tc = c.taxCalculation or {}
    local it = tc.incomeTax or {}
    local ist = c.incomeSummaryTotals or {}
    local ad = c.allowancesAndDeductions or {}
    local nics = tc.nics or {}
    return {
        total_income = first(it.totalIncomeReceivedFromAllSources),
        property_profit = first(ist.totalUKPropertyProfit),
        trading_profit = first(ist.totalSelfEmploymentProfit),
        employment = first(ist.totalEmploymentIncome),
        personal_allowance = first(ad.reducedPersonalAllowance, ad.personalAllowance),
        taxable_income = first(it.totalTaxableIncome),
        income_tax_charged = first(it.incomeTaxCharged),
        finance_cost_reduction = first(dig(c, "reliefs", "residentialFinanceCosts",
            "totalResidentialFinanceCostsRelief")),
        income_tax_due = first(it.incomeTaxDueAfterReliefs, it.totalIncomeTaxDue),
        class4_nic = first(dig(nics, "class4Nics", "totalAmount"), nics.nic4Amount),
        class2_nic = first(dig(nics, "class2Nics", "amount"), nics.nic2Amount),
        total = first(tc.totalIncomeTaxAndNicsDue),
    }
end

--- The same lines from our estimate (TaxTools.estimate / compute_year result).
function Delta.our_lines(est)
    est = est or {}
    local sch = est.schedules or {}
    return {
        total_income = num(est.total_income),
        property_profit = num(sch.property_profit),
        trading_profit = num(sch.trading_profit),
        employment = num(sch.employment),
        personal_allowance = num(est.personal_allowance),
        taxable_income = num(est.total_taxable),
        income_tax_charged = num(est.income_tax_before_reductions),
        finance_cost_reduction = num(est.finance_cost_reduction),
        income_tax_due = num(est.income_tax_due),
        class4_nic = num(est.class4_nic),
        class2_nic = num(est.class2_nic),
        total = num(est.total_liability or est.total_tax_due),
    }
end

-- Display order, labels and the reason shown when a line differs.
Delta.ROWS = {
    { key = "total_income", label = "Total income", why = "income" },
    { key = "property_profit", label = "UK property profit", why = "property" },
    { key = "trading_profit", label = "Self-employment profit", why = "trading" },
    { key = "employment", label = "Employment income", why = "employment" },
    { key = "personal_allowance", label = "Personal Allowance", why = "allowance" },
    { key = "taxable_income", label = "Taxable income", why = "taxable" },
    { key = "income_tax_charged", label = "Income tax before reliefs", why = "tax_charged" },
    { key = "finance_cost_reduction", label = "Finance-cost credit (20%)", why = "finance" },
    { key = "income_tax_due", label = "Income tax due", why = "tax_due" },
    { key = "class4_nic", label = "Class 4 National Insurance", why = "class4" },
    { key = "class2_nic", label = "Class 2 National Insurance", why = "class2" },
    { key = "total", label = "Total tax and NI due", why = "total", is_total = true },
}

-- Charges and deductions in HMRC's calculation that our estimate doesn't model.
local EXTRAS = {
    { path = { "taxCalculation", "totalStudentLoansRepaymentAmount" }, label = "Student loan repayments" },
    { path = { "taxCalculation", "incomeTax", "highIncomeBenefitCharge", "amountDue" },
      label = "High Income Child Benefit Charge" },
    { path = { "taxCalculation", "incomeTax", "totalPensionSavingsTaxCharges" },
      label = "Pension savings tax charges" },
    { path = { "taxCalculation", "totalTaxDeducted" }, label = "Tax already deducted (PAYE etc.)" },
    { path = { "taxCalculation", "capitalGainsTax", "totalCapitalGainsTax" }, label = "Capital Gains Tax" },
    { path = { "taxCalculation", "incomeTax", "marriageAllowanceRelief" }, label = "Marriage Allowance relief" },
}

local function round2(x)
    if x == nil then return nil end
    if x >= 0 then return math.floor(x * 100 + 0.5) / 100 end
    return -math.floor(-x * 100 + 0.5) / 100
end

--- Compare our estimate with HMRC's calculation.
-- @param est   table  our estimate (TaxTools.estimate)
-- @param calc  table  HMRC's retrieved calculation (full response: metadata, calculation, messages)
-- @param opts  table? { sandbox = bool }
-- @return { rows = {...}, differs, total_delta, sandbox, income_sources, extras, messages }
function Delta.compare(est, calc, opts)
    opts = opts or {}
    local ours, hmrc = Delta.our_lines(est), Delta.hmrc_lines(calc)
    local rows, differs = {}, false
    for _, r in ipairs(Delta.ROWS) do
        local o, h = ours[r.key], hmrc[r.key]
        -- A line neither side has (e.g. employment for a landlord) is left out.
        if (o and o ~= 0) or (h and h ~= 0) or r.is_total then
            local delta = (o and h) and round2(h - o) or nil
            local row_differs = (o == nil) ~= (h == nil)
                or (delta ~= nil and math.abs(delta) >= Delta.TOLERANCE)
            if row_differs then differs = true end
            rows[#rows + 1] = {
                key = r.key, label = r.label, ours = o and round2(o), hmrc = h and round2(h),
                delta = delta, differs = row_differs, is_total = r.is_total or nil,
                why = row_differs and REASON[r.why] or nil,
            }
        end
    end

    local c = (type(calc) == "table" and (calc.calculation or calc)) or {}
    local sources = {}
    for _, b in ipairs(type(c.businessProfitAndLoss) == "table" and c.businessProfitAndLoss or {}) do
        sources[#sources + 1] = {
            type = b.incomeSourceType, name = b.incomeSourceName, id = b.incomeSourceId,
            income = num(b.totalIncome), expenses = num(b.totalExpenses),
            taxable_profit = first(b.taxableProfit, b.netProfit),
        }
    end
    local extras = {}
    for _, e in ipairs(EXTRAS) do
        local v = num(dig(c, e.path))
        if v and v ~= 0 then extras[#extras + 1] = { label = e.label, amount = round2(v) } end
    end

    local msgs = (type(calc) == "table" and (calc.messages or c.messages)) or {}
    local function texts(list)
        local out = {}
        for _, m in ipairs(type(list) == "table" and list or {}) do
            if m.text and m.text ~= "" then out[#out + 1] = { id = m.id, text = m.text } end
        end
        return out
    end

    local total_ours, total_hmrc = ours.total, hmrc.total
    return {
        rows = rows,
        differs = differs,
        total_delta = (total_ours and total_hmrc) and round2(total_hmrc - total_ours) or nil,
        sandbox = opts.sandbox == true,
        income_sources = sources,
        extras = extras,
        messages = { info = texts(msgs.info), warnings = texts(msgs.warnings), errors = texts(msgs.errors) },
    }
end

return Delta
