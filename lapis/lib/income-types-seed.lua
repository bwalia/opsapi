--[[
    Default "My Income" definitions for the 13 system income types that
    diy-tax-return-uk and opsapi share (income_types rows seeded by
    migrations/income-types-system.lua, dividend-panels, interest-panels,
    overseas-property-system and pension-payments-system).

    Pure data — applied by migrations/my-income-dynamic.lua only where a row still
    has an EMPTY field_schema (an admin's edits are never overwritten), and
    validated by spec/my-income-types_spec.lua. After seeding, administrators
    maintain everything from Tax → Income types; nothing here is read at runtime.

    Box references are to the 2024-25/2025-26 HMRC paper forms and are shown as
    guidance only. Tax rules (allowances, bands, Section 24) live in lib/tax-calc.
]]

local function money(key, label, opts)
    local f = { key = key, label = label, type = "currency" }
    for k, v in pairs(opts or {}) do f[k] = v end
    return f
end

local OWNERSHIP = {
    key = "ownership_share",
    label = "Your share of this property",
    type = "percentage",
    default = 100,
    role = "info",
    help = "If you own it on your own, leave this at 100%. If you own it jointly (for example "
        .. "50% with a spouse), enter the figures for the WHOLE property below and your share "
        .. "here — we work out your part.",
}

return {
    -- ------------------------------------------------------------------ salary
    {
        key = "salary",
        icon = "Briefcase",
        entity_type = "employment",
        entity_label = "job",
        help_text = "Add each job you had in the tax year (6 April to 5 April). Your P60 (or P45 if "
            .. "you left) shows your pay and the tax already taken off. Your employer's P11D lists "
            .. "any taxable benefits such as a company car or private medical insurance.",
        field_schema = { sections = {
            { key = "pay", title = "Pay and tax", help = "Copy these from your P60 or P45.", fields = {
                money("pay", "Pay from this job before tax", { role = "income", required = true,
                    hmrc_box = "SA102 box 1",
                    help = "Your gross pay for the year — on your P60 under 'Pay in this employment'. "
                        .. "Not your take-home pay." }),
                money("tax_taken_off", "UK tax taken off", { role = "tax_paid", hmrc_box = "SA102 box 2",
                    help = "On your P60 under 'Tax in this employment'." }),
                money("tips", "Tips and other payments not on your P60", { role = "income",
                    hmrc_box = "SA102 box 3" }),
            } },
            { key = "benefits", title = "Benefits and expenses",
                help = "Only if your employer gave you a P11D or you paid for work costs yourself.", fields = {
                money("benefits", "Taxable benefits (total from your P11D)", { role = "income",
                    hmrc_box = "SA102 boxes 9–16",
                    help = "Company car, fuel, private medical insurance, vouchers and so on. Leave "
                        .. "out any benefits your employer already 'payrolled' — they're in your pay." }),
                money("expenses", "Work expenses you paid and weren't paid back for", { role = "expense",
                    hmrc_box = "SA102 boxes 17–20",
                    help = "For example professional subscriptions, uniform cleaning or business "
                        .. "travel. Ordinary commuting doesn't count." }),
            } },
            { key = "details", title = "Employer details", fields = {
                { key = "paye_reference", label = "Employer's PAYE reference", type = "text",
                    placeholder = "123/AB45678", role = "info",
                    help = "On your P60 or payslip. Helps HMRC match this job." },
                { key = "left_in_year", label = "Did this job end during the tax year?", type = "boolean",
                    role = "info" },
                { key = "end_date", label = "Date it ended", type = "date", role = "info",
                    show_if = { field = "left_in_year", equals = true } },
            } },
        } },
        estimator_mapping = {
            { field = "pay", input = "employment_income" },
            { field = "tips", input = "employment_income" },
            { field = "benefits", input = "employment_income" },
            { field = "expenses", input = "employment_expenses" },
            { field = "tax_taken_off", input = "paye_deducted" },
        },
    },
    -- -------------------------------------------------------- self-employment
    {
        key = "self_employment",
        icon = "Store",
        entity_type = "business",
        entity_label = "business",
        help_text = "Add each business you run as a sole trader. Enter your takings and your "
            .. "allowable business costs for the tax year. If your takings are small, the £1,000 "
            .. "trading allowance may be better than claiming costs — the estimate uses whichever "
            .. "gives you the lower profit.",
        field_schema = { sections = {
            { key = "income", title = "Business income", fields = {
                money("turnover", "Takings, fees and sales", { role = "income", required = true,
                    hmrc_box = "SA103S box 9 / SA103F box 15",
                    help = "Everything your customers paid you for the year, before costs.",
                    prefill = { categories = { "sales_income", "consulting_income", "income_sales" },
                        direction = "credit" } }),
                money("other_business_income", "Other business income", { role = "income",
                    hmrc_box = "SA103S box 10 / SA103F box 16",
                    help = "For example grants or commission that isn't from your main trade." }),
            } },
            { key = "costs", title = "Allowable costs", fields = {
                money("expenses", "Allowable business expenses", { role = "expense",
                    hmrc_box = "SA103S box 20 / SA103F box 31",
                    help = "Costs that are only for the business: stock, materials, travel, phone, "
                        .. "insurance, accountancy fees… Not personal spending, and not the cost of "
                        .. "equipment you'll keep (that's capital allowances)." }),
                money("capital_allowances", "Capital allowances", { role = "expense",
                    hmrc_box = "SA103 capital allowances boxes",
                    help = "Tax relief for equipment, tools, vans and computers you bought for the "
                        .. "business. Most small businesses claim the full cost (Annual Investment "
                        .. "Allowance)." }),
            } },
        } },
        estimator_mapping = {
            { field = "turnover", input = "se_turnover" },
            { field = "other_business_income", input = "se_turnover" },
            { field = "expenses", input = "se_expenses" },
            { field = "capital_allowances", input = "se_capital_allowances" },
        },
    },
    -- ------------------------------------------------------------ dividends
    {
        key = "dividends",
        icon = "TrendingUp",
        help_text = "Dividends you received from shares in UK companies in the tax year, including "
            .. "from your own limited company. The first £500 is tax-free (dividend allowance).",
        field_schema = { sections = {
            { key = "dividends", title = "UK dividends", fields = {
                money("uk_dividends", "Total dividends from UK companies", { role = "income",
                    required = true, hmrc_box = "SA100 TR3 box 4",
                    help = "The amount you received — on your dividend vouchers or platform tax "
                        .. "summary. Don't add any tax credit.",
                    prefill = { categories = { "income_dividend" }, direction = "credit" } }),
            } },
        } },
        estimator_mapping = { { field = "uk_dividends", input = "dividends" } },
    },
    {
        key = "foreign_dividends",
        icon = "Globe",
        help_text = "Dividends from companies based outside the UK. Up to £2,000 in total can go on "
            .. "the main return; above that, or if you want to claim relief for foreign tax, it goes "
            .. "on the Foreign pages (SA106).",
        field_schema = { sections = {
            { key = "dividends", title = "Foreign dividends", fields = {
                money("gross", "Total foreign dividends (in pounds, before foreign tax)", {
                    role = "income", required = true, hmrc_box = "SA100 TR3 box 5 / SA106",
                    help = "Convert to pounds using the exchange rate on the date you were paid." }),
                money("foreign_tax", "Foreign tax taken off", { role = "info",
                    help = "Recorded for your return. Foreign Tax Credit Relief isn't in the estimate "
                        .. "yet, so the estimate may be slightly high." }),
            } },
        } },
        estimator_mapping = { { field = "gross", input = "dividends" } },
    },
    {
        key = "other_dividends",
        icon = "PieChart",
        help_text = "Dividend distributions from UK unit trusts, OEICs and other investment funds.",
        field_schema = { sections = {
            { key = "dividends", title = "Fund dividends", fields = {
                money("amount", "Total dividend distributions", { role = "income", required = true,
                    hmrc_box = "SA100 TR3 box 4",
                    help = "On your fund manager's annual tax voucher. Interest distributions "
                        .. "from bond funds belong under Bank interest instead." }),
            } },
        } },
        estimator_mapping = { { field = "amount", input = "dividends" } },
    },
    -- ------------------------------------------------------------- property
    {
        key = "rental",
        icon = "Home",
        entity_type = "property",
        entity_label = "property",
        help_text = "Add each UK property you let out. Enter the rent and the running costs for the "
            .. "tax year. Mortgage interest on a home you let is not a normal expense: it gets a 20% "
            .. "tax credit instead (Section 24), so it has its own box.",
        field_schema = { sections = {
            { key = "about", title = "About this property", fields = { OWNERSHIP } },
            { key = "income", title = "Rent", fields = {
                money("rents", "Rent and other income from this property", { role = "income",
                    required = true, hmrc_box = "SA105 box 20",
                    help = "All rent due for the year, before any agent's fees.",
                    prefill = { categories = { "rental_income", "income_rental" }, direction = "credit" } }),
            } },
            { key = "expenses", title = "Running costs",
                help = "Only costs of letting the property. Improvements (an extension, a new "
                    .. "kitchen that's better than the old one) aren't allowable here.", fields = {
                money("rates_insurance", "Rent, rates, insurance and ground rent", { role = "expense",
                    hmrc_box = "SA105 box 24" }),
                money("repairs", "Repairs and maintenance", { role = "expense", hmrc_box = "SA105 box 25" }),
                money("professional_fees", "Letting agent, legal and accountancy fees", { role = "expense",
                    hmrc_box = "SA105 box 27" }),
                money("services", "Services you provide, including wages", { role = "expense",
                    hmrc_box = "SA105 box 28",
                    help = "For example cleaning, gardening or utilities you pay for the tenant." }),
                money("other_expenses", "Other allowable costs", { role = "expense",
                    hmrc_box = "SA105 box 29",
                    help = "For example travel to the property, phone calls, replacing furniture." }),
                money("commercial_finance", "Interest on loans for COMMERCIAL property", {
                    role = "expense", hmrc_box = "SA105 box 26",
                    help = "Only for shops, offices and other non-residential lets — that interest "
                        .. "is still a normal expense." }),
            } },
            { key = "finance", title = "Mortgage interest on a home you let", fields = {
                money("residential_finance_costs", "Residential mortgage interest and finance fees", {
                    role = "relief", hmrc_box = "SA105 box 44",
                    help = "The INTEREST only — not the capital you paid back. Your lender's annual "
                        .. "statement shows it. You get 20% of this back as a tax credit." }),
            } },
        } },
        estimator_mapping = {
            { field = "rents", input = "property_rents", scale_by = "ownership_share" },
            { field = "rates_insurance", input = "property_expenses", scale_by = "ownership_share" },
            { field = "repairs", input = "property_expenses", scale_by = "ownership_share" },
            { field = "professional_fees", input = "property_expenses", scale_by = "ownership_share" },
            { field = "services", input = "property_expenses", scale_by = "ownership_share" },
            { field = "other_expenses", input = "property_expenses", scale_by = "ownership_share" },
            { field = "commercial_finance", input = "property_expenses", scale_by = "ownership_share" },
            { field = "residential_finance_costs", input = "property_finance_costs",
                scale_by = "ownership_share" },
        },
    },
    {
        key = "overseas_property",
        icon = "Plane",
        entity_type = "overseas_property",
        entity_label = "property abroad",
        help_text = "Property you let outside the UK goes on the Foreign pages (SA106). Convert "
            .. "figures to pounds. If you paid tax abroad on the rent you may be able to claim "
            .. "Foreign Tax Credit Relief — that isn't in the estimate yet.",
        field_schema = { sections = {
            { key = "about", title = "About this property", fields = {
                { key = "country", label = "Country", type = "text", role = "info", required = true },
                OWNERSHIP,
            } },
            { key = "income", title = "Rent", fields = {
                money("rents", "Rent and other income (in pounds)", { role = "income", required = true,
                    hmrc_box = "SA106 box 14" }),
            } },
            { key = "expenses", title = "Costs", fields = {
                money("expenses", "Allowable running costs (in pounds)", { role = "expense",
                    hmrc_box = "SA106 box 24",
                    help = "Repairs, agent's fees, insurance and so on. Not residential mortgage "
                        .. "interest — that has its own box." }),
                money("residential_finance_costs", "Residential mortgage interest (in pounds)", {
                    role = "relief", hmrc_box = "SA106 box 24A",
                    help = "Interest only, not capital. Gets a 20% tax credit like UK property." }),
                money("foreign_tax", "Foreign tax paid on this income", { role = "info",
                    help = "Recorded for your return; relief for it isn't in the estimate yet." }),
            } },
        } },
        estimator_mapping = {
            { field = "rents", input = "property_rents", scale_by = "ownership_share" },
            { field = "expenses", input = "property_expenses", scale_by = "ownership_share" },
            { field = "residential_finance_costs", input = "property_finance_costs",
                scale_by = "ownership_share" },
        },
    },
    -- ------------------------------------------------------------- interest
    {
        key = "interest",
        icon = "PiggyBank",
        help_text = "Interest from UK bank and building society accounts, savings bonds and similar. "
            .. "Most people pay no tax on it: the Personal Savings Allowance covers £1,000 for "
            .. "basic-rate taxpayers (£500 for higher rate). ISA interest is tax-free — leave it out.",
        field_schema = { sections = {
            { key = "interest", title = "UK interest", fields = {
                money("uk_interest", "Total interest from UK accounts", { role = "income", required = true,
                    hmrc_box = "SA100 TR3 box 2",
                    help = "Your bank's annual interest statement shows it. Don't include ISAs.",
                    prefill = { categories = { "interest_income", "income_interest" }, direction = "credit" } }),
            } },
        } },
        estimator_mapping = { { field = "uk_interest", input = "savings_interest" } },
    },
    {
        key = "foreign_interest",
        icon = "Landmark",
        help_text = "Interest from bank accounts outside the UK, converted to pounds. Up to £2,000 "
            .. "can go on the main return; above that it goes on the Foreign pages (SA106).",
        field_schema = { sections = {
            { key = "interest", title = "Foreign interest", fields = {
                money("gross", "Total foreign interest (in pounds, before foreign tax)", {
                    role = "income", required = true, hmrc_box = "SA100 TR3 box 3 / SA106" }),
                money("foreign_tax", "Foreign tax taken off", { role = "info",
                    help = "Recorded for your return; relief for it isn't in the estimate yet." }),
            } },
        } },
        estimator_mapping = { { field = "gross", input = "savings_interest" } },
    },
    -- ------------------------------------------------------------- pensions
    {
        key = "pension",
        icon = "Sunrise",
        help_text = "Your State Pension and any private or workplace pensions you were paid in the "
            .. "tax year. Your pension provider's P60 shows the amount and tax taken off.",
        field_schema = { sections = {
            { key = "pensions", title = "Pension income", fields = {
                money("state_pension", "State Pension received", { role = "income",
                    hmrc_box = "SA100 TR3 box 8",
                    help = "The yearly total — the Department for Work and Pensions letter shows it." }),
                money("private_pensions", "Private and workplace pensions (before tax)", {
                    role = "income", hmrc_box = "SA100 TR3 box 11",
                    help = "Add up the gross amounts on the P60s from your pension providers." }),
                money("tax_taken_off", "Tax taken off your pensions", { role = "tax_paid",
                    hmrc_box = "SA100 TR3 box 12" }),
            } },
        } },
        estimator_mapping = {
            { field = "state_pension", input = "pension_income" },
            { field = "private_pensions", input = "pension_income" },
            { field = "tax_taken_off", input = "tax_deducted_at_source" },
        },
    },
    {
        key = "pension_payments",
        icon = "ShieldCheck",
        help_text = "Payments YOU made into a personal pension. This isn't income — it can lower "
            .. "your tax. Most personal pensions use 'relief at source': you pay £80 and the provider "
            .. "adds £20. Higher-rate taxpayers claim the extra relief here.",
        field_schema = { sections = {
            { key = "payments", title = "Pension payments", fields = {
                money("relief_at_source_net", "Payments where your provider added basic-rate tax relief",
                    { role = "relief", hmrc_box = "SA100 TR4 box 1",
                      help = "The amount you actually paid (for example £80, not £100). Leave out "
                        .. "workplace pension deductions taken from your pay before tax." }),
            } },
        } },
        estimator_mapping = { { field = "relief_at_source_net", input = "pension_ras" } },
    },
    -- ------------------------------------------------------------ capital gains
    {
        key = "capital_gains",
        icon = "BarChart3",
        estimate_note = "Capital Gains Tax is worked out separately and isn't in this estimate yet.",
        help_text = "Gains from selling or giving away things like shares, a second home or crypto. "
            .. "Each person has a small tax-free annual exempt amount. Selling your own main home "
            .. "is usually exempt.",
        field_schema = { sections = {
            { key = "gains", title = "Disposals in the tax year", fields = {
                { key = "disposals", label = "Number of disposals", type = "number", min = 0, role = "info" },
                money("proceeds", "Total sale proceeds", { role = "info", hmrc_box = "SA108" }),
                money("gains", "Total gains before losses", { role = "income", hmrc_box = "SA108" }),
                money("losses", "Losses in the year", { role = "expense", hmrc_box = "SA108" }),
            } },
        } },
        estimator_mapping = {},
    },
    -- ------------------------------------------------------------------ other
    {
        key = "other",
        icon = "Wallet",
        help_text = "Taxable income that doesn't fit anywhere else — for example casual earnings, "
            .. "commission or small one-off jobs that aren't a business.",
        field_schema = { sections = {
            { key = "other", title = "Other income", fields = {
                { key = "description", label = "What was it?", type = "text", role = "info",
                    placeholder = "e.g. Commission from a one-off referral" },
                money("amount", "Amount received", { role = "income", required = true,
                    hmrc_box = "SA100 TR3 box 17" }),
                money("expenses", "Allowable costs of earning it", { role = "expense",
                    hmrc_box = "SA100 TR3 box 18" }),
                money("tax_taken_off", "Tax already taken off", { role = "tax_paid",
                    hmrc_box = "SA100 TR3 box 19" }),
            } },
        } },
        estimator_mapping = {
            { field = "amount", input = "other_income" },
            { field = "expenses", input = "other_income", sign = -1 },
            { field = "tax_taken_off", input = "tax_deducted_at_source" },
        },
    },
}
