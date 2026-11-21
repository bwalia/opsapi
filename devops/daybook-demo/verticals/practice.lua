-- Vertical "practice": Harbour & Lane Accountants and clients C1–C6
-- (docs/plans/DAYBOOK_DEMO_SPEC.md). Everything here is fictional.
--
-- A vertical file returns DATA plus small generator functions. It never touches the
-- database. seed-daybook.lua makes the workspace and people from it;
-- seed-daybook-data.lua turns each client's generator output into bank accounts,
-- statements, classified transactions, the AI-assistant profile, VAT and the
-- accountant's filing queue.
--
-- Generator contract: generate(G, add, year), where:
--   G    helpers: G.months(year) → { {y,m}, … } April..March;
--        G.day(y, m, d) → "YYYY-MM-DD" (clamped to the month);
--        G.rng(seed) → r with r:int(a,b), r:money(lo,hi), r:pick(list), r:chance(p).
--   add  add{ acct, date, desc, amount (>0), dir = "CREDIT"|"DEBIT", cat, conf?, by?,
--            status? = "confirmed"|"classified"|"review"|"resolved", reason?, note?,
--            deductible? (overrides the category default), business? (bool),
--            vat? = { code, source, conf, reason } | { review = true, reasons = {…} } }
--   year the tax year being generated, e.g. "2025-26".
-- The same seed and year always give the same lines, so every reset gives the same demo.

local TAX_YEAR = "2025-26"

local function last_year_of(year)
    local a = tonumber(year:sub(1, 4)) - 1
    return string.format("%d-%02d", a, (a + 1) % 100)
end

---------------------------------------------------------------------------
-- C1 Jordan Hale: 100 residential lets through four letting agents.
-- 275 lines a year: 4 rents + 4 agent fees + 4 mortgages + insurance + a transfer
-- to Jordan's personal account each month (168), 100 repairs, 7 one-offs.
---------------------------------------------------------------------------
local C1_AGENTS = { -- name, houses, average rent, fee rate (incl. VAT)
    { "HARTWELL LETTINGS", 30, 1050, 0.12 },
    { "OAKRIDGE ESTATES", 28, 960, 0.12 },
    { "BRAMLEY HOMES", 22, 1640, 0.108 },
    { "FENWICK & CO LETTINGS", 20, 1200, 0.10 },
}
local C1_MORTGAGES = { -- lender, monthly payment (interest + capital), day
    { "BIRCHWOOD BUILDING SOCIETY BTL MORTGAGE", 16850.00, 1 },
    { "KINGSMEAD BTL MORTGAGE", 13420.00, 3 },
    { "HARROWGATE LENDING BTL MORTGAGE", 11780.00, 5 },
    { "CASTLEFORD HOMES BTL MORTGAGE", 14960.00, 8 },
}
local C1_REPAIRS = {
    { "PLUMBFAST LTD BOILER REPAIR", 280, 2400 }, { "SPARKWELL ELECTRICAL EICR", 180, 950 },
    { "GASSAFE CERTIFICATES LTD", 240, 1300 }, { "ROOFLINE REPAIRS LTD", 450, 3800 },
    { "DAMPGUARD SOLUTIONS", 600, 3400 }, { "GREENSWARD GARDEN MAINTENANCE", 150, 720 },
    { "KEYSTONE LOCKSMITHS", 95, 380 }, { "BRIGHTCOAT DECORATORS", 900, 4200 },
    { "ACE APPLIANCE REPAIRS", 120, 640 }, { "CLEARVIEW WINDOWS LTD REPAIR", 320, 2900 },
}

local function c1_generate(G, add, year)
    local r = G.rng(year == TAX_YEAR and 2526 or 2425)
    local this_year = (year == TAX_YEAR)
    -- 2025-26: 274 lines sorted from what Jordan confirmed in 2024-25, no AI call.
    -- 2024-25: everything confirmed by Jordan (that is what the AI learns from).
    local function learned(t)
        if this_year then
            t.by = "learned"; t.conf = t.conf or 0.99; t.status = "confirmed"
            t.reason = t.reason or ("Same as you confirmed in " .. last_year_of(year) .. ": " .. t.cat:gsub("_", " ") .. ".")
        else
            t.by = t.by or "rule_engine"; t.conf = t.conf or 0.93; t.status = "confirmed"
        end
        add(t)
    end
    for i, ym in ipairs(G.months(year)) do
        local y, m = ym[1], ym[2]
        for k, a in ipairs(C1_AGENTS) do
            local rent = a[2] * a[3] * (1 + (r:int(-15, 15) / 1000))
            learned{ acct = "main", date = G.day(y, m, 2 + k * 3), dir = "CREDIT", amount = rent,
                desc = a[1] .. " RENT REMITTANCE", cat = "rental_income",
                reason = this_year and nil or "Rent collected by a letting agent is rental income." }
            learned{ acct = "main", date = G.day(y, m, 3 + k * 3), dir = "DEBIT", amount = rent * a[4],
                desc = a[1] .. " MANAGEMENT FEE", cat = "professional_fees" }
        end
        for _, mg in ipairs(C1_MORTGAGES) do
            learned{ acct = "main", date = G.day(y, m, mg[3]), dir = "DEBIT", amount = mg[2],
                desc = mg[1], cat = "loan_repayments",
                reason = this_year and nil or "A mortgage payment mixes capital and interest; the interest is taken from the lender's annual statement." }
        end
        learned{ acct = "main", date = G.day(y, m, 15), dir = "DEBIT", amount = 1386.40,
            desc = "SIMPLY LANDLORD INSURANCE DD", cat = "premises_insurance" }
        learned{ acct = "main", date = G.day(y, m, 28), dir = "DEBIT", amount = 6000,
            desc = "TRANSFER TO J HALE PERSONAL", cat = "drawings" }
        for _ = 1, (i <= 4 and 9 or 8) do
            local rp = r:pick(C1_REPAIRS)
            learned{ acct = "main", date = G.day(y, m, r:int(1, 28)), dir = "DEBIT",
                amount = r:money(rp[2], rp[3]), desc = rp[1], cat = "repairs_property" }
        end
    end
    local a = tonumber(year:sub(1, 4))
    learned{ acct = "main", date = G.day(a, 5, 19), dir = "DEBIT", amount = 1140, desc = "ELMHURST EPC ASSESSMENTS", cat = "professional_fees" }
    learned{ acct = "main", date = G.day(a, 7, 31), dir = "DEBIT", amount = 96400, desc = "HMRC SELF ASSESSMENT PAYMENT", cat = "tax_payments" }
    learned{ acct = "main", date = G.day(a, 8, 14), dir = "DEBIT", amount = 2650, desc = "LANDLORD LAW SOLICITORS POSSESSION", cat = "legal_fees" }
    learned{ acct = "main", date = G.day(a, 10, 22), dir = "DEBIT", amount = 30, desc = "HM LAND REGISTRY", cat = "legal_fees" }
    learned{ acct = "main", date = G.day(a, 12, 22), dir = "DEBIT", amount = 7400, desc = "HARBOUR & LANE ACCOUNTANTS", cat = "accountancy_fees" }
    learned{ acct = "main", date = G.day(a + 1, 1, 30), dir = "DEBIT", amount = 168250, desc = "HMRC SELF ASSESSMENT PAYMENT", cat = "tax_payments" }
    if this_year then
        -- The one line nothing from last year matched: the AI was asked, flagged it,
        -- and Ade's review settled it before filing.
        add{ acct = "main", date = G.day(a + 1, 2, 17), dir = "DEBIT", amount = 7850,
            desc = "CLEARVIEW WINDOWS LTD NEW KITCHEN 14 MILL LANE", cat = "repairs_property",
            by = "agent", conf = 0.58, status = "resolved", deductible = false,
            reason = "A new kitchen could be a repair (like-for-like) or an improvement (capital). Not seen last year, so a person should decide.",
            note = "Ade Okoro: full refit with a layout change, so an improvement (capital), not a repair. Not allowable against rent; kept for the CGT base cost." }
    else
        learned{ acct = "main", date = G.day(a + 1, 2, 17), dir = "DEBIT", amount = 2180,
            desc = "CLEARVIEW WINDOWS LTD REPAIR", cat = "repairs_property" }
    end
end

---------------------------------------------------------------------------
-- C2 Priya Shah: two flats, one with a residential mortgage. ~60 lines, 3 flagged.
---------------------------------------------------------------------------
local function c2_generate(G, add, year)
    local r = G.rng(3101)
    local a = tonumber(year:sub(1, 4))
    for _, ym in ipairs(G.months(year)) do
        local y, m = ym[1], ym[2]
        add{ acct = "main", date = G.day(y, m, 1), dir = "CREDIT", amount = 1250, desc = "FP TENANT FLAT 3 12 MILL LANE RENT",
            cat = "rental_income", by = "rule_engine", conf = 0.97, reason = "Regular monthly payment referencing a flat: rent." }
        add{ acct = "main", date = G.day(y, m, 3), dir = "CREDIT", amount = 1100, desc = "FP TENANT FLAT 7 QUAY COURT RENT",
            cat = "rental_income", by = "rule_engine", conf = 0.97, reason = "Regular monthly payment referencing a flat: rent." }
        add{ acct = "main", date = G.day(y, m, 12), dir = "DEBIT", amount = 642.18, desc = "ALDERGATE BUILDING SOC MORTGAGE",
            cat = "loan_repayments", by = "rule_engine", conf = 0.96,
            reason = "Mortgage payment: capital is never deductible; the interest goes in as a finance cost (20% credit)." }
        if m % 3 == 1 then
            add{ acct = "main", date = G.day(y, m, 20), dir = "DEBIT", amount = 486, desc = "QUAY COURT MGMT SERVICE CHARGE",
                cat = "repairs_property", by = "agent", conf = 0.86, reason = "Service charge for a let flat: an allowable property cost." }
        end
    end
    local repairs = { { "PLUMBRIGHT 24HR", 95, 340 }, { "SAFEHOME GAS CERT", 75, 95 }, { "MILL LANE HANDYMAN", 60, 420 } }
    for i = 1, 10 do
        local rp = r:pick(repairs)
        add{ acct = "main", date = G.day(a + (i > 8 and 1 or 0), ((3 + i) % 12) + 1, r:int(2, 26)), dir = "DEBIT",
            amount = r:money(rp[2], rp[3]), desc = rp[1], cat = "repairs_property", by = "rule_engine", conf = 0.92 }
    end
    add{ acct = "main", date = G.day(a, 6, 2), dir = "DEBIT", amount = 312.40, desc = "DIRECT LINE LANDLORD INS", cat = "premises_insurance", by = "rule_engine", conf = 0.95 }
    add{ acct = "main", date = G.day(a, 11, 2), dir = "DEBIT", amount = 298.10, desc = "DIRECT LINE LANDLORD INS", cat = "premises_insurance", by = "rule_engine", conf = 0.95 }
    add{ acct = "main", date = G.day(a, 9, 9), dir = "DEBIT", amount = 214.00, desc = "BRISTOL CITY COUNCIL CTAX VOID", cat = "utilities", by = "agent", conf = 0.81,
        reason = "Council tax while the flat was empty between tenants is a property running cost." }
    add{ acct = "main", date = G.day(a, 9, 15), dir = "DEBIT", amount = 61.20, desc = "BRISTOL WATER VOID PERIOD", cat = "utilities", by = "agent", conf = 0.8 }
    add{ acct = "main", date = G.day(a, 7, 31), dir = "DEBIT", amount = 1840, desc = "HMRC SELF ASSESSMENT", cat = "tax_payments", by = "rule_engine", conf = 0.99 }
    add{ acct = "main", date = G.day(a + 1, 1, 29), dir = "DEBIT", amount = 2210, desc = "HMRC SELF ASSESSMENT", cat = "tax_payments", by = "rule_engine", conf = 0.99 }
    add{ acct = "main", date = G.day(a, 5, 20), dir = "DEBIT", amount = 540, desc = "HARBOUR & LANE ACCOUNTANTS", cat = "accountancy_fees", by = "rule_engine", conf = 0.96 }
    -- Flagged for the review queue.
    add{ acct = "main", date = G.day(a, 10, 14), dir = "DEBIT", amount = 4200, desc = "HENDRY KITCHENS LTD", cat = "repairs_property",
        by = "agent", conf = 0.52, status = "review",
        reason = "A kitchen supplier: replacing like-for-like is a repair, a better kitchen is an improvement (capital). Ask the client." }
    add{ acct = "main", date = G.day(a, 8, 3), dir = "DEBIT", amount = 186.45, desc = "B&Q 1123 BRISTOL", cat = "repairs_property",
        by = "agent", conf = 0.48, status = "review", reason = "DIY store: could be for a flat or for the client's own home." }
    add{ acct = "main", date = G.day(a, 12, 18), dir = "CREDIT", amount = 1500, desc = "TRANSFER FROM R SHAH", cat = "transfer",
        by = "agent", conf = 0.44, status = "review", reason = "Money in from a family name: a personal transfer, or rent paid by someone else? Check before excluding it." }
end

---------------------------------------------------------------------------
-- C3 Tom Reid: IT consultant, one mixed personal/business account, two half-year
-- statements. ~120 lines, 6 flagged (3 already corrected by Ade, 3 still open).
-- Also the demo login's own "sample book" (see viewer_book below).
---------------------------------------------------------------------------
local function c3_generate(G, add, year)
    local r = G.rng(4242)
    local a = tonumber(year:sub(1, 4))
    for _, ym in ipairs(G.months(year)) do
        local y, m = ym[1], ym[2]
        add{ acct = "main", date = G.day(y, m, 5), dir = "CREDIT", amount = r:money(6200, 7400),
            desc = "NORTHWIND DIGITAL LTD INV " .. string.format("%02d%02d", m, y % 100), cat = "consulting_income",
            by = "rule_engine", conf = 0.97, reason = "Payment from a client company quoting an invoice number: turnover." }
        if m % 2 == 0 then
            add{ acct = "main", date = G.day(y, m, 19), dir = "CREDIT", amount = r:money(1800, 2600),
                desc = "BLUEPEAK SYSTEMS PAYMENT", cat = "consulting_income", by = "agent", conf = 0.91 }
        end
        add{ acct = "main", date = G.day(y, m, 2), dir = "DEBIT", amount = 18.80, desc = "GITHUB INC", cat = "software_subscriptions", by = "rule_engine", conf = 0.98 }
        add{ acct = "main", date = G.day(y, m, 8), dir = "DEBIT", amount = r:money(22, 61), desc = "AWS EMEA", cat = "software_subscriptions", by = "rule_engine", conf = 0.97 }
        add{ acct = "main", date = G.day(y, m, 11), dir = "DEBIT", amount = 26.00, desc = "EE LIMITED", cat = "telephone", by = "rule_engine", conf = 0.94 }
        add{ acct = "main", date = G.day(y, m, 1), dir = "DEBIT", amount = 210.00, desc = "THE DESK SPACE COWORKING", cat = "rent_business", by = "agent", conf = 0.9 }
        add{ acct = "main", date = G.day(y, m, r:int(3, 26)), dir = "DEBIT", amount = r:money(48, 132), desc = "TESCO STORES 3021", cat = "personal_expense",
            by = "rule_engine", conf = 0.93, business = false, reason = "Supermarket food shop: personal, kept out of the business figures." }
        add{ acct = "main", date = G.day(y, m, 14), dir = "DEBIT", amount = 12.99, desc = "NETFLIX.COM", cat = "personal_expense", by = "rule_engine", conf = 0.96, business = false }
        if m % 2 == 1 then
            add{ acct = "main", date = G.day(y, m, r:int(5, 25)), dir = "DEBIT", amount = r:money(38, 96), desc = "TRAINLINE.COM", cat = "travel_transport", by = "agent", conf = 0.84,
                reason = "Rail tickets on weekdays near client invoices: business travel." }
        end
        if m % 2 == 0 then
            add{ acct = "main", date = G.day(y, m, 27), dir = "DEBIT", amount = 1000, desc = "TRANSFER TO T REID SAVINGS", cat = "transfer", by = "rule_engine", conf = 0.95, business = false }
        end
    end
    add{ acct = "main", date = G.day(a, 4, 30), dir = "DEBIT", amount = 189.00, desc = "JETBRAINS S.R.O.", cat = "software_subscriptions", by = "rule_engine", conf = 0.97 }
    add{ acct = "main", date = G.day(a, 5, 6), dir = "DEBIT", amount = 342.00, desc = "HISCOX PI INSURANCE", cat = "business_insurance", by = "rule_engine", conf = 0.95 }
    add{ acct = "main", date = G.day(a, 7, 31), dir = "DEBIT", amount = 4980, desc = "HMRC SELF ASSESSMENT", cat = "tax_payments", by = "rule_engine", conf = 0.99 }
    add{ acct = "main", date = G.day(a + 1, 1, 28), dir = "DEBIT", amount = 7120, desc = "HMRC SELF ASSESSMENT", cat = "tax_payments", by = "rule_engine", conf = 0.99 }
    add{ acct = "main", date = G.day(a, 11, 12), dir = "DEBIT", amount = 660, desc = "HARBOUR & LANE ACCOUNTANTS", cat = "accountancy_fees", by = "rule_engine", conf = 0.96 }
    -- Flagged: three already corrected by Ade, three still waiting.
    add{ acct = "main", date = G.day(a, 6, 21), dir = "DEBIT", amount = 1899, desc = "APPLE STORE R245", cat = "equipment_purchase",
        by = "agent", conf = 0.55, status = "resolved", reason = "A laptop-priced Apple purchase: business equipment or personal?",
        note = "Ade Okoro: MacBook used for client work (confirmed with Tom). Capital allowance (AIA), not an expense." }
    add{ acct = "main", date = G.day(a, 9, 4), dir = "DEBIT", amount = 64.20, desc = "AMAZON MKTP UK*2K4", cat = "personal_expense",
        by = "agent", conf = 0.41, status = "resolved", business = false, reason = "Amazon order with no detail: could be anything.",
        note = "Ade Okoro: Tom says birthday presents. Moved to personal." }
    add{ acct = "main", date = G.day(a, 10, 16), dir = "DEBIT", amount = 23.40, desc = "UBER *TRIP", cat = "travel_transport",
        by = "agent", conf = 0.5, status = "resolved", reason = "Taxi on a weekday: business travel if it was to a client.",
        note = "Ade Okoro: trip to the Northwind office. Business travel." }
    add{ acct = "main", date = G.day(a + 1, 1, 9), dir = "DEBIT", amount = 112.97, desc = "AMAZON MKTP UK*8H1", cat = "office_supplies",
        by = "agent", conf = 0.46, status = "review", reason = "Amazon order with no detail: office kit or personal shopping? Ask Tom." }
    add{ acct = "main", date = G.day(a + 1, 2, 12), dir = "DEBIT", amount = 14.85, desc = "PRET A MANGER", cat = "personal_expense",
        by = "agent", conf = 0.49, status = "review", business = false,
        reason = "Lunch is usually personal; it's only allowable when travelling away from the normal place of work." }
    add{ acct = "main", date = G.day(a + 1, 3, 3), dir = "DEBIT", amount = 249.00, desc = "CURRYS ONLINE", cat = "equipment_purchase",
        by = "agent", conf = 0.52, status = "review", reason = "Electronics retailer: a monitor for work, or a household item?" }
end

---------------------------------------------------------------------------
-- C4 Ellie Moss t/a Corner Cup Café: VAT-registered (standard, quarters to
-- Mar/Jun/Sep/Dec). ~390 lines, VAT-coded. Q1 filed, Q2 ready, Q3 open with 5
-- lines waiting for a decision.
---------------------------------------------------------------------------
local C4_FLAGGED = {
    { 10, 7, "AMAZON MKTP UK*4F2", 89.99, "Amazon order: could be stock, equipment or personal; the receipt shows the VAT." },
    { 10, 21, "MAKRO CARDIFF", 412.60, "Cash-and-carry receipt mixes zero-rated food and standard-rated items; split it from the receipt." },
    { 11, 8, "IKEA CARDIFF", 329.00, "Furniture: new café chairs (capital, reclaimable) or for home?" },
    { 11, 26, "AMAZON MKTP UK*9Q1", 46.50, "Amazon order with no VAT receipt yet." },
    { 12, 12, "CASH DEPOSIT CARDIFF", 640.00, "Cash paid in: café takings (standard-rated sales) or a personal deposit?" },
}

local function c4_generate(G, add, year)
    local r = G.rng(5150)
    local a = tonumber(year:sub(1, 4))
    local function v(code, source, conf, reason)
        return { code = code, source = source or "rule", conf = conf or 1, reason = reason }
    end
    for _, ym in ipairs(G.months(year)) do
        local y, m = ym[1], ym[2]
        for _, d in ipairs({ 2, 6, 9, 13, 16, 20, 23, 27 }) do -- twice-weekly card payouts
            add{ acct = "main", date = G.day(y, m, d), dir = "CREDIT", amount = r:money(1450, 2350),
                desc = "SUMUP PAYOUT", cat = "sales_income", by = "rule_engine", conf = 0.98,
                vat = v("STD20", "rule", 1, "Card takings for hot food and drinks: standard rated.") }
        end
        for _, d in ipairs({ 4, 11, 18, 25 }) do
            add{ acct = "main", date = G.day(y, m, d), dir = "DEBIT", amount = r:money(380, 690), desc = "BIDFOOD LTD",
                cat = "inventory_stock", by = "rule_engine", conf = 0.95,
                vat = v("ZERO", "ai", 0.88, "Food for resale (catering supplies): zero rated on the invoice.") }
            add{ acct = "main", date = G.day(y, m, d + 1), dir = "DEBIT", amount = r:money(92, 140), desc = "VALLEY DAIRIES MILK",
                cat = "inventory_stock", by = "rule_engine", conf = 0.96, vat = v("ZERO", "rule", 1, "Milk: zero rated.") }
        end
        for _, d in ipairs({ 8, 22 }) do
            add{ acct = "main", date = G.day(y, m, d), dir = "DEBIT", amount = r:money(240, 330), desc = "HILLTOP COFFEE ROASTERS",
                cat = "inventory_stock", by = "agent", conf = 0.93, vat = v("ZERO", "ai", 0.9, "Coffee beans are food: zero rated.") }
        end
        add{ acct = "main", date = G.day(y, m, 1), dir = "DEBIT", amount = 1500, desc = "PENARTH ESTATES RENT", cat = "rent_business",
            by = "rule_engine", conf = 0.97, vat = v("STD20", "rule", 1, "The landlord has opted to tax: VAT on the rent invoice.") }
        add{ acct = "main", date = G.day(y, m, 14), dir = "DEBIT", amount = r:money(310, 420), desc = "OCTOPUS ENERGY BUSINESS", cat = "utilities",
            by = "rule_engine", conf = 0.96, vat = v("STD20", "rule", 1, "Business energy: standard rated.") }
        add{ acct = "main", date = G.day(y, m, 17), dir = "DEBIT", amount = r:money(48, 66), desc = "WELSH WATER BUSINESS", cat = "utilities",
            by = "rule_engine", conf = 0.95, vat = v("ZERO", "rule", 1, "Water supplied to a business: zero rated.") }
        for _, s in ipairs({ { "J PATEL WAGES", 1320 }, { "M EVANS WAGES", 1180 }, { "L DAVIES WAGES", 640 } }) do
            add{ acct = "main", date = G.day(y, m, 28), dir = "DEBIT", amount = s[2], desc = s[1], cat = "salaries_wages",
                by = "rule_engine", conf = 0.94, vat = v("OUTSIDE", "rule", 1, "Wages are outside the scope of VAT.") }
        end
        add{ acct = "main", date = G.day(y, m, 19), dir = "DEBIT", amount = r:money(410, 470), desc = "HMRC PAYE", cat = "employer_ni",
            by = "rule_engine", conf = 0.9, vat = v("OUTSIDE", "rule", 1, "PAYE and NIC: outside the scope of VAT.") }
        add{ acct = "main", date = G.day(y, m, 3), dir = "DEBIT", amount = r:money(140, 190), desc = "SUMUP FEES", cat = "bank_charges",
            by = "rule_engine", conf = 0.97, vat = v("EXEMPT", "rule", 1, "Card processing fees: exempt.") }
        add{ acct = "main", date = G.day(y, m, 10), dir = "DEBIT", amount = r:money(120, 210), desc = "VEGWARE LTD PACKAGING", cat = "cost_of_sales",
            by = "agent", conf = 0.9, vat = v("STD20", "ai", 0.92, "Takeaway packaging: standard rated.") }
        add{ acct = "main", date = G.day(y, m, 12), dir = "DEBIT", amount = r:money(35, 80), desc = "BUNZL CLEANING SUPPLIES", cat = "materials_supplies",
            by = "agent", conf = 0.88, vat = v("STD20", "ai", 0.9, "Cleaning products: standard rated.") }
        add{ acct = "main", date = G.day(y, m, 5), dir = "DEBIT", amount = 29.00, desc = "SQUARE POS SOFTWARE", cat = "software_subscriptions",
            by = "rule_engine", conf = 0.97, vat = v("STD20", "rule", 1, "Software subscription from a UK supplier: standard rated.") }
        add{ acct = "main", date = G.day(y, m, 30), dir = "DEBIT", amount = 1800, desc = "TRANSFER TO E MOSS", cat = "drawings",
            by = "rule_engine", conf = 0.96, business = false, vat = v("OUTSIDE", "rule", 1, "Drawings: not a supply.") }
    end
    for _, ym in ipairs({ { a, 6 }, { a, 9 }, { a, 12 }, { a + 1, 3 } }) do
        add{ acct = "main", date = G.day(ym[1], ym[2], 24), dir = "DEBIT", amount = 420, desc = "HARBOUR & LANE ACCOUNTANTS", cat = "accountancy_fees",
            by = "rule_engine", conf = 0.96, vat = v("STD20", "rule", 1, "Accountancy fees: standard rated.") }
    end
    for i, ym in ipairs({ { a, 8 }, { a, 11 }, { a + 1, 2 } }) do
        add{ acct = "main", date = G.day(ym[1], ym[2], 7), dir = "DEBIT", amount = ({ 2961.40, 3104.85, 2876.10 })[i],
            desc = "HMRC VAT", cat = "tax_payments", by = "rule_engine", conf = 0.99, vat = v("OUTSIDE", "rule", 1, "Paying HMRC the VAT due: not a supply.") }
    end
    add{ acct = "main", date = G.day(a, 5, 2), dir = "DEBIT", amount = 684.00, desc = "HISCOX CAFE INSURANCE", cat = "business_insurance",
        by = "rule_engine", conf = 0.95, vat = v("EXEMPT", "rule", 1, "Insurance: exempt (IPT is not VAT).") }
    add{ acct = "main", date = G.day(a, 7, 15), dir = "DEBIT", amount = 268.80, desc = "CAFE TECH ESPRESSO SERVICE", cat = "equipment_repairs",
        by = "agent", conf = 0.9, vat = v("STD20", "ai", 0.9, "Repair service: standard rated.") }
    add{ acct = "main", date = G.day(a + 1, 2, 3), dir = "DEBIT", amount = 154.80, desc = "CAFE TECH ESPRESSO SERVICE", cat = "equipment_repairs",
        by = "agent", conf = 0.9, vat = v("STD20", "ai", 0.9, "Repair service: standard rated.") }
    for _, f in ipairs(C4_FLAGGED) do
        add{ acct = "main", date = G.day(a, f[1], f[2]), dir = f[3]:find("CASH DEPOSIT") and "CREDIT" or "DEBIT", amount = f[4], desc = f[3],
            cat = f[3]:find("CASH DEPOSIT") and "sales_income" or "materials_supplies", by = "agent", conf = 0.47, status = "review",
            reason = f[5], vat = { review = true, reasons = { f[5] } } }
    end
end

---------------------------------------------------------------------------
-- C5 Dan Kowalski: CIS subcontractor builder. ~150 lines, just sorted, not reviewed
-- (4 flagged). Contractors pay him net of the 20% CIS deduction.
---------------------------------------------------------------------------
local function c5_generate(G, add, year)
    local r = G.rng(6060)
    local a = tonumber(year:sub(1, 4))
    for _, ym in ipairs(G.months(year)) do
        local y, m = ym[1], ym[2]
        for k, d in ipairs({ 9, 23 }) do
            local gross = r:money(1900, 3100)
            local contractor = (k == 1) and "MAINCO BUILD LTD" or "ASHDOWN HOMES LTD"
            add{ acct = "main", date = G.day(y, m, d), dir = "CREDIT", amount = gross * 0.8, desc = contractor .. " CIS NET PAYMENT",
                cat = "sales_income", by = "rule_engine", conf = 0.95,
                reason = "Payment from a contractor marked CIS: turnover. The gross and the 20% deduction come from the monthly CIS statement.",
                note = string.format("Gross £%.2f, CIS deducted £%.2f (per the contractor's CIS statement).", gross, gross * 0.2) }
        end
        for _ = 1, 4 do
            local s = r:pick({ { "TRAVIS PERKINS", 60, 640 }, { "SCREWFIX DIRECT", 18, 160 }, { "JEWSON LTD", 80, 520 } })
            add{ acct = "main", date = G.day(y, m, r:int(1, 28)), dir = "DEBIT", amount = r:money(s[2], s[3]), desc = s[1],
                cat = "materials_supplies", by = "rule_engine", conf = 0.93 }
        end
        for _ = 1, 3 do
            add{ acct = "main", date = G.day(y, m, r:int(1, 28)), dir = "DEBIT", amount = r:money(58, 92),
                desc = r:pick({ "SHELL GARAGE", "BP CONNECT", "ESSO TESCO EXPRESS" }), cat = "vehicle_fuel", by = "rule_engine", conf = 0.9 }
        end
        add{ acct = "main", date = G.day(y, m, 6), dir = "DEBIT", amount = 96.40, desc = "ADMIRAL VAN INSURANCE", cat = "vehicle_insurance", by = "rule_engine", conf = 0.95 }
        add{ acct = "main", date = G.day(y, m, 15), dir = "DEBIT", amount = 389.00, desc = "BLACKHORSE VAN FINANCE", cat = "loan_repayments", by = "agent", conf = 0.82,
            reason = "Hire purchase on the van: capital isn't an expense; the interest part is (from the finance statement)." }
        add{ acct = "main", date = G.day(y, m, 20), dir = "DEBIT", amount = 22.00, desc = "VODAFONE", cat = "telephone", by = "rule_engine", conf = 0.94 }
    end
    add{ acct = "main", date = G.day(a, 7, 31), dir = "DEBIT", amount = 1120, desc = "HMRC SELF ASSESSMENT", cat = "tax_payments", by = "rule_engine", conf = 0.99 }
    add{ acct = "main", date = G.day(a + 1, 1, 30), dir = "DEBIT", amount = 1460, desc = "HMRC SELF ASSESSMENT", cat = "tax_payments", by = "rule_engine", conf = 0.99 }
    add{ acct = "main", date = G.day(a, 8, 2), dir = "DEBIT", amount = 649.99, desc = "SCREWFIX DIRECT MITRE SAW", cat = "equipment_purchase", by = "agent", conf = 0.55, status = "review",
        reason = "A power tool over £500: a capital purchase (allowance) rather than materials." }
    add{ acct = "main", date = G.day(a, 10, 12), dir = "DEBIT", amount = 212.30, desc = "B&Q 1450 SWINDON", cat = "materials_supplies", by = "agent", conf = 0.46, status = "review",
        reason = "DIY store on a Saturday: job materials or home?" }
    add{ acct = "main", date = G.day(a, 12, 20), dir = "DEBIT", amount = 300, desc = "CASH WITHDRAWAL SWINDON", cat = "drawings", by = "agent", conf = 0.4, status = "review",
        business = false, reason = "Cash taken out: personal, or paying a labourer in cash (needs a record)?" }
    add{ acct = "main", date = G.day(a + 1, 2, 6), dir = "DEBIT", amount = 85.00, desc = "PAYPAL *TOOLHIRE", cat = "materials_supplies", by = "agent", conf = 0.5, status = "review",
        reason = "PayPal payment to a tool-hire name: hire costs are allowable; confirm it was for a job." }
end

---------------------------------------------------------------------------
-- C6 Sam Rivers: employee (PAYE) with a craft business on Etsy. ~80 lines, 2 flagged.
---------------------------------------------------------------------------
local function c6_generate(G, add, year)
    local r = G.rng(7070)
    local a = tonumber(year:sub(1, 4))
    for _, ym in ipairs(G.months(year)) do
        local y, m = ym[1], ym[2]
        add{ acct = "main", date = G.day(y, m, 25), dir = "CREDIT", amount = 2309.50, desc = "BRIGHTWATER COUNCIL SALARY", cat = "transfer",
            by = "rule_engine", conf = 0.96, business = false,
            reason = "Salary from an employer: employment income comes from the P60, so it's kept out of the Etsy business figures." }
        for _, d in ipairs({ 6, 20 }) do
            add{ acct = "main", date = G.day(y, m, d), dir = "CREDIT", amount = r:money(140, 520), desc = "ETSY UK PAYOUT", cat = "sales_income",
                by = "rule_engine", conf = 0.97, reason = "Etsy shop payout: turnover of the craft business." }
        end
        add{ acct = "main", date = G.day(y, m, 2), dir = "DEBIT", amount = r:money(12, 38), desc = "ETSY ADS AND FEES", cat = "marketing_advertising", by = "rule_engine", conf = 0.94 }
        if m % 3 ~= 0 then
            add{ acct = "main", date = G.day(y, m, r:int(3, 24)), dir = "DEBIT", amount = r:money(24, 96),
                desc = r:pick({ "WOOL WAREHOUSE", "THE CRAFT COTTAGE", "LOVECRAFTS" }), cat = "materials_supplies", by = "agent", conf = 0.88 }
        end
        if m % 6 ~= 0 then
            add{ acct = "main", date = G.day(y, m, r:int(5, 27)), dir = "DEBIT", amount = r:money(9, 44), desc = "ROYAL MAIL CLICK&DROP", cat = "postage_delivery",
                by = "rule_engine", conf = 0.96 }
        end
    end
    add{ acct = "main", date = G.day(a, 11, 21), dir = "DEBIT", amount = 142.00, desc = "HOBBYCRAFT 0412", cat = "materials_supplies", by = "agent", conf = 0.5, status = "review",
        reason = "Craft shop: stock for the Etsy business, or a personal hobby buy?" }
    add{ acct = "main", date = G.day(a + 1, 1, 14), dir = "CREDIT", amount = 260.00, desc = "PAYPAL TRANSFER", cat = "sales_income", by = "agent", conf = 0.45, status = "review",
        reason = "Money in through PayPal: a craft fair sale, or a friend paying you back?" }
end

return {
    slug = "practice",
    tax_year = TAX_YEAR,
    namespace = {
        slug = "daybook-demo",
        name = "Harbour & Lane Accountants",
        description = "Daybook demo: a fictional accountancy practice and six clients. Read-only, reset every 30 minutes.",
    },
    -- Members of the practice. The first "owner" owns the workspace.
    staff = {
        { email = "ruth.hughes@sample.daybook.co.uk", first = "Ruth", last = "Hughes", role = "owner" },
        { email = "ade.okoro@sample.daybook.co.uk", first = "Ade", last = "Okoro", role = "admin" },
        { email = "lucy.fairbairn@sample.daybook.co.uk", first = "Lucy", last = "Fairbairn", role = "member" },
    },
    -- Who handles the filing queue and VAT clients in the stories below.
    handler = "ade.okoro@sample.daybook.co.uk",
    -- The demo login's own Tax pages (Transactions, Statements, Reports, File My Tax,
    -- AI assistant) show the signed-in person's own book. OpsAPI has no "view as
    -- client", so the viewer gets a copy of this client's book. Only ONE vertical may set
    -- it: personal tax pages are per person, not per workspace.
    viewer_book = "C3",
    -- The viewer acts as the practice's VAT agent for these clients (VAT → VAT clients).
    vat_agent_arn = "XARN0001234",

    clients = {
        {
            key = "C1", email = "jordan.hale@sample.daybook.co.uk", first = "Jordan", last = "Hale",
            profile_key = "landlord", business_description = "Residential lettings: 100 houses through four letting agents",
            income_types = { "uk_property" },
            -- What Jordan told the assistant: the interest part of the four BTL mortgages.
            profile = { property_finance_costs = 513090 },
            years = { "2024-25", TAX_YEAR },
            accounts = { main = { bank = "Lloyds Bank", name = "J Hale Property Account", last4 = "4471", sort = "30-96-26", type = "BUSINESS", opening = 84210.55 } },
            workflow = "FILED",
            generate = c1_generate,
            filing = {
                status = "filed", hmrc_reference = "XAIT00000462190", filed_days_ago = 41,
                timeline = {
                    { status = "submitted", by = "customer", days_ago = 49 },
                    { status = "reviewing", by = "accountant", days_ago = 48 },
                    { status = "needs_info", by = "accountant", days_ago = 47,
                      text = "Was the £7,850 kitchen at 14 Mill Lane like-for-like, or a refit with a new layout?" },
                    { type = "reply", by = "customer", days_ago = 46, text = "A full refit, new layout and an extra unit." },
                    { status = "reviewing", by = "accountant", days_ago = 46 },
                    { status = "filing", by = "accountant", days_ago = 42 },
                    { status = "filed", by = "accountant", days_ago = 41, hmrc_reference = "XAIT00000462190" },
                },
            },
        },
        {
            key = "C2", email = "priya.shah@sample.daybook.co.uk", first = "Priya", last = "Shah",
            profile_key = "landlord", business_description = "Two let flats in Bristol",
            income_types = { "uk_property" }, profile = { property_finance_costs = 5112 },
            accounts = { main = { bank = "Nationwide", name = "P Shah Current Account", last4 = "0918", sort = "07-04-36", type = "PERSONAL", opening = 6420.10 } },
            workflow = "CLASSIFIED",
            generate = c2_generate,
            filing = {
                status = "needs_info",
                client_message = "Is the £4,200 to Hendry Kitchens a like-for-like replacement (repair) or a better kitchen (improvement)? A photo of the old one would settle it.",
                timeline = {
                    { status = "submitted", by = "customer", days_ago = 9 },
                    { status = "reviewing", by = "accountant", days_ago = 7 },
                    { status = "needs_info", by = "accountant", days_ago = 6, text = "Is the £4,200 to Hendry Kitchens a repair or an improvement?" },
                },
            },
        },
        {
            key = "C3", email = "tom.reid@sample.daybook.co.uk", first = "Tom", last = "Reid",
            profile_key = "it_contractor", business_description = "Self-employed IT consultant",
            income_types = { "self_employment" }, profile = {},
            accounts = { main = { bank = "Monzo", name = "T Reid Current Account", last4 = "2207", sort = "04-00-04", type = "PERSONAL", opening = 9120.00, statement_months = 6 } },
            workflow = "CLASSIFIED",
            generate = c3_generate,
            filing = {
                status = "reviewing",
                timeline = {
                    { status = "submitted", by = "customer", days_ago = 5 },
                    { status = "reviewing", by = "accountant", days_ago = 3 },
                },
            },
        },
        {
            key = "C4", email = "ellie.moss@sample.daybook.co.uk", first = "Ellie", last = "Moss",
            profile_key = "sole_trader", business_description = "Corner Cup Café, Penarth (sole trader, VAT registered)",
            income_types = { "self_employment" }, profile = {},
            accounts = { main = { bank = "Barclays", name = "E Moss t/a Corner Cup Cafe", last4 = "6630", sort = "20-45-77", type = "BUSINESS", opening = 11850.00 } },
            workflow = "CLASSIFIED",
            generate = c4_generate,
            vat = {
                business_name = "Corner Cup Café", scheme = "standard", stagger = "quarterly_mar",
                effective_date = "2021-07-01", business_address = "4 Station Parade, Penarth, CF64 1AA",
                -- Quarters of the tax year: filed (with a sandbox receipt), ready (draft saved), open.
                returns = {
                    { start = "2025-04-01", ["end"] = "2025-06-30", state = "submitted" },
                    { start = "2025-07-01", ["end"] = "2025-09-30", state = "draft" },
                },
            },
        },
        {
            key = "C5", email = "dan.kowalski@sample.daybook.co.uk", first = "Dan", last = "Kowalski",
            profile_key = "construction", business_description = "Builder, CIS subcontractor",
            income_types = { "self_employment" }, profile = {},
            accounts = { main = { bank = "Santander", name = "D Kowalski Business", last4 = "5582", sort = "09-01-28", type = "BUSINESS", opening = 3210.75 } },
            workflow = "CLASSIFIED",
            generate = c5_generate,
        },
        {
            key = "C6", email = "sam.rivers@sample.daybook.co.uk", first = "Sam", last = "Rivers",
            profile_key = "sole_trader", business_description = "Employee, plus a knitwear shop on Etsy",
            income_types = { "employment", "self_employment" },
            profile = { employment_income = 31500, paye_deducted = 3786 },
            accounts = { main = { bank = "HSBC", name = "S Rivers Current Account", last4 = "7713", sort = "40-11-62", type = "PERSONAL", opening = 2875.40 } },
            workflow = "CLASSIFIED",
            generate = c6_generate,
            filing = {
                status = "submitted",
                timeline = { { status = "submitted", by = "customer", days_ago = 1 } },
            },
        },
    },
}
