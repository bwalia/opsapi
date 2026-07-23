--[[
  Salary / Employment (SA102) — content-only migration.

  Puts the existing `salary` income type onto the form-sections engine's
  RECORD MODE: each employment is one tax_form_records row, and the form
  the user fills (Employment Details / Close Company / Income / Benefits
  / Expenses / Foreign / Notes — the IRIS SA102 layout) is defined here
  as tax_form_sections rows with config_json.fields. Everything below is
  catalogue DATA — the engine (migration 755 + the form-sections routes)
  is what executes it, and an admin can reshape any of it in the Form
  Sections UI afterwards with no deploy.

  1. Seed the SA102 section/field catalogue for income type 'salary'
     and turn off flat manual entry (the records page replaces it).
  2. Port legacy flat my_incomes salary rows into records so nothing a
     user already typed disappears from the new page. Source rows are
     left in place (inert for the UI, still feeding the FastAPI calc
     until records gain calc integration — same standing gap as every
     engine type).

  Box references follow SA102: 1 pay, 1.1 payrolled benefits, 2 UK tax,
  3 tips, 4 PAYE reference, 5 employer name, 6/6.1 director, 7 close
  company, 9–16 benefits, 17–20 expenses. They are informational
  metadata (hmrc_mapping / per-field box) until calc integration.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

-- One section row, idempotent on (income_type_key, section_key) — same
-- convention as the pension port. Re-running never duplicates and never
-- overwrites admin edits made since.
local function ensure_section(s)
    local exists = db.select(
        "id FROM tax_form_sections WHERE income_type_key = ? AND section_key = ?",
        "salary", s.key)
    if exists and #exists > 0 then return end
    db.query([[
        INSERT INTO tax_form_sections
            (uuid, income_type_key, section_key, label, description,
             hmrc_mapping, config_json, display_order, is_active,
             created_at, updated_at)
        VALUES (?, 'salary', ?, ?, ?, ?, ?, ?, true, NOW(), NOW())
    ]], MigrationUtils.generateUUID(), s.key, s.label,
        s.description or db.NULL, s.hmrc_mapping or db.NULL,
        cjson.encode(s.config), s.order or 0)
end

return {
    -- =========================================================================
    -- 1. SA102 section + field catalogue for 'salary'
    -- =========================================================================
    [1] = function()
        ensure_section({
            key = "employment_details",
            label = "Employment details",
            description = "Who you worked for — from your P60, P45 or payslips.",
            hmrc_mapping = '{"sa102_boxes":"4-7"}',
            order = 1,
            config = {
                -- Record-mode settings for the whole type live on the first
                -- section (lowest display_order with a record block wins).
                record = {
                    noun = "Employment",
                    title_field = "employer_name",
                    subtitle_field = "paye_reference",
                },
                fields = {
                    { key = "employer_name", label = "Employer's name", type = "text",
                      required = true, box = "5" },
                    { key = "paye_reference", label = "Employer's PAYE tax reference (NNN/XXXXXX)",
                      type = "text", required = true, format = "paye_reference", box = "4",
                      help = "On your P60 or P45 — three numbers, a slash, then letters and numbers." },
                    { key = "start_date", label = "Date employment started", type = "date" },
                    { key = "end_date", label = "Date employment ceased", type = "date" },
                    { key = "is_director", label = "Were you a company director?", type = "boolean",
                      box = "6" },
                    { key = "director_ceased_date", label = "Date ceased being a director",
                      type = "date", box = "6.1", show_if = { field = "is_director" } },
                    { key = "is_close_company", label = "Is this a close company?", type = "boolean",
                      box = "7",
                      help = "A company controlled by 5 or fewer people (or by its directors)." },
                },
            },
        })

        ensure_section({
            key = "close_company_details",
            label = "Close company details",
            order = 2,
            config = {
                fields = {
                    { key = "registered_number", label = "Registered number", type = "text",
                      show_if = { field = "is_close_company" } },
                    { key = "close_company_dividends",
                      label = "Dividends you received from this close company", type = "money",
                      show_if = { field = "is_close_company" } },
                    { key = "shareholding_percent",
                      label = "Percentage shareholding in this close company", type = "number",
                      show_if = { field = "is_close_company" } },
                },
            },
        })

        ensure_section({
            key = "income",
            label = "Income",
            description = "From your P60 (or P45 if you left during the year).",
            hmrc_mapping = '{"sa102_boxes":"1-3"}',
            order = 3,
            config = {
                fields = {
                    { key = "pay_before_tax",
                      label = "Pay from this employment before tax was taken off", type = "money",
                      box = "1", summary = true },
                    { key = "payrolled_benefits",
                      label = "Payrolled benefits included above which affect your student loan repayments",
                      type = "money", box = "1.1" },
                    { key = "uk_tax_taken_off", label = "UK tax taken off", type = "money",
                      box = "2" },
                    { key = "tips_not_on_p60", label = "Tips and other payments not on your P60",
                      type = "money", box = "3", summary = true },
                },
            },
        })

        ensure_section({
            key = "benefits",
            label = "Benefits",
            description = "These amounts will be on form P11D from your employer.",
            hmrc_mapping = '{"sa102_boxes":"9-16"}',
            order = 4,
            config = {
                fields = {
                    { key = "company_cars", label = "Company cars", type = "money", box = "9" },
                    { key = "fuel_company_cars", label = "Fuel for company cars", type = "money", box = "10" },
                    { key = "company_vans", label = "Company vans", type = "money", box = "9" },
                    { key = "fuel_company_vans", label = "Fuel for company vans", type = "money", box = "10" },
                    { key = "travel_subsistence", label = "Travel and subsistence", type = "money", box = "16" },
                    { key = "entertaining", label = "Entertaining", type = "money", box = "16" },
                    { key = "private_medical", label = "Private medical and dental insurance", type = "money", box = "11" },
                    { key = "telephone", label = "Telephone", type = "money", box = "16" },
                    { key = "professional_fees_employer", label = "Professional fees & subscriptions paid by employer", type = "money", box = "16" },
                    { key = "vouchers_credit_cards", label = "Vouchers and credit cards", type = "money", box = "12" },
                    { key = "excess_mileage_allowance", label = "Excess mileage allowance", type = "money", box = "12" },
                    { key = "goods_assets_provided", label = "Goods and other assets provided by employer", type = "money", box = "13" },
                    { key = "accommodation_provided", label = "Accommodation provided by employer", type = "money", box = "14" },
                    { key = "other_benefits", label = "Other benefits", type = "money", box = "15" },
                    { key = "expenses_payments_received", label = "Expenses payments received", type = "money", box = "16" },
                },
            },
        })

        ensure_section({
            key = "expenses",
            label = "Expenses",
            description = "Costs of doing your job that your employer didn't reimburse.",
            hmrc_mapping = '{"sa102_boxes":"17-20"}',
            order = 5,
            config = {
                fields = {
                    { key = "business_travel", label = "Business travel", type = "money", box = "17" },
                    { key = "hotel_meal_expenses", label = "Hotel and meal expenses", type = "money", box = "17" },
                    { key = "fixed_deductions", label = "Fixed deductions for expenses", type = "money", box = "18" },
                    { key = "professional_fees_subs", label = "Professional fees and subscriptions", type = "money", box = "19" },
                    { key = "tools_work_clothes", label = "Cost of tools and work clothes", type = "money", box = "18" },
                    { key = "vehicle_expenses", label = "Vehicle expenses", type = "money", box = "17" },
                    { key = "mileage_shortfall", label = "Mileage allowance shortfall", type = "money", box = "17" },
                    { key = "other_expenses_capital", label = "Other expenses and capital allowances", type = "money", box = "20" },
                },
            },
        })

        ensure_section({
            key = "foreign",
            label = "Foreign earnings and deductions",
            order = 6,
            config = {
                fields = {
                    { key = "seafarers_deduction", label = "Seafarers' earnings deduction", type = "money" },
                    { key = "foreign_earnings_not_taxable", label = "Foreign earnings not taxable in the UK", type = "money" },
                    { key = "foreign_tax_no_credit", label = "Foreign tax for which tax credit relief not claimed", type = "money" },
                    { key = "exempt_overseas_pension", label = "Exempt employers' contributions to an overseas pension scheme", type = "money" },
                },
            },
        })

        ensure_section({
            key = "notes",
            label = "Additional information",
            order = 7,
            config = {
                fields = {
                    { key = "tax_return_note", label = "Additional text note for your tax return",
                      type = "textarea",
                      help = "Anything HMRC should know about this employment — goes in the 'any other information' box." },
                },
            },
        })

        -- The records page replaces flat one-amount entries for salary.
        -- Existing my_incomes rows are grandfathered by the my-incomes
        -- routes (unchanged-type edits still allowed) — this only stops
        -- NEW flat entries / type changes onto salary.
        db.query([[
            UPDATE income_types SET allows_manual_entry = false, updated_at = NOW()
            WHERE income_type_key = 'salary'
        ]])
        print("[Salary SA102] Seeded 7 form sections for 'salary'; flat manual entry off")
    end,

    -- =========================================================================
    -- 2. Port legacy flat salary entries → one record each. Reuses the
    --    source row's uuid so a re-run can never duplicate. Source rows are
    --    NOT archived: the FastAPI calc aggregator still reads them (records
    --    have no calc integration yet), and the new page simply doesn't
    --    render the flat surface.
    -- =========================================================================
    [2] = function()
        local rows = db.query([[
            SELECT * FROM my_incomes
            WHERE income_type = 'salary' AND is_archived = false
        ]]) or {}
        for _, r in ipairs(rows) do
            local title = r.description
            if type(title) ~= "string" or title == "" then title = "Employment" end
            if #title > 200 then title = title:sub(1, 200) end
            local data = {
                employer_name = title,
                pay_before_tax = tonumber(r.amount) or 0,
            }
            db.query([[
                INSERT INTO tax_form_records
                    (uuid, user_id, namespace_id, income_type_key, tax_year,
                     data_json, total, is_archived, created_at, updated_at)
                VALUES (?, ?, ?, 'salary', ?, ?, ?, false, ?, ?)
                ON CONFLICT (uuid) DO NOTHING
            ]], r.uuid, r.user_id, r.namespace_id or db.NULL, r.tax_year,
                cjson.encode(data), tonumber(r.amount) or 0,
                r.created_at, r.updated_at)
        end
        print("[Salary SA102] Ported " .. #rows .. " flat salary entries to records")
    end,
}
