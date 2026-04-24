--[[
  Tax Copilot System Migrations

  Database schema for UK Tax Return AI Agent.
  These migrations are only executed when PROJECT_CODE includes 'tax_copilot'.

  Tables created:
  - tax_bank_accounts       : User's bank accounts
  - tax_statements          : Uploaded bank statements (PDF/CSV)
  - tax_transactions        : Extracted and classified transactions
  - tax_categories          : Business expense/income categories
  - tax_hmrc_categories     : HMRC SA103F box mappings
  - tax_returns             : Calculated tax returns
  - tax_audit_logs          : Audit trail for all changes
  - tax_support_conversations : User-accountant messaging
  - tax_support_messages    : Individual support messages
  - tax_user_profiles       : User HMRC profile (hashed NINO, preferences)
  - hmrc_businesses         : Cached HMRC business details
  - hmrc_obligations        : Cached quarterly obligation periods
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local MigrationUtils = require "helper.migration-utils"

return {
    -- 1. Create tax_bank_accounts table
    [1] = function()
        schema.create_table("tax_bank_accounts", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_id", types.integer },
            { "namespace_id", types.integer({ null = true }) },
            { "bank_name", types.varchar },
            { "account_name", types.varchar({ null = true }) },
            { "account_number_last4", types.varchar({ null = true }) },
            { "sort_code", types.varchar({ null = true }) },
            { "account_type", types.varchar({ default = "'BUSINESS'" }) },
            { "currency", types.varchar({ default = "'GBP'" }) },
            { "is_primary", types.boolean({ default = false }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 2. Add indexes to tax_bank_accounts
    [2] = function()
        schema.create_index("tax_bank_accounts", "user_id")
        schema.create_index("tax_bank_accounts", "namespace_id")
        schema.create_index("tax_bank_accounts", "uuid")
        schema.create_index("tax_bank_accounts", "is_active")
    end,

    -- 3. Create tax_hmrc_categories table (must be before tax_categories due to FK)
    [3] = function()
        schema.create_table("tax_hmrc_categories", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "key", types.varchar({ unique = true }) },
            { "box", types.varchar({ unique = true }) },  -- SA103F box number
            { "label", types.varchar },
            { "description", types.text({ null = true }) },
            { "is_tax_deductible", types.boolean({ default = true }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 4. Seed default HMRC categories (SA103F Self-Employment boxes)
    [4] = function()
        local hmrc_categories = {
            { key = "turnover", box = "15", label = "Turnover/Sales", description = "Total business income/turnover", is_deductible = false },
            { key = "other_income", box = "16", label = "Other Business Income", description = "Any other business income", is_deductible = false },
            { key = "cost_of_goods", box = "17", label = "Cost of Goods Sold", description = "Cost of goods bought for resale or goods used", is_deductible = true },
            { key = "car_van_travel", box = "19", label = "Car, Van and Travel Expenses", description = "Business travel costs including fuel, repairs, insurance", is_deductible = true },
            { key = "wages_staff", box = "20", label = "Wages, Salaries and Other Staff Costs", description = "Employee wages, salaries, NI contributions", is_deductible = true },
            { key = "rent_rates", box = "21", label = "Rent, Rates, Power and Insurance Costs", description = "Business premises rent, council rates, utilities, insurance", is_deductible = true },
            { key = "repairs_maintenance", box = "22", label = "Repairs and Maintenance", description = "Repairs to business property and equipment", is_deductible = true },
            { key = "accountancy_legal", box = "23", label = "Accountancy, Legal and Other Professional Fees", description = "Professional services fees", is_deductible = true },
            { key = "interest_finance", box = "24", label = "Interest and Other Finance Charges", description = "Bank charges, loan interest, finance charges", is_deductible = true },
            { key = "telephone_office", box = "25", label = "Phone, Fax, Stationery and Other Office Costs", description = "Communication and office expenses", is_deductible = true },
            { key = "other_expenses", box = "26", label = "Other Allowable Business Expenses", description = "Other business expenses not listed elsewhere", is_deductible = true },
            { key = "depreciation", box = "27", label = "Depreciation and Loss/Profit on Sale of Assets", description = "Asset depreciation (informational only)", is_deductible = false },
            { key = "use_of_home", box = "32", label = "Use of Home as Office", description = "Proportion of home costs for business use", is_deductible = true },
            { key = "capital_allowances", box = "28", label = "Capital Allowances", description = "Annual Investment Allowance on equipment", is_deductible = true },
        }

        for _, cat in ipairs(hmrc_categories) do
            local exists = db.select("id FROM tax_hmrc_categories WHERE key = ?", cat.key)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO tax_hmrc_categories (uuid, key, box, label, description, is_tax_deductible, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), cat.key, cat.box, cat.label, cat.description, cat.is_deductible, true)
            end
        end
    end,

    -- 5. Create tax_categories table
    [5] = function()
        schema.create_table("tax_categories", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "key", types.varchar({ unique = true }) },
            { "label", types.varchar },
            { "hmrc_category_id", types.integer({ null = true }) },  -- FK to tax_hmrc_categories
            { "is_tax_deductible", types.boolean({ default = true }) },
            { "deduction_rate", "numeric(3,2) DEFAULT 1.0" },
            { "type", types.varchar },  -- INCOME or EXPENSE
            { "description", types.text({ null = true }) },
            { "examples", types.text({ null = true }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 6. Seed default business categories
    [6] = function()
        -- Helper to get HMRC category ID by key
        local function get_hmrc_id(key)
            local result = db.select("id FROM tax_hmrc_categories WHERE key = ?", key)
            return result and result[1] and result[1].id or nil
        end

        local categories = {
            -- Income categories
            { key = "sales_income", label = "Sales/Revenue", type = "INCOME", hmrc_key = "turnover", is_deductible = false, rate = 1.0, desc = "Income from selling products or services", examples = "Customer payments, invoice payments, online sales" },
            { key = "consulting_income", label = "Consulting/Freelance Income", type = "INCOME", hmrc_key = "turnover", is_deductible = false, rate = 1.0, desc = "Income from professional services", examples = "Consulting fees, freelance work, contract work" },
            { key = "rental_income", label = "Rental Income", type = "INCOME", hmrc_key = "other_income", is_deductible = false, rate = 1.0, desc = "Income from renting property or equipment", examples = "Property rent, equipment hire" },
            { key = "interest_income", label = "Interest Received", type = "INCOME", hmrc_key = "other_income", is_deductible = false, rate = 1.0, desc = "Bank interest and investment returns", examples = "Savings interest, investment dividends" },
            { key = "refund_income", label = "Refunds Received", type = "INCOME", hmrc_key = "other_income", is_deductible = false, rate = 1.0, desc = "Refunds from suppliers or overpayments", examples = "Supplier refunds, tax refunds, deposit returns" },
            { key = "income_other", label = "Other Income", type = "INCOME", hmrc_key = "other_income", is_deductible = false, rate = 1.0, desc = "Any other business income", examples = "Grants, awards, miscellaneous income" },

            -- Expense categories
            { key = "inventory_stock", label = "Inventory/Stock Purchases", type = "EXPENSE", hmrc_key = "cost_of_goods", is_deductible = true, rate = 1.0, desc = "Goods purchased for resale", examples = "Stock, raw materials, products for sale" },
            { key = "materials_supplies", label = "Materials & Supplies", type = "EXPENSE", hmrc_key = "cost_of_goods", is_deductible = true, rate = 1.0, desc = "Materials used in delivering services", examples = "Packaging, consumables, project materials" },
            { key = "vehicle_fuel", label = "Vehicle Fuel", type = "EXPENSE", hmrc_key = "car_van_travel", is_deductible = true, rate = 1.0, desc = "Petrol/diesel for business vehicles", examples = "Petrol, diesel, charging costs" },
            { key = "vehicle_maintenance", label = "Vehicle Maintenance", type = "EXPENSE", hmrc_key = "car_van_travel", is_deductible = true, rate = 1.0, desc = "Vehicle repairs and servicing", examples = "MOT, servicing, repairs, tyres" },
            { key = "vehicle_insurance", label = "Vehicle Insurance", type = "EXPENSE", hmrc_key = "car_van_travel", is_deductible = true, rate = 1.0, desc = "Business vehicle insurance", examples = "Car insurance, van insurance" },
            { key = "travel_transport", label = "Travel & Transport", type = "EXPENSE", hmrc_key = "car_van_travel", is_deductible = true, rate = 1.0, desc = "Business travel expenses", examples = "Train tickets, flights, taxis, parking" },
            { key = "mileage", label = "Mileage Allowance", type = "EXPENSE", hmrc_key = "car_van_travel", is_deductible = true, rate = 1.0, desc = "Business mileage in personal vehicle", examples = "Mileage reimbursement at HMRC rates" },
            { key = "salaries_wages", label = "Salaries & Wages", type = "EXPENSE", hmrc_key = "wages_staff", is_deductible = true, rate = 1.0, desc = "Employee pay and benefits", examples = "Staff salaries, bonuses, PAYE" },
            { key = "subcontractors", label = "Subcontractor Payments", type = "EXPENSE", hmrc_key = "wages_staff", is_deductible = true, rate = 1.0, desc = "Payments to freelancers/contractors", examples = "Contractor fees, agency workers" },
            { key = "employer_ni", label = "Employer NI Contributions", type = "EXPENSE", hmrc_key = "wages_staff", is_deductible = true, rate = 1.0, desc = "National Insurance for employees", examples = "Employer NI payments" },
            { key = "pension_contributions", label = "Pension Contributions", type = "EXPENSE", hmrc_key = "wages_staff", is_deductible = true, rate = 1.0, desc = "Employer pension contributions", examples = "Workplace pension contributions" },
            { key = "rent_business", label = "Business Rent", type = "EXPENSE", hmrc_key = "rent_rates", is_deductible = true, rate = 1.0, desc = "Office or premises rent", examples = "Office rent, warehouse rent, shop rent" },
            { key = "business_rates", label = "Business Rates", type = "EXPENSE", hmrc_key = "rent_rates", is_deductible = true, rate = 1.0, desc = "Council business rates", examples = "Business rates, council tax (business portion)" },
            { key = "utilities", label = "Utilities", type = "EXPENSE", hmrc_key = "rent_rates", is_deductible = true, rate = 1.0, desc = "Gas, electric, water for business premises", examples = "Electricity, gas, water bills" },
            { key = "premises_insurance", label = "Premises Insurance", type = "EXPENSE", hmrc_key = "rent_rates", is_deductible = true, rate = 1.0, desc = "Business premises insurance", examples = "Buildings insurance, contents insurance" },
            { key = "repairs_property", label = "Property Repairs", type = "EXPENSE", hmrc_key = "repairs_maintenance", is_deductible = true, rate = 1.0, desc = "Repairs to business premises", examples = "Building repairs, decorating, maintenance" },
            { key = "equipment_repairs", label = "Equipment Repairs", type = "EXPENSE", hmrc_key = "repairs_maintenance", is_deductible = true, rate = 1.0, desc = "Repairs to business equipment", examples = "Computer repairs, machinery maintenance" },
            { key = "accountancy_fees", label = "Accountancy Fees", type = "EXPENSE", hmrc_key = "accountancy_legal", is_deductible = true, rate = 1.0, desc = "Accountant and bookkeeping fees", examples = "Accountant fees, tax advice, bookkeeping" },
            { key = "legal_fees", label = "Legal Fees", type = "EXPENSE", hmrc_key = "accountancy_legal", is_deductible = true, rate = 1.0, desc = "Legal and professional fees", examples = "Solicitor fees, contracts, legal advice" },
            { key = "professional_fees", label = "Other Professional Fees", type = "EXPENSE", hmrc_key = "accountancy_legal", is_deductible = true, rate = 1.0, desc = "Other professional services", examples = "Consulting fees, architect fees" },
            { key = "bank_charges", label = "Bank Charges", type = "EXPENSE", hmrc_key = "interest_finance", is_deductible = true, rate = 1.0, desc = "Bank fees and charges", examples = "Monthly fees, transaction fees, card fees" },
            { key = "loan_interest", label = "Loan Interest", type = "EXPENSE", hmrc_key = "interest_finance", is_deductible = true, rate = 1.0, desc = "Interest on business loans", examples = "Bank loan interest, overdraft interest" },
            { key = "finance_charges", label = "Finance Charges", type = "EXPENSE", hmrc_key = "interest_finance", is_deductible = true, rate = 1.0, desc = "Other finance costs", examples = "HP interest, lease finance" },
            { key = "telephone", label = "Telephone & Mobile", type = "EXPENSE", hmrc_key = "telephone_office", is_deductible = true, rate = 1.0, desc = "Phone and mobile costs", examples = "Phone bills, mobile contracts, call charges" },
            { key = "internet", label = "Internet & Broadband", type = "EXPENSE", hmrc_key = "telephone_office", is_deductible = true, rate = 1.0, desc = "Internet service costs", examples = "Broadband, business internet, hosting" },
            { key = "software_subscriptions", label = "Software & Subscriptions", type = "EXPENSE", hmrc_key = "telephone_office", is_deductible = true, rate = 1.0, desc = "Software and online subscriptions", examples = "Accounting software, Office 365, SaaS subscriptions" },
            { key = "office_supplies", label = "Office Supplies", type = "EXPENSE", hmrc_key = "telephone_office", is_deductible = true, rate = 1.0, desc = "Stationery and office supplies", examples = "Paper, ink, stationery, office equipment under £100" },
            { key = "postage_delivery", label = "Postage & Delivery", type = "EXPENSE", hmrc_key = "telephone_office", is_deductible = true, rate = 1.0, desc = "Postage and courier costs", examples = "Royal Mail, couriers, shipping" },
            { key = "marketing_advertising", label = "Marketing & Advertising", type = "EXPENSE", hmrc_key = "other_expenses", is_deductible = true, rate = 1.0, desc = "Advertising and marketing costs", examples = "Google Ads, Facebook Ads, print advertising" },
            { key = "website_costs", label = "Website Costs", type = "EXPENSE", hmrc_key = "other_expenses", is_deductible = true, rate = 1.0, desc = "Website and domain costs", examples = "Domain names, website hosting, web design" },
            { key = "training_courses", label = "Training & Courses", type = "EXPENSE", hmrc_key = "other_expenses", is_deductible = true, rate = 1.0, desc = "Professional development and training", examples = "Courses, certifications, CPD" },
            { key = "professional_memberships", label = "Professional Memberships", type = "EXPENSE", hmrc_key = "other_expenses", is_deductible = true, rate = 1.0, desc = "Professional body memberships", examples = "Industry associations, professional bodies" },
            { key = "business_insurance", label = "Business Insurance", type = "EXPENSE", hmrc_key = "other_expenses", is_deductible = true, rate = 1.0, desc = "General business insurance", examples = "Public liability, professional indemnity" },
            { key = "client_entertainment", label = "Client Entertainment", type = "EXPENSE", hmrc_key = "other_expenses", is_deductible = false, rate = 0.0, desc = "Client entertainment (not tax deductible)", examples = "Client meals, hospitality (not deductible for tax)" },
            { key = "home_office", label = "Home Office Costs", type = "EXPENSE", hmrc_key = "use_of_home", is_deductible = true, rate = 1.0, desc = "Working from home allowance", examples = "Proportion of rent, utilities, council tax" },
            { key = "equipment_purchase", label = "Equipment Purchases", type = "EXPENSE", hmrc_key = "capital_allowances", is_deductible = true, rate = 1.0, desc = "Capital equipment purchases", examples = "Computers, machinery, furniture over £100" },
            { key = "uncategorised_expense", label = "Uncategorised Expense", type = "EXPENSE", hmrc_key = "other_expenses", is_deductible = true, rate = 1.0, desc = "Expenses pending categorisation", examples = "To be reviewed and categorised" },

            -- Non-business / Personal
            { key = "personal_expense", label = "Personal/Non-Business", type = "EXPENSE", hmrc_key = nil, is_deductible = false, rate = 0.0, desc = "Personal expenses (not business related)", examples = "Personal purchases, groceries, personal bills" },
            { key = "transfer", label = "Transfer Between Accounts", type = "EXPENSE", hmrc_key = nil, is_deductible = false, rate = 0.0, desc = "Transfers between own accounts", examples = "Bank transfers, savings transfers" },
            { key = "drawings", label = "Drawings/Owner Withdrawals", type = "EXPENSE", hmrc_key = nil, is_deductible = false, rate = 0.0, desc = "Money taken for personal use", examples = "ATM withdrawals, personal transfers" },
            { key = "tax_payments", label = "Tax Payments", type = "EXPENSE", hmrc_key = nil, is_deductible = false, rate = 0.0, desc = "Tax payments to HMRC", examples = "Self-assessment payments, VAT payments" },
        }

        for _, cat in ipairs(categories) do
            local exists = db.select("id FROM tax_categories WHERE key = ?", cat.key)
            if not exists or #exists == 0 then
                -- Use db.NULL for nil values to ensure proper SQL NULL handling
                local hmrc_id = cat.hmrc_key and get_hmrc_id(cat.hmrc_key) or db.NULL
                db.query([[
                    INSERT INTO tax_categories (uuid, key, label, hmrc_category_id, is_tax_deductible, deduction_rate, type, description, examples, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), cat.key, cat.label, hmrc_id, cat.is_deductible, cat.rate, cat.type, cat.desc, cat.examples, true)
            end
        end
    end,

    -- 7. Add indexes to tax_categories
    [7] = function()
        schema.create_index("tax_categories", "uuid")
        schema.create_index("tax_categories", "key")
        schema.create_index("tax_categories", "type")
        schema.create_index("tax_categories", "is_active")
        schema.create_index("tax_categories", "hmrc_category_id")
    end,

    -- 8. Create tax_statements table
    [8] = function()
        schema.create_table("tax_statements", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "bank_account_id", types.integer },
            { "user_id", types.integer },
            { "namespace_id", types.integer({ null = true }) },

            -- File storage
            { "minio_bucket", types.varchar({ null = true }) },
            { "minio_object_key", types.text({ null = true }) },
            { "file_name", types.varchar({ null = true }) },
            { "file_size_bytes", "bigint" },
            { "file_type", types.varchar({ null = true }) },

            -- Statement metadata
            { "statement_date", types.date({ null = true }) },
            { "period_start", types.date({ null = true }) },
            { "period_end", types.date({ null = true }) },
            { "opening_balance", "numeric(15,2)" },
            { "closing_balance", "numeric(15,2)" },

            -- Processing status
            { "processing_status", types.varchar({ default = "'UPLOADED'" }) },
            { "validation_status", types.varchar({ default = "'PENDING'" }) },
            { "workflow_step", types.varchar({ default = "'UPLOADED'" }) },
            { "error_message", types.text({ null = true }) },

            -- Tax results
            { "tax_year", types.varchar({ null = true }) },
            { "total_income", "numeric(15,2)" },
            { "total_expenses", "numeric(15,2)" },
            { "tax_due", "numeric(15,2)" },

            -- Filing
            { "is_filed", types.boolean({ default = false }) },
            { "filed_at", types.time({ null = true }) },
            { "hmrc_submission_id", types.varchar({ null = true }) },
            { "hmrc_response", types.text({ null = true }) },  -- JSON string

            -- Timestamps
            { "uploaded_at", types.time({ default = db.raw("NOW()") }) },
            { "processed_at", types.time({ null = true }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 9. Add indexes to tax_statements
    [9] = function()
        schema.create_index("tax_statements", "uuid")
        schema.create_index("tax_statements", "user_id")
        schema.create_index("tax_statements", "bank_account_id")
        schema.create_index("tax_statements", "namespace_id")
        schema.create_index("tax_statements", "processing_status")
        schema.create_index("tax_statements", "workflow_step")
        schema.create_index("tax_statements", "tax_year")
    end,

    -- 10. Create tax_transactions table
    [10] = function()
        schema.create_table("tax_transactions", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "statement_id", types.integer },
            { "bank_account_id", types.integer },
            { "user_id", types.integer },

            -- Core transaction data
            { "transaction_date", types.date({ null = true }) },
            { "description", types.text({ null = true }) },
            { "amount", "numeric(15,2)" },
            { "balance", "numeric(15,2)" },
            { "transaction_type", types.varchar },  -- DEBIT/CREDIT

            -- AI Classification results
            { "category", types.varchar({ null = true }) },
            { "hmrc_category", types.varchar({ null = true }) },
            { "confidence_score", "numeric(5,4)" },
            { "classified_by", types.varchar({ null = true }) },
            { "is_tax_deductible", types.boolean({ null = true }) },
            { "is_vat_applicable", types.boolean({ null = true }) },
            { "vat_rate", "numeric(5,2)" },
            { "llm_response", types.text({ null = true }) },  -- JSON string

            -- User confirmations - extraction
            { "confirmation_status", types.varchar({ default = "'PENDING'" }) },
            { "confirmed_at", types.time({ null = true }) },
            { "confirmed_by", types.integer({ null = true }) },

            -- User confirmations - classification
            { "classification_status", types.varchar({ default = "'PENDING'" }) },
            { "classification_confirmed_at", types.time({ null = true }) },
            { "classification_confirmed_by", types.integer({ null = true }) },

            -- Manual review
            { "is_manually_reviewed", types.boolean({ default = false }) },
            { "reviewed_by", types.integer({ null = true }) },
            { "reviewed_at", types.time({ null = true }) },
            { "user_notes", types.text({ null = true }) },

            -- Timestamps
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 11. Add indexes to tax_transactions
    [11] = function()
        schema.create_index("tax_transactions", "uuid")
        schema.create_index("tax_transactions", "statement_id")
        schema.create_index("tax_transactions", "bank_account_id")
        schema.create_index("tax_transactions", "user_id")
        schema.create_index("tax_transactions", "transaction_date")
        schema.create_index("tax_transactions", "category")
        schema.create_index("tax_transactions", "confirmation_status")
        schema.create_index("tax_transactions", "classification_status")
    end,

    -- 12. Create tax_returns table
    [12] = function()
        schema.create_table("tax_returns", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "statement_id", types.integer },
            { "user_id", types.integer },
            { "tax_year", types.varchar },

            -- Income
            { "trading_income", "numeric(15,2)" },
            { "other_income", "numeric(15,2)" },
            { "total_income", "numeric(15,2)" },

            -- Expenses
            { "expense_breakdown", types.text({ null = true }) },  -- JSON
            { "total_expenses", "numeric(15,2)" },

            -- Calculations
            { "trading_profit", "numeric(15,2)" },
            { "personal_allowance", "numeric(15,2)" },
            { "taxable_income", "numeric(15,2)" },
            { "income_tax", "numeric(15,2)" },
            { "national_insurance", "numeric(15,2)" },
            { "total_tax_due", "numeric(15,2)" },

            -- Status
            { "status", types.varchar({ default = "'DRAFT'" }) },
            { "hmrc_submission_id", types.varchar({ null = true }) },
            { "hmrc_filed_at", types.time({ null = true }) },
            { "hmrc_response", types.text({ null = true }) },

            -- Timestamps
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 13. Add indexes to tax_returns
    [13] = function()
        schema.create_index("tax_returns", "uuid")
        schema.create_index("tax_returns", "statement_id")
        schema.create_index("tax_returns", "user_id")
        schema.create_index("tax_returns", "tax_year")
        schema.create_index("tax_returns", "status")
    end,

    -- 14. Create tax_audit_logs table
    [14] = function()
        schema.create_table("tax_audit_logs", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_id", types.integer },
            { "user_email", types.varchar({ null = true }) },
            { "entity_type", types.varchar },  -- TRANSACTION, STATEMENT, BANK_ACCOUNT
            { "entity_id", types.varchar },  -- UUID of changed entity
            { "parent_entity_type", types.varchar({ null = true }) },
            { "parent_entity_id", types.varchar({ null = true }) },
            { "action", types.varchar },  -- CREATE, UPDATE, DELETE, CONFIRM, BULK_CONFIRM
            { "old_values", types.text({ null = true }) },  -- JSON
            { "new_values", types.text({ null = true }) },  -- JSON
            { "change_reason", types.text({ null = true }) },
            { "ip_address", types.varchar({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 15. Add indexes to tax_audit_logs
    [15] = function()
        schema.create_index("tax_audit_logs", "uuid")
        schema.create_index("tax_audit_logs", "user_id")
        schema.create_index("tax_audit_logs", "entity_type", "entity_id")
        schema.create_index("tax_audit_logs", "created_at")
    end,

    -- 16. Create tax_support_conversations table
    [16] = function()
        schema.create_table("tax_support_conversations", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_id", types.integer },
            { "assigned_to", types.integer({ null = true }) },
            { "statement_id", types.integer({ null = true }) },
            { "subject", types.varchar({ null = true }) },
            { "status", types.varchar({ default = "'OPEN'" }) },  -- OPEN, IN_PROGRESS, RESOLVED, CLOSED
            { "priority", types.varchar({ default = "'NORMAL'" }) },  -- LOW, NORMAL, HIGH, URGENT
            { "unread_by_user", types.boolean({ default = false }) },
            { "unread_by_accountant", types.boolean({ default = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            { "resolved_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 17. Add indexes to tax_support_conversations
    [17] = function()
        schema.create_index("tax_support_conversations", "uuid")
        schema.create_index("tax_support_conversations", "user_id")
        schema.create_index("tax_support_conversations", "assigned_to")
        schema.create_index("tax_support_conversations", "status")
        schema.create_index("tax_support_conversations", "statement_id")
    end,

    -- 18. Create tax_support_messages table
    [18] = function()
        schema.create_table("tax_support_messages", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "conversation_id", types.integer },
            { "sender_id", types.integer },
            { "sender_type", types.varchar },  -- USER, ACCOUNTANT, SYSTEM
            { "content", types.text },
            { "is_read", types.boolean({ default = false }) },
            { "read_at", types.time({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- 19. Add indexes to tax_support_messages
    [19] = function()
        schema.create_index("tax_support_messages", "uuid")
        schema.create_index("tax_support_messages", "conversation_id")
        schema.create_index("tax_support_messages", "sender_id")
        schema.create_index("tax_support_messages", "is_read")
    end,

    -- 20. Add foreign key constraints
    [20] = function()
        -- Note: Adding FKs after all tables exist to avoid ordering issues
        -- These are optional - uncomment if you want strict referential integrity

        -- db.query([[
        --     ALTER TABLE tax_bank_accounts
        --     ADD CONSTRAINT fk_tax_bank_accounts_user
        --     FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        -- ]])

        -- db.query([[
        --     ALTER TABLE tax_statements
        --     ADD CONSTRAINT fk_tax_statements_bank_account
        --     FOREIGN KEY (bank_account_id) REFERENCES tax_bank_accounts(id) ON DELETE CASCADE
        -- ]])

        -- db.query([[
        --     ALTER TABLE tax_transactions
        --     ADD CONSTRAINT fk_tax_transactions_statement
        --     FOREIGN KEY (statement_id) REFERENCES tax_statements(id) ON DELETE CASCADE
        -- ]])

        -- db.query([[
        --     ALTER TABLE tax_support_messages
        --     ADD CONSTRAINT fk_tax_support_messages_conversation
        --     FOREIGN KEY (conversation_id) REFERENCES tax_support_conversations(id) ON DELETE CASCADE
        -- ]])

        print("[Tax Copilot] Foreign key constraints ready (currently soft - uncomment in migration to enable)")
    end,

    -- 21. Create tax-specific roles
    [21] = function()
        -- Add tax-specific roles to the roles table
        local tax_roles = {
            { name = "tax_admin", description = "Tax system administrator with full access" },
            { name = "tax_accountant", description = "Accountant with access to multiple users" },
            { name = "tax_client", description = "Standard tax user" },
            { name = "tax_viewer", description = "Read-only access to tax data" },
        }

        for _, role in ipairs(tax_roles) do
            local exists = db.select("id FROM roles WHERE role_name = ?", role.name)
            if not exists or #exists == 0 then
                -- Check if description column exists (from rbac-enhancements)
                local has_description = db.query("SELECT column_name FROM information_schema.columns WHERE table_name = 'roles' AND column_name = 'description'")
                if has_description and #has_description > 0 then
                    db.query([[
                        INSERT INTO roles (uuid, role_name, description, created_at, updated_at)
                        VALUES (?, ?, ?, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), role.name, role.description)
                else
                    db.query([[
                        INSERT INTO roles (uuid, role_name, created_at, updated_at)
                        VALUES (?, ?, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), role.name)
                end
            end
        end
    end,

    -- 22. Add tax module to modules table
    [22] = function()
        local exists = db.select("id FROM modules WHERE machine_name = ?", "tax")
        if not exists or #exists == 0 then
            db.query([[
                INSERT INTO modules (uuid, machine_name, name, description, priority, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), "tax", "Tax Management", "UK Tax Return AI Agent - Self Assessment", "1")
        end
    end,

    -- 23. Final cleanup / verification
    [23] = function()
        print("[Tax Copilot] Migration complete!")
        print("Tables created:")
        print("  - tax_bank_accounts")
        print("  - tax_hmrc_categories (with SA103F box mappings)")
        print("  - tax_categories (with default UK business categories)")
        print("  - tax_statements")
        print("  - tax_transactions")
        print("  - tax_returns")
        print("  - tax_audit_logs")
        print("  - tax_support_conversations")
        print("  - tax_support_messages")
        print("Roles created: tax_admin, tax_accountant, tax_client, tax_viewer")
        print("Module created: tax")
    end,

    -- 24. Rename account_number_last4 to account_number and expand to VARCHAR(20)
    [24] = function()
        -- Check if table exists first (it may not if earlier migrations ran as no-ops)
        local table_check = db.query([[
            SELECT 1 FROM information_schema.tables
            WHERE table_name = 'tax_bank_accounts'
        ]])
        if not table_check or #table_check == 0 then
            print("[Tax Copilot] tax_bank_accounts table does not exist - skipping rename migration")
            print("[Tax Copilot] You may need to reset the database (-r) and re-run migrations with PROJECT_CODE=tax_copilot")
            return
        end

        -- Idempotent: check if old column exists before renaming
        local col_check = db.query([[
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'tax_bank_accounts' AND column_name = 'account_number_last4'
        ]])
        if col_check and #col_check > 0 then
            db.query("ALTER TABLE tax_bank_accounts RENAME COLUMN account_number_last4 TO account_number")
            print("[Tax Copilot] Renamed account_number_last4 -> account_number")
        end
        -- Expand column size to hold full account number (up to 20 chars)
        db.query("ALTER TABLE tax_bank_accounts ALTER COLUMN account_number TYPE varchar(20)")
        print("[Tax Copilot] account_number column expanded to VARCHAR(20)")
    end,

    -- 25. Consolidate dashboard modules: rename "Dashboard" to "Admin Dashboard" and remove tax_admin
    -- The "dashboard" module is now the sole admin gate. "tax_admin" is redundant.
    [25] = function()
        -- Rename core dashboard module display name
        db.query([[
            UPDATE modules SET name = 'Admin Dashboard',
                               description = 'Admin panel access and analytics dashboard',
                               updated_at = NOW()
            WHERE machine_name = 'dashboard'
        ]])
        print("[Tax Copilot] Renamed 'dashboard' module display name to 'Admin Dashboard'")

        -- Remove the redundant tax_admin module entirely.
        -- Note: is_active column may not exist yet (added in migration 400), so we DELETE instead.
        db.query([[
            DELETE FROM modules WHERE machine_name = 'tax_admin'
        ]])
        print("[Tax Copilot] Removed 'tax_admin' module (redundant — 'dashboard' is the sole admin gate)")

        -- Remove tax_admin from any existing role permissions so it doesn't linger
        -- This strips the "tax_admin" key from the JSON permissions column in namespace_roles
        local roles_with_perms = db.query([[
            SELECT id, permissions FROM namespace_roles
            WHERE permissions IS NOT NULL AND permissions::text LIKE '%tax_admin%'
        ]])
        if roles_with_perms then
            for _, role in ipairs(roles_with_perms) do
                db.query([[
                    UPDATE namespace_roles
                    SET permissions = (permissions::jsonb - 'tax_admin')::text,
                        updated_at = NOW()
                    WHERE id = ?
                ]], role.id)
            end
            print("[Tax Copilot] Cleaned tax_admin from " .. #roles_with_perms .. " role permission(s)")
        end
    end,

    -- 26. Summary
    [26] = function()
        print("[Tax Copilot] Dashboard consolidation complete:")
        print("  - 'dashboard' module is now 'Admin Dashboard' (sole admin gate)")
        print("  - 'tax_admin' module deactivated and removed from role permissions")
    end,

    -- 27. Add allowed_actions column to modules table
    -- This lets each module declare which actions the UI should show.
    -- NULL = full CRUD + manage (default). A JSON array restricts to specific actions.
    [27] = function()
        db.query([[
            ALTER TABLE modules ADD COLUMN IF NOT EXISTS allowed_actions TEXT DEFAULT NULL
        ]])
        print("[Tax Copilot] Added 'allowed_actions' column to modules table")
    end,

    -- 28. Set allowed_actions for modules that are NOT full CRUD
    [28] = function()
        -- Single-checkbox "access" modules
        local access_only = {"dashboard", "reports", "tax_bank_accounts", "tax_file"}
        for _, m in ipairs(access_only) do
            db.query([[
                UPDATE modules SET allowed_actions = '["access"]', updated_at = NOW()
                WHERE machine_name = ?
            ]], m)
        end
        print("[Tax Copilot] Set allowed_actions=['access'] for: " .. table.concat(access_only, ", "))

        -- Support chat: read + reply only
        db.query([[
            UPDATE modules SET allowed_actions = '["read","reply"]', updated_at = NOW()
            WHERE machine_name = 'tax_support'
        ]])
        print("[Tax Copilot] Set allowed_actions=['read','reply'] for tax_support")

        -- Update description for tax_support
        db.query([[
            UPDATE modules SET description = 'View and reply to support conversations', updated_at = NOW()
            WHERE machine_name = 'tax_support'
        ]])

        -- Update description for tax_file
        db.query([[
            UPDATE modules SET description = 'Submit tax returns to HMRC', updated_at = NOW()
            WHERE machine_name = 'tax_file'
        ]])
    end,

    -- 29. Remove modules no longer needed for tax_copilot
    -- Note: DELETE instead of SET is_active=false because is_active column
    -- is added later in migration 400_add_module_rbac_columns.
    [29] = function()
        local removed = {"namespace", "tax_extract", "tax_classify", "tax_reconcile", "tax_calculate"}
        for _, m in ipairs(removed) do
            db.query([[
                DELETE FROM modules WHERE machine_name = ?
            ]], m)
        end
        print("[Tax Copilot] Removed modules: " .. table.concat(removed, ", "))

        -- Clean removed modules from existing role permissions
        for _, m in ipairs(removed) do
            local roles_with_mod = db.query([[
                SELECT id FROM namespace_roles
                WHERE permissions IS NOT NULL AND permissions::text LIKE ?
            ]], "%" .. m .. "%")
            if roles_with_mod then
                for _, role in ipairs(roles_with_mod) do
                    db.query([[
                        UPDATE namespace_roles
                        SET permissions = (permissions::jsonb - ?)::text,
                            updated_at = NOW()
                        WHERE id = ?
                    ]], m, role.id)
                end
                if #roles_with_mod > 0 then
                    print("[Tax Copilot] Cleaned '" .. m .. "' from " .. #roles_with_mod .. " role(s)")
                end
            end
        end
    end,

    -- 30. Migrate existing permissions to new action names
    -- Roles that had old CRUD actions on single-checkbox modules need migration to "access"
    [30] = function()
        local access_modules = {"dashboard", "reports", "tax_bank_accounts", "tax_file"}
        for _, m in ipairs(access_modules) do
            -- Find roles that have this module with any old CRUD actions
            local roles = db.query([[
                SELECT id, permissions FROM namespace_roles
                WHERE permissions IS NOT NULL AND permissions::text LIKE ?
            ]], "%" .. m .. "%")
            if roles then
                for _, role in ipairs(roles) do
                    -- Replace whatever actions existed with ["access"]
                    db.query([[
                        UPDATE namespace_roles
                        SET permissions = jsonb_set(
                            permissions::jsonb,
                            ?::text[],
                            '["access"]'::jsonb
                        )::text,
                        updated_at = NOW()
                        WHERE id = ?
                    ]], "{" .. m .. "}", role.id)
                end
                if #roles > 0 then
                    print("[Tax Copilot] Migrated '" .. m .. "' to access-only in " .. #roles .. " role(s)")
                end
            end
        end

        -- Migrate tax_support: old CRUD actions -> read (+ reply if they had update/manage)
        local support_roles = db.query([[
            SELECT id, permissions FROM namespace_roles
            WHERE permissions IS NOT NULL AND permissions::text LIKE '%tax_support%'
        ]])
        if support_roles then
            for _, role in ipairs(support_roles) do
                local ok, perms = pcall(require("cjson").decode, role.permissions)
                if ok and perms and perms.tax_support then
                    local old_actions = perms.tax_support
                    local new_actions = {"read"}
                    -- If they had update, manage, or create, give them reply too
                    for _, a in ipairs(old_actions) do
                        if a == "update" or a == "manage" or a == "create" then
                            new_actions = {"read", "reply"}
                            break
                        end
                    end
                    local new_json = require("cjson").encode(new_actions)
                    db.query([[
                        UPDATE namespace_roles
                        SET permissions = jsonb_set(
                            permissions::jsonb,
                            '{tax_support}'::text[],
                            ?::jsonb
                        )::text,
                        updated_at = NOW()
                        WHERE id = ?
                    ]], new_json, role.id)
                end
            end
            if #support_roles > 0 then
                print("[Tax Copilot] Migrated tax_support actions in " .. #support_roles .. " role(s)")
            end
        end
    end,

    -- 31. Summary of permission module restructure
    [31] = function()
        print("[Tax Copilot] Permission module restructure complete:")
        print("  Single-checkbox (access): dashboard, reports, tax_bank_accounts, tax_file")
        print("  Custom actions (read/reply): tax_support")
        print("  Full CRUD: users, roles, settings, tax_transactions, tax_categories, tax_statements")
        print("  Removed: namespace, tax_extract, tax_classify, tax_reconcile, tax_calculate, tax_admin")
    end,

    -- 32. Create tax_rates table for configurable tax brackets (UUID primary key)
    [32] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS tax_rates (
                uuid VARCHAR(255) NOT NULL DEFAULT gen_random_uuid()::text,
                tax_year VARCHAR(10) NOT NULL UNIQUE,
                personal_allowance NUMERIC NOT NULL DEFAULT 12570,
                personal_allowance_taper_threshold NUMERIC NOT NULL DEFAULT 100000,
                basic_rate NUMERIC NOT NULL DEFAULT 0.20,
                basic_rate_upper NUMERIC NOT NULL DEFAULT 50270,
                higher_rate NUMERIC NOT NULL DEFAULT 0.40,
                higher_rate_upper NUMERIC NOT NULL DEFAULT 125140,
                additional_rate NUMERIC NOT NULL DEFAULT 0.45,
                nic_class4_main_rate NUMERIC NOT NULL DEFAULT 0.06,
                nic_class4_lower_threshold NUMERIC NOT NULL DEFAULT 12570,
                nic_class4_upper_threshold NUMERIC NOT NULL DEFAULT 50270,
                nic_class4_additional_rate NUMERIC NOT NULL DEFAULT 0.02,
                nic_class2_weekly NUMERIC NOT NULL DEFAULT 3.45,
                nic_class2_annual NUMERIC NOT NULL DEFAULT 179.40,
                nic_class2_threshold NUMERIC NOT NULL DEFAULT 12570,
                is_active BOOLEAN NOT NULL DEFAULT true,
                created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
                PRIMARY KEY (uuid)
            )
        ]])
        print("[Tax Copilot] Created tax_rates table with UUID primary key")
    end,

    -- 33. Seed 2025-26 tax rates (current HMRC rates)
    [33] = function()
        db.query([[
            INSERT INTO tax_rates (
                uuid, tax_year,
                personal_allowance, personal_allowance_taper_threshold,
                basic_rate, basic_rate_upper,
                higher_rate, higher_rate_upper,
                additional_rate,
                nic_class4_main_rate, nic_class4_lower_threshold,
                nic_class4_upper_threshold, nic_class4_additional_rate,
                nic_class2_weekly, nic_class2_annual, nic_class2_threshold
            ) VALUES
            (gen_random_uuid()::text, '2025-26', 12570, 100000, 0.20, 50270, 0.40, 125140, 0.45,
             0.06, 12570, 50270, 0.02, 3.45, 179.40, 12570),
            (gen_random_uuid()::text, '2024-25', 12570, 100000, 0.20, 50270, 0.40, 125140, 0.45,
             0.06, 12570, 50270, 0.02, 3.45, 179.40, 12570),
            (gen_random_uuid()::text, '2023-24', 12570, 100000, 0.20, 50270, 0.40, 125140, 0.45,
             0.09, 12570, 50270, 0.02, 3.45, 179.40, 12570)
            ON CONFLICT (tax_year) DO NOTHING
        ]])
        print("[Tax Copilot] Seeded tax_rates for 2023-24, 2024-25, 2025-26")
    end,

    -- 34. Create tax_user_profiles table
    -- Stores user's HMRC-related profile data (hashed NINO, business info, etc.)
    -- NINO is stored as a bcrypt hash — only last 4 chars are kept in plaintext for display.
    [34] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS tax_user_profiles (
                id SERIAL NOT NULL,
                uuid CHARACTER VARYING(255) NOT NULL DEFAULT gen_random_uuid()::text UNIQUE,
                user_id INTEGER NOT NULL UNIQUE,
                user_uuid CHARACTER VARYING(255) NOT NULL UNIQUE,
                nino_hash TEXT,
                nino_last4 CHARACTER VARYING(255),
                has_nino BOOLEAN NOT NULL DEFAULT FALSE,
                hmrc_connected BOOLEAN NOT NULL DEFAULT FALSE,
                default_business_id CHARACTER VARYING(255),
                default_tax_year CHARACTER VARYING(255),
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                PRIMARY KEY (id)
            )
        ]])
        print("[Tax Copilot] Created tax_user_profiles table (NINO stored as bcrypt hash)")
    end,

    -- 35. Add indexes to tax_user_profiles
    [35] = function()
        db.query("CREATE INDEX IF NOT EXISTS idx_tax_user_profiles_user_id ON tax_user_profiles (user_id)")
        db.query("CREATE INDEX IF NOT EXISTS idx_tax_user_profiles_user_uuid ON tax_user_profiles (user_uuid)")
        db.query("CREATE INDEX IF NOT EXISTS idx_tax_user_profiles_uuid ON tax_user_profiles (uuid)")
        print("[Tax Copilot] Added indexes to tax_user_profiles")
    end,

    -- 36. Create hmrc_businesses table
    -- Caches the user's HMRC business details fetched via MTD API
    [36] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS hmrc_businesses (
                id SERIAL NOT NULL,
                uuid CHARACTER VARYING(255) NOT NULL DEFAULT gen_random_uuid()::text UNIQUE,
                user_uuid CHARACTER VARYING(255) NOT NULL,
                business_id CHARACTER VARYING(255) NOT NULL,
                type_of_business CHARACTER VARYING(255) NOT NULL DEFAULT 'self-employment',
                trading_name CHARACTER VARYING(255),
                accounting_type CHARACTER VARYING(255),
                first_accounting_period_start CHARACTER VARYING(255),
                first_accounting_period_end CHARACTER VARYING(255),
                raw_response TEXT,
                fetched_at TIMESTAMP NOT NULL DEFAULT NOW(),
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                PRIMARY KEY (id)
            )
        ]])
        print("[Tax Copilot] Created hmrc_businesses table")
    end,

    -- 37. Add indexes to hmrc_businesses
    [37] = function()
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_businesses_user_uuid ON hmrc_businesses (user_uuid)")
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_businesses_business_id ON hmrc_businesses (business_id)")
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_businesses_uuid ON hmrc_businesses (uuid)")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_hmrc_businesses_user_business
            ON hmrc_businesses (user_uuid, business_id)
        ]])
        print("[Tax Copilot] Added indexes to hmrc_businesses")
    end,

    -- 38. Create hmrc_obligations table
    -- Caches quarterly obligation periods fetched from HMRC
    [38] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS hmrc_obligations (
                id SERIAL NOT NULL,
                uuid CHARACTER VARYING(255) NOT NULL DEFAULT gen_random_uuid()::text UNIQUE,
                user_uuid CHARACTER VARYING(255) NOT NULL,
                business_id CHARACTER VARYING(255) NOT NULL,
                tax_year CHARACTER VARYING(255) NOT NULL,
                period_start CHARACTER VARYING(255) NOT NULL,
                period_end CHARACTER VARYING(255) NOT NULL,
                due_date CHARACTER VARYING(255),
                status CHARACTER VARYING(255) NOT NULL DEFAULT 'Open',
                received_date CHARACTER VARYING(255),
                period_key CHARACTER VARYING(255),
                fetched_at TIMESTAMP NOT NULL DEFAULT NOW(),
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                PRIMARY KEY (id)
            )
        ]])
        print("[Tax Copilot] Created hmrc_obligations table")
    end,

    -- 39. Add indexes to hmrc_obligations
    [39] = function()
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_obligations_user_uuid ON hmrc_obligations (user_uuid)")
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_obligations_business_id ON hmrc_obligations (business_id)")
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_obligations_tax_year ON hmrc_obligations (tax_year)")
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_obligations_status ON hmrc_obligations (status)")
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_obligations_uuid ON hmrc_obligations (uuid)")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_hmrc_obligations_period
            ON hmrc_obligations (user_uuid, business_id, period_start, period_end)
        ]])
        print("[Tax Copilot] Added indexes to hmrc_obligations")
    end,

    -- 40. Add encrypted NINO column to tax_user_profiles
    -- Stores AES-encrypted NINO for server-side HMRC API calls
    -- (bcrypt hash is kept for verification, encrypted copy for API usage)
    [40] = function()
        db.query("ALTER TABLE tax_user_profiles ADD COLUMN IF NOT EXISTS nino_encrypted TEXT")
        print("[Tax Copilot] Added nino_encrypted column to tax_user_profiles")
    end,

    -- 41. Create hmrc_tokens table
    -- Stores HMRC OAuth access/refresh tokens per user.
    -- Previously created at runtime via ensureTable() — now a proper migration.
    [41] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS hmrc_tokens (
                id           SERIAL PRIMARY KEY,
                user_uuid    TEXT        NOT NULL UNIQUE,
                access_token TEXT        NOT NULL,
                refresh_token TEXT,
                scope        TEXT,
                expires_at   TIMESTAMP,
                created_at   TIMESTAMP   NOT NULL DEFAULT NOW(),
                updated_at   TIMESTAMP   NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_tokens_user_uuid ON hmrc_tokens (user_uuid)")
        db.query("CREATE INDEX IF NOT EXISTS idx_hmrc_tokens_expires_at ON hmrc_tokens (expires_at)")
        print("[Tax Copilot] Created hmrc_tokens table")
    end,

    -- 42. Add namespace_id to tables missing it + backfill with active namespace
    -- Ensures all tax data is namespace-scoped for multi-tenant isolation.
    -- Safe: adds column with DEFAULT 0, then backfills from the first active namespace.
    [42] = function()
        -- Tables that need namespace_id added
        local tables_to_add = {
            "tax_transactions",
            "tax_user_profiles",
            "hmrc_businesses",
            "hmrc_obligations",
            "hmrc_tokens",
        }

        for _, tbl in ipairs(tables_to_add) do
            -- Check if column already exists (idempotent)
            local col_check = db.query([[
                SELECT 1 FROM information_schema.columns
                WHERE table_name = ? AND column_name = 'namespace_id'
            ]], tbl)
            if not col_check or #col_check == 0 then
                db.query("ALTER TABLE " .. db.escape_identifier(tbl) ..
                    " ADD COLUMN namespace_id INTEGER NOT NULL DEFAULT 0")
                db.query("CREATE INDEX IF NOT EXISTS idx_" .. tbl .. "_namespace_id ON " ..
                    db.escape_identifier(tbl) .. " (namespace_id)")
                print("[Tax Copilot] Added namespace_id to " .. tbl)
            else
                print("[Tax Copilot] namespace_id already exists on " .. tbl)
            end
        end

        -- Backfill: set namespace_id to the tax_copilot namespace (not system)
        -- Uses PROJECT_CODE env var to find the correct namespace.
        -- Falls back to project_code = 'tax_copilot', then first non-system namespace.
        local project_code = os.getenv("PROJECT_CODE") or "tax_copilot"
        local ns = db.query([[
            SELECT id FROM namespaces
            WHERE status = 'active' AND project_code = ?
            ORDER BY id ASC LIMIT 1
        ]], project_code)
        -- Fallback: first non-system active namespace
        if not ns or #ns == 0 then
            ns = db.query([[
                SELECT id FROM namespaces
                WHERE status = 'active' AND slug != 'system'
                ORDER BY id ASC LIMIT 1
            ]])
        end
        if ns and #ns > 0 then
            local ns_id = ns[1].id
            -- All tables with namespace_id (including ones that already had it)
            local all_tables = {
                "tax_bank_accounts",
                "tax_statements",
                "tax_transactions",
                "tax_user_profiles",
                "hmrc_businesses",
                "hmrc_obligations",
                "hmrc_tokens",
            }
            for _, tbl in ipairs(all_tables) do
                local updated = db.query(
                    "UPDATE " .. db.escape_identifier(tbl) ..
                    " SET namespace_id = ? WHERE namespace_id = 0 OR namespace_id IS NULL",
                    ns_id
                )
                local count = updated and updated.affected_rows or 0
                print("[Tax Copilot] Backfilled " .. tbl .. " namespace_id=" .. ns_id .. " (" .. tostring(count) .. " rows)")
            end
        else
            print("[Tax Copilot] WARNING: No active namespace found, skipping backfill")
        end
    end,

    -- =========================================================================
    -- 43. Classification training data table
    --
    -- Stores high-confidence AI classifications and accountant corrections
    -- as training data for building a custom classification model.
    -- Embeddings and MinIO paths are NULL when created by OpsAPI (accountant
    -- corrections) and filled asynchronously by FastAPI background processor.
    -- =========================================================================
    [43] = function()
        local exists = db.query([[
            SELECT 1 FROM information_schema.tables
            WHERE table_name = 'classification_training_data'
        ]])
        if #exists > 0 then
            -- Table exists (possibly from Python auto-create with old schema).
            -- Ensure all required columns exist for the current schema.
            print("[Tax Copilot] classification_training_data exists — ensuring columns are up to date")
            pcall(function() db.query("ALTER TABLE classification_training_data ADD COLUMN IF NOT EXISTS source varchar(50) DEFAULT 'ai_classification'") end)
            pcall(function() db.query("ALTER TABLE classification_training_data ADD COLUMN IF NOT EXISTS original_category varchar(100)") end)
            pcall(function() db.query("ALTER TABLE classification_training_data ADD COLUMN IF NOT EXISTS corrected_by integer") end)
            pcall(function() db.query("ALTER TABLE classification_training_data ADD COLUMN IF NOT EXISTS namespace_id integer DEFAULT 0") end)
            pcall(function() db.query("ALTER TABLE classification_training_data ADD COLUMN IF NOT EXISTS updated_at timestamp DEFAULT NOW()") end)
            -- Ensure pgvector column (may be text from old auto-create)
            pcall(function() db.query("CREATE EXTENSION IF NOT EXISTS vector") end)
            pcall(function()
                -- Ensure embedding column is vector(384) for all-MiniLM-L6-v2.
                -- Handles: text (old Python auto-create), vector(1536) (old OpenAI), or missing.
                local col_info = db.query([[
                    SELECT data_type, udt_name FROM information_schema.columns
                    WHERE table_name = 'classification_training_data' AND column_name = 'embedding'
                ]])
                if col_info and #col_info > 0 then
                    local dt = col_info[1].data_type
                    if dt == "text" then
                        -- Drop existing data (incompatible format) and change type
                        db.query("UPDATE classification_training_data SET embedding = NULL WHERE embedding IS NOT NULL")
                        db.query("ALTER TABLE classification_training_data ALTER COLUMN embedding TYPE vector(384) USING NULL")
                        print("[Tax Copilot] Converted embedding column from text to vector(384)")
                    elseif dt == "USER-DEFINED" then
                        -- Already vector type; check if it's the wrong dimension
                        -- Drop and recreate if needed (NULL out old embeddings since dimensions changed)
                        local check_dim = db.query("SELECT atttypmod FROM pg_attribute WHERE attrelid = 'classification_training_data'::regclass AND attname = 'embedding'")
                        if check_dim and #check_dim > 0 and check_dim[1].atttypmod ~= 388 then
                            -- atttypmod = dims + 4 for pgvector; 384 + 4 = 388
                            db.query("UPDATE classification_training_data SET embedding = NULL")
                            pcall(function() db.query("DROP INDEX IF EXISTS idx_ctd_embedding_hnsw") end)
                            db.query("ALTER TABLE classification_training_data ALTER COLUMN embedding TYPE vector(384) USING NULL")
                            print("[Tax Copilot] Changed embedding column from vector(1536) to vector(384)")
                        end
                    end
                else
                    -- Column missing entirely
                    db.query("ALTER TABLE classification_training_data ADD COLUMN embedding vector(384)")
                    print("[Tax Copilot] Added embedding column as vector(384)")
                end
            end)
            -- Ensure indexes
            pcall(function() db.query("CREATE INDEX IF NOT EXISTS idx_ctd_source ON classification_training_data(source)") end)
            pcall(function() db.query("CREATE INDEX IF NOT EXISTS idx_ctd_namespace ON classification_training_data(namespace_id)") end)
            pcall(function() db.query("CREATE INDEX IF NOT EXISTS idx_ctd_embedding_hnsw ON classification_training_data USING hnsw (embedding vector_cosine_ops)") end)
            pcall(function() db.query("CREATE INDEX IF NOT EXISTS idx_ctd_pending_embedding ON classification_training_data (id) WHERE embedding IS NULL") end)
            print("[Tax Copilot] classification_training_data schema updated")
            return
        end

        -- Ensure pgvector extension is available
        pcall(function()
            db.query("CREATE EXTENSION IF NOT EXISTS vector")
        end)

        schema.create_table("classification_training_data", {
            { "id",                types.serial },
            { "uuid",              types.varchar({ unique = true }) },
            { "transaction_uuid",  types.text },
            { "user_id",           types.integer },
            { "source",            types.varchar },                        -- ai_classification | accountant_correction
            { "original_category", types.varchar({ null = true }) },       -- AI's category before accountant changed it
            { "corrected_by",      types.integer({ null = true }) },       -- accountant user_id
            { "description",       types.text },
            { "amount",            "numeric(18,2)" },
            { "transaction_type",  types.varchar },
            { "transaction_date",  types.varchar({ null = true }) },
            { "category",          types.varchar },                        -- final category (after correction if any)
            { "hmrc_category",     types.varchar },
            { "confidence",        "numeric(5,4)" },
            { "is_tax_deductible", types.boolean({ default = false }) },
            { "reasoning",         types.text({ null = true }) },
            { "classified_by",     types.varchar({ null = true }) },
            { "minio_path",        types.text({ null = true }) },          -- filled by FastAPI
            { "namespace_id",      types.integer({ default = 0 }) },
            { "created_at",        types.time({ default = db.raw("NOW()") }) },
            { "updated_at",        types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
        })

        -- Native pgvector column (384 dimensions for all-MiniLM-L6-v2 sentence-transformer)
        -- Added via raw SQL because Lapis schema builder doesn't know the vector type.
        -- NULL when created by OpsAPI; filled by FastAPI background processor.
        db.query("ALTER TABLE classification_training_data ADD COLUMN embedding vector(384)")

        -- Unique constraint on transaction_uuid (idempotency)
        db.query("ALTER TABLE classification_training_data ADD CONSTRAINT uq_ctd_transaction_uuid UNIQUE (transaction_uuid)")

        -- Standard indexes
        schema.create_index("classification_training_data", "uuid")
        schema.create_index("classification_training_data", "transaction_uuid")
        schema.create_index("classification_training_data", "user_id")
        schema.create_index("classification_training_data", "source")
        schema.create_index("classification_training_data", "category")
        schema.create_index("classification_training_data", "created_at")
        schema.create_index("classification_training_data", "namespace_id")

        -- HNSW index for fast approximate nearest-neighbor search on embeddings.
        -- cosine distance (vector_cosine_ops) matches the similarity metric used
        -- by the Python search_similar() query.
        db.query([[
            CREATE INDEX idx_ctd_embedding_hnsw
            ON classification_training_data
            USING hnsw (embedding vector_cosine_ops)
        ]])

        -- Partial index: records awaiting embedding generation
        db.query("CREATE INDEX idx_ctd_pending_embedding ON classification_training_data (id) WHERE embedding IS NULL")

        print("[Tax Copilot] Created classification_training_data table with pgvector embedding")
    end,

    -- 44. Seed 9 additional transaction categories from accountant analysis
    -- Adds categories identified from real accountant-classified bank statements
    -- that were missing from the original seed (migration [6]).
    [44] = function()
        local function get_hmrc_id(key)
            local result = db.select("id FROM tax_hmrc_categories WHERE key = ?", key)
            return result and result[1] and result[1].id or nil
        end

        local new_categories = {
            -- Tax-deductible expense categories
            { key = "cost_of_sales", label = "Cost of Sales", type = "EXPENSE", hmrc_key = "cost_of_goods", is_deductible = true, rate = 1.0, desc = "Direct costs of goods sold or services delivered", examples = "COGS, cost of production, direct labour costs, manufacturing costs" },
            { key = "printing_and_reproduction", label = "Printing & Reproduction", type = "EXPENSE", hmrc_key = "telephone_office", is_deductible = true, rate = 1.0, desc = "Printing, photocopying, and reproduction costs", examples = "Business cards, brochures, document printing, photocopying, leaflets" },
            { key = "motor_expenses", label = "Motor Expenses", type = "EXPENSE", hmrc_key = "car_van_travel", is_deductible = true, rate = 1.0, desc = "Vehicle running costs including fuel, repairs, insurance, road tax, MOT", examples = "Shell, BP, Esso, petrol, diesel, MOT, car insurance, road tax, breakdown cover" },
            { key = "shipping_and_delivery", label = "Shipping & Delivery", type = "EXPENSE", hmrc_key = "telephone_office", is_deductible = true, rate = 1.0, desc = "Courier, freight, and delivery costs", examples = "DPD, DHL, FedEx, Hermes, Evri, courier delivery, freight charges, shipping" },
            { key = "staff_welfare", label = "Staff Welfare", type = "EXPENSE", hmrc_key = "wages_staff", is_deductible = true, rate = 1.0, desc = "Staff welfare expenses (not entertainment)", examples = "Staff refreshments, first aid supplies, team building, staff gifts under HMRC limits" },
            { key = "general_admin_expenses", label = "General Administrative Expenses", type = "EXPENSE", hmrc_key = "telephone_office", is_deductible = true, rate = 1.0, desc = "General office and administrative expenses not elsewhere classified", examples = "Office maintenance, waste disposal, shredding, fire extinguisher servicing" },
            -- Non-deductible / balance sheet categories
            { key = "directors_loan_account", label = "Directors Loan Account", type = "EXPENSE", hmrc_key = nil, is_deductible = false, rate = 0.0, desc = "Movements on directors loan account (balance sheet, not P&L)", examples = "DLA repayment, loan to director, director loan repayment" },
            { key = "loan_repayments", label = "Loan Repayments", type = "EXPENSE", hmrc_key = nil, is_deductible = false, rate = 0.0, desc = "Capital repayments on loans (not deductible; interest portion is separate)", examples = "Bounce Back Loan repayment, bank loan repayment, commercial loan repayment" },
            { key = "dividend_payments", label = "Dividend Payments", type = "EXPENSE", hmrc_key = nil, is_deductible = false, rate = 0.0, desc = "Dividend distributions to shareholders (not a business expense)", examples = "Interim dividend, final dividend, shareholder distribution" },
        }

        local count = 0
        for _, cat in ipairs(new_categories) do
            local exists = db.select("id FROM tax_categories WHERE key = ?", cat.key)
            if not exists or #exists == 0 then
                local hmrc_id = cat.hmrc_key and get_hmrc_id(cat.hmrc_key) or db.NULL
                db.query([[
                    INSERT INTO tax_categories (uuid, key, label, hmrc_category_id, is_tax_deductible, deduction_rate, type, description, examples, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), cat.key, cat.label, hmrc_id, cat.is_deductible, cat.rate, cat.type, cat.desc, cat.examples, true)
                count = count + 1
            end
        end

        print("[Tax Copilot] Seeded " .. count .. " new transaction categories from accountant analysis")
    end,

    -- 45. Merge overlapping categories that map to the same HMRC box.
    -- motor_expenses → travel_expense (both travelCosts)
    -- computer_and_internet_expenses → software_subscriptions (both adminCosts)
    -- post_and_stationery → shipping_and_delivery (both adminCosts)
    [45] = function()
        -- Remap transactions that used the old category keys to the merged keys
        local merges = {
            { old = "motor_expenses", new = "travel_expense" },
            { old = "computer_and_internet_expenses", new = "software_subscriptions" },
            { old = "post_and_stationery", new = "shipping_and_delivery" },
        }

        local total_remapped = 0
        for _, merge in ipairs(merges) do
            local result = db.query(
                "UPDATE tax_transactions SET category = ? WHERE category = ?",
                merge.new, merge.old
            )
            local count = result and result.affected_rows or 0
            if count > 0 then
                print("[Tax Copilot] Remapped " .. count .. " transactions: " .. merge.old .. " → " .. merge.new)
            end
            total_remapped = total_remapped + count
        end

        -- Deactivate the old categories (keep for audit trail, don't delete)
        db.query([[
            UPDATE tax_categories SET is_active = false, updated_at = NOW()
            WHERE key IN ('motor_expenses', 'computer_and_internet_expenses', 'post_and_stationery')
        ]])

        -- Update shipping_and_delivery to include stationery in label/description
        db.query([[
            UPDATE tax_categories
            SET label = 'Postage, Shipping & Delivery',
                description = 'Postage, stationery, courier, freight, and delivery costs',
                examples = 'Royal Mail, DPD, DHL, FedEx, Hermes, Evri, stamps, envelopes, Staples, courier delivery, freight charges, shipping',
                updated_at = NOW()
            WHERE key = 'shipping_and_delivery'
        ]])

        print("[Tax Copilot] Merged 3 overlapping categories, remapped " .. total_remapped .. " transactions")
    end,

    -- 46. Create classification_reference_data table
    -- Stores accountant-classified transactions from external bank statements
    -- as gold-standard reference data for AI similarity search.
    -- Separate from classification_training_data (real user corrections).
    [46] = function()
        -- Requires pgvector extension (already created in migration [43])
        schema.create_table("classification_reference_data", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "description", types.text },
            { "description_raw", types.text },
            { "amount", "numeric(18,2) NOT NULL" },
            { "transaction_type", types.varchar },
            { "transaction_date", types.varchar({ null = true }) },
            { "category", types.varchar },
            { "hmrc_category", types.varchar({ null = true }) },
            { "confidence", "numeric(5,4) NOT NULL DEFAULT 1.0" },
            { "is_tax_deductible", types.boolean({ default = false }) },
            { "reasoning", types.text({ null = true }) },
            { "original_label", types.varchar({ null = true }) },
            { "client_business_type", types.varchar },
            { "user_profile_type", types.varchar({ null = true }) },
            { "industry", types.varchar({ null = true }) },
            { "source_file", types.varchar },
            { "row_index", types.integer },
            { "embedding", "vector(384)" },
            { "namespace_id", types.integer({ default = 0 }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        -- Standard indexes
        schema.create_index("classification_reference_data", "uuid")
        schema.create_index("classification_reference_data", "category")
        schema.create_index("classification_reference_data", "client_business_type")
        schema.create_index("classification_reference_data", "industry")
        schema.create_index("classification_reference_data", "source_file")
        schema.create_index("classification_reference_data", "created_at")
        schema.create_index("classification_reference_data", "namespace_id")

        -- Composite unique for idempotent re-imports
        db.query([[
            CREATE UNIQUE INDEX idx_crd_source_row
            ON classification_reference_data (source_file, row_index)
        ]])

        -- HNSW index for fast similarity search (same as classification_training_data)
        db.query([[
            CREATE INDEX idx_crd_embedding_hnsw
            ON classification_reference_data
            USING hnsw (embedding vector_cosine_ops)
        ]])

        -- Partial index for records awaiting embedding generation
        db.query("CREATE INDEX idx_crd_pending_embedding ON classification_reference_data (id) WHERE embedding IS NULL")

        print("[Tax Copilot] Created classification_reference_data table with pgvector embedding")
    end,

    -- 47. Seed classification_reference_data with accountant-classified transactions
    -- Client C (Amazon seller, ecommerce) and Client D (Construction company).
    -- Source: 600 raw transactions from Numbers files → 599 parsed (1 "multiple
    -- transactions" aggregator row skipped) → 183 deduped rows using amount-banded
    -- strategy: group by (description, category, hmrc_category, business_type,
    -- profile_type, industry, transaction_type, amount_band) where bands are
    -- small (<£50), medium (£50-200), large (£200+). Keeps first row per group.
    -- Per profile: amazon_seller=35, construction_company=148.
    -- See scripts/dedupe_reference_data.py for the regenerator.
    [47] = function()
        local count = 0

        -- Load SQL from external file to avoid LuaJIT string-size segfaults
        local sql_path = debug.getinfo(1, "S").source:match("@(.*/)")
            .. "sql/047_seed_classification_reference_data.sql"
        local f = assert(io.open(sql_path, "r"))
        local sql = f:read("*a")
        f:close()

        db.query(sql)
        local result = db.select("COUNT(*) as cnt FROM classification_reference_data")
        count = result and result[1] and result[1].cnt or 0
        print("[Tax Copilot] Seeded " .. count .. " deduped accountant reference transactions (Client C + D)")
    end,

    -- 48. Add profession/industry fields to tax_user_profiles
    -- Needed so the AI classifier can factor in the user's business type
    -- (e.g., "Shell £45" is deductible for a taxi driver but personal for a dev).
    [48] = function()
        db.query("ALTER TABLE tax_user_profiles ADD COLUMN IF NOT EXISTS profession VARCHAR(255)")
        db.query("ALTER TABLE tax_user_profiles ADD COLUMN IF NOT EXISTS industry VARCHAR(255)")
        db.query("ALTER TABLE tax_user_profiles ADD COLUMN IF NOT EXISTS business_description TEXT")
        db.query("CREATE INDEX IF NOT EXISTS idx_tax_user_profiles_profession ON tax_user_profiles (profession)")
        print("[Tax Copilot] Added profession, industry, business_description to tax_user_profiles")
    end,

    -- 49. Add classification metadata fields to tax_transactions
    -- Tracks how each transaction was classified (source), its cleaned merchant name
    -- (for pattern matching / RAG lookup), and whether it's a business expense.
    [49] = function()
        db.query("ALTER TABLE tax_transactions ADD COLUMN IF NOT EXISTS classification_source VARCHAR(100)")
        db.query("ALTER TABLE tax_transactions ADD COLUMN IF NOT EXISTS cleaned_merchant_name VARCHAR(500)")
        db.query("ALTER TABLE tax_transactions ADD COLUMN IF NOT EXISTS is_business_expense BOOLEAN DEFAULT TRUE")
        db.query("CREATE INDEX IF NOT EXISTS idx_tax_txn_cleaned_merchant ON tax_transactions (cleaned_merchant_name)")
        print("[Tax Copilot] Added classification_source, cleaned_merchant_name, is_business_expense to tax_transactions")
    end,

    -- ===========================================================================
    -- 50. Error Catalog + i18n Notification System
    -- ===========================================================================
    -- Three tables powering a unified, multi-language error + notification system:
    --
    --   message_catalog       Canonical list of error / notification codes.
    --   message_translations  Per-locale user-facing messages for each code.
    --   error_occurrences     Audit trail linking every user-visible error back
    --                         to the raw exception that caused it (admin only).
    --
    -- All primary keys are UUIDs. The `code` column on message_catalog is the
    -- developer-facing identifier (e.g. AUTH_401, TAX_CALC_003) and is UNIQUE.
    [50] = function()
        -- message_catalog ------------------------------------------------------
        db.query([[
            CREATE TABLE IF NOT EXISTS message_catalog (
                uuid VARCHAR(255) NOT NULL DEFAULT gen_random_uuid()::text,
                code VARCHAR(64) NOT NULL UNIQUE,
                category VARCHAR(16) NOT NULL DEFAULT 'error',
                severity VARCHAR(16) NOT NULL DEFAULT 'error',
                http_status INTEGER,
                default_locale VARCHAR(8) NOT NULL DEFAULT 'en',
                developer_note TEXT,
                is_active BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                PRIMARY KEY (uuid),
                CONSTRAINT message_catalog_category_ck
                    CHECK (category IN ('error','warning','info','success')),
                CONSTRAINT message_catalog_severity_ck
                    CHECK (severity IN ('error','warn','info'))
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_message_catalog_code ON message_catalog (code)")
        db.query("CREATE INDEX IF NOT EXISTS idx_message_catalog_category ON message_catalog (category)")
        db.query("CREATE INDEX IF NOT EXISTS idx_message_catalog_active ON message_catalog (is_active)")

        -- message_translations -------------------------------------------------
        db.query([[
            CREATE TABLE IF NOT EXISTS message_translations (
                uuid VARCHAR(255) NOT NULL DEFAULT gen_random_uuid()::text,
                catalog_uuid VARCHAR(255) NOT NULL
                    REFERENCES message_catalog(uuid) ON DELETE CASCADE,
                locale VARCHAR(8) NOT NULL,
                user_message TEXT NOT NULL,
                title VARCHAR(255),
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                PRIMARY KEY (uuid),
                CONSTRAINT message_translations_catalog_locale_uk
                    UNIQUE (catalog_uuid, locale)
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_message_translations_catalog ON message_translations (catalog_uuid)")
        db.query("CREATE INDEX IF NOT EXISTS idx_message_translations_locale ON message_translations (locale)")

        -- error_occurrences ----------------------------------------------------
        -- Every time middleware catches an error we write one row here. Admins
        -- browse these in /admin/errors for triage. `raw_error` and `stack_trace`
        -- are never exposed to end users.
        db.query([[
            CREATE TABLE IF NOT EXISTS error_occurrences (
                uuid VARCHAR(255) NOT NULL DEFAULT gen_random_uuid()::text,
                catalog_uuid VARCHAR(255)
                    REFERENCES message_catalog(uuid) ON DELETE SET NULL,
                code VARCHAR(64) NOT NULL,
                correlation_id VARCHAR(64) NOT NULL,
                raw_error TEXT,
                stack_trace TEXT,
                endpoint TEXT,
                http_method VARCHAR(16),
                http_status INTEGER,
                user_uuid VARCHAR(255),
                tenant_namespace VARCHAR(255),
                request_context JSONB,
                app_context JSONB,
                user_agent TEXT,
                ip_address INET,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                PRIMARY KEY (uuid)
            )
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_error_occurrences_code_created ON error_occurrences (code, created_at DESC)")
        db.query("CREATE INDEX IF NOT EXISTS idx_error_occurrences_correlation ON error_occurrences (correlation_id)")
        db.query("CREATE INDEX IF NOT EXISTS idx_error_occurrences_user_created ON error_occurrences (user_uuid, created_at DESC)")
        db.query("CREATE INDEX IF NOT EXISTS idx_error_occurrences_created ON error_occurrences (created_at DESC)")
        db.query("CREATE INDEX IF NOT EXISTS idx_error_occurrences_tenant ON error_occurrences (tenant_namespace)")

        print("[Tax Copilot] Created message_catalog, message_translations, error_occurrences")
    end,

    -- 51. Seed English catalog + translations for the initial code set.
    -- Safe to re-run: uses ON CONFLICT (code) DO NOTHING.
    -- Adding a new code = append a row + translation. No code change needed.
    [51] = function()
        -- Helper: insert a catalog row + English translation atomically.
        -- Using a DO block so the translation can reference the generated UUID.
        db.query([[
            DO $$
            DECLARE
                v_catalog_uuid VARCHAR(255);
                seed_row RECORD;
            BEGIN
                FOR seed_row IN
                    SELECT * FROM (VALUES
                        -- code, category, severity, http_status, title, user_message, developer_note
                        ('SYSTEM_500', 'error', 'error', 500,
                         'Something went wrong',
                         'Something went wrong on our side. Please try again in a moment. If it keeps happening, contact support and share this reference.',
                         'Unclassified exception fallback. Always accompanied by a stack trace in error_occurrences.'),
                        ('SYSTEM_503', 'error', 'error', 503,
                         'Service unavailable',
                         'The service is temporarily unavailable. Please try again shortly.',
                         'Upstream health check failed or dependency unreachable.'),
                        ('VALIDATION_400', 'error', 'warn', 400,
                         'Check your details',
                         'Some of the details you entered don''t look right. Please review and try again.',
                         'Request body / query validation failed. Include field errors in app_context.'),
                        ('RATE_LIMIT_429', 'error', 'warn', 429,
                         'Too many attempts',
                         'You''ve made too many attempts. Please wait a moment and try again.',
                         'slowapi rate limit triggered.'),

                        ('AUTH_401', 'error', 'warn', 401,
                         'Sign in required',
                         'Please sign in to continue.',
                         'Missing or invalid JWT.'),
                        ('AUTH_403', 'error', 'warn', 403,
                         'Access denied',
                         'You don''t have permission to do that.',
                         'Role check failed (ROLE_ADMIN / ROLE_ACCOUNTANT etc.).'),
                        ('AUTH_EXPIRED', 'error', 'warn', 401,
                         'Session expired',
                         'Your session has expired. Please sign in again.',
                         'JWT exp claim in the past.'),
                        ('AUTH_INVALID_CREDENTIALS', 'error', 'warn', 401,
                         'Invalid credentials',
                         'The email or password you entered is incorrect.',
                         'Lapis /auth/login returned 401.'),
                        ('AUTH_ACCOUNT_LOCKED', 'error', 'error', 423,
                         'Account locked',
                         'Your account is temporarily locked. Please contact support.',
                         'Too many failed login attempts.'),

                        ('UPLOAD_PDF_001', 'error', 'warn', 400,
                         'Unable to read file',
                         'We couldn''t read the file you uploaded. Please make sure it''s a valid PDF, image, CSV or Excel file.',
                         'Raised by pdf_processor when the uploaded bytes match no known format.'),
                        ('UPLOAD_PDF_002', 'error', 'warn', 413,
                         'File too large',
                         'The file you uploaded is too large. Please upload a file smaller than {max_mb} MB.',
                         'Exceeds settings.max_upload_size_mb.'),
                        ('UPLOAD_PDF_003', 'error', 'warn', 415,
                         'Unsupported file type',
                         'We can''t process files of this type. Please upload a PDF, image, CSV or Excel file.',
                         'Extension not in supported list.'),

                        ('EXTRACT_001', 'error', 'warn', 422,
                         'No transactions found',
                         'We couldn''t find any transactions in this statement. Please check it''s the right file and try again.',
                         'Extractor returned 0 transactions.'),
                        ('EXTRACT_002', 'error', 'error', 502,
                         'Extraction service unavailable',
                         'We''re having trouble reading statements right now. Please try again in a few minutes.',
                         'All LLM providers failed (Claude + OpenAI).'),
                        ('EXTRACT_003', 'warning', 'warn', 200,
                         'Low-confidence extraction',
                         'We extracted your transactions but some values may need review. Please double-check before continuing.',
                         'Confidence below 0.7.'),

                        ('CLASSIFY_001', 'error', 'error', 502,
                         'Classification service unavailable',
                         'We couldn''t classify your transactions right now. Please try again shortly.',
                         'All LLM providers failed during classification.'),
                        ('CLASSIFY_002', 'error', 'warn', 404,
                         'Statement not found',
                         'We couldn''t find that statement. It may have been removed.',
                         'Statement UUID not in current user''s namespace.'),

                        ('RECONCILE_001', 'error', 'warn', 422,
                         'Reconciliation failed',
                         'We couldn''t match all your transactions. Please review and try again.',
                         'Reconciliation rules produced unresolvable conflicts.'),

                        ('TAX_CALC_001', 'error', 'warn', 422,
                         'Calculation input incomplete',
                         'Some required information is missing from your return. Please fill in the highlighted sections.',
                         'Tax calculator validator rejected input.'),
                        ('TAX_CALC_002', 'error', 'error', 500,
                         'Calculation failed',
                         'We couldn''t complete your tax calculation. Please try again or contact support.',
                         'Unhandled exception in tax_calculator.'),
                        ('TAX_CALC_003', 'warning', 'warn', 200,
                         'Figures differ from HMRC',
                         'Our calculation differs from HMRC''s preview. Please review the breakdown.',
                         'Local vs. HMRC preview diff exceeded tolerance.'),

                        ('HMRC_AUTH_001', 'error', 'warn', 401,
                         'HMRC not connected',
                         'Please connect your HMRC account to continue.',
                         'No HMRC OAuth token on file for this user.'),
                        ('HMRC_AUTH_002', 'error', 'warn', 401,
                         'HMRC session expired',
                         'Your HMRC session has expired. Please reconnect HMRC.',
                         'HMRC returned 401; refresh token flow not yet wired.'),
                        ('HMRC_SUBMIT_001', 'error', 'warn', 400,
                         'HMRC rejected submission',
                         'HMRC rejected your submission. Please review the details and try again.',
                         'HMRC 400 RULE_* error; specific rule in app_context.'),
                        ('HMRC_SUBMIT_002', 'error', 'error', 502,
                         'HMRC unavailable',
                         'HMRC is temporarily unavailable. Please try again in a few minutes.',
                         'HMRC 5xx or timeout.'),
                        ('HMRC_NOT_FOUND_404', 'error', 'warn', 404,
                         'HMRC record not found',
                         'HMRC couldn''t find the record you''re looking for. Please check your HMRC registration and try again.',
                         'HMRC 404 MATCHING_RESOURCE_NOT_FOUND.'),

                        ('NOTIF_INFO_001', 'info', 'info', NULL,
                         'Heads up',
                         '{message}',
                         'Generic in-app info toast; message passed via app_context.'),
                        ('NOTIF_WARNING_001', 'warning', 'warn', NULL,
                         'Please review',
                         '{message}',
                         'Generic in-app warning; message passed via app_context.'),
                        ('NOTIF_SUCCESS_001', 'success', 'info', NULL,
                         'All done',
                         'Your changes have been saved.',
                         'Generic success toast.'),
                        ('NOTIF_SUCCESS_002', 'success', 'info', NULL,
                         'Submission successful',
                         'Your submission to HMRC was successful. Reference: {reference}.',
                         'HMRC submission receipt confirmation.')
                    ) AS t(code, category, severity, http_status, title, user_message, developer_note)
                LOOP
                    INSERT INTO message_catalog (code, category, severity, http_status, developer_note)
                    VALUES (seed_row.code, seed_row.category, seed_row.severity, seed_row.http_status, seed_row.developer_note)
                    ON CONFLICT (code) DO NOTHING
                    RETURNING uuid INTO v_catalog_uuid;

                    -- If ON CONFLICT skipped the insert, look up the existing uuid
                    IF v_catalog_uuid IS NULL THEN
                        SELECT uuid INTO v_catalog_uuid FROM message_catalog WHERE code = seed_row.code;
                    END IF;

                    INSERT INTO message_translations (catalog_uuid, locale, user_message, title)
                    VALUES (v_catalog_uuid, 'en', seed_row.user_message, seed_row.title)
                    ON CONFLICT (catalog_uuid, locale) DO NOTHING;
                END LOOP;
            END $$;
        ]])

        local result = db.select("COUNT(*) as cnt FROM message_catalog")
        local count = result and result[1] and result[1].cnt or 0
        print("[Tax Copilot] Seeded message_catalog (" .. count .. " codes) + English translations")
    end,

    -- 52. Seed notification-specific catalog codes used by the Python
    -- send_catalog_notification helper (Phase E). Translations themselves
    -- live in backend/app/errors/translations/*.json and are loaded on
    -- FastAPI startup, so we do NOT seed message_translations here —
    -- that would duplicate the source of truth.
    --
    -- Idempotent: ON CONFLICT (code) DO NOTHING. Safe to re-run; safe to
    -- add more codes in a future migration.
    [52] = function()
        db.query([[
            INSERT INTO message_catalog (code, category, severity, http_status, developer_note)
            VALUES
                ('NOTIF_EXTRACT_COMPLETE', 'success', 'info', NULL,
                 'Push/toast fired by /api/extract when extraction finishes. Placeholders: {count}.'),
                ('NOTIF_CLASSIFY_COMPLETE', 'success', 'info', NULL,
                 'Push/toast fired by /api/classify when classification finishes. Placeholders: {count}.'),
                ('NOTIF_HMRC_OBLIGATIONS_UPDATED', 'info', 'info', NULL,
                 'Push fired when fetch_obligations discovers new obligations. Placeholders: {body}.')
            ON CONFLICT (code) DO NOTHING
        ]])

        local result = db.select("COUNT(*) as cnt FROM message_catalog WHERE code LIKE 'NOTIF_%'")
        local count = result and result[1] and result[1].cnt or 0
        print("[Tax Copilot] Seeded notification codes (" .. count .. " NOTIF_* rows in catalog)")
    end,

    -- 53. Seed CLASSIFY_003 — the "partial success" notice code. Attached
    -- as a notice on the classify 200 response when cloud AI providers
    -- failed but Ollama filled in, so the user gets a toast rather than
    -- finding out silently. Placeholder: {fallback_count}.
    [53] = function()
        db.query([[
            INSERT INTO message_catalog (code, category, severity, http_status, developer_note)
            VALUES
                ('CLASSIFY_003', 'warning', 'warn', NULL,
                 'Attached as a notice to classify 2xx when cloud AI providers failed and Ollama filled in. Placeholder: {fallback_count}.')
            ON CONFLICT (code) DO NOTHING
        ]])
        print("[Tax Copilot] Seeded CLASSIFY_003 partial-success notice code")
    end,

    -- 54. Add profile_type to classification_training_data
    -- Records which business profile was active during classification,
    -- enabling per-profile accuracy analysis and RAG boosting.
    [54] = function()
        db.query("ALTER TABLE classification_training_data ADD COLUMN IF NOT EXISTS profile_type VARCHAR(100)")
        db.query("CREATE INDEX IF NOT EXISTS idx_ctd_profile_type ON classification_training_data (profile_type)")
        print("[Tax Copilot] Added profile_type to classification_training_data")
    end,

    -- 55. Seed health_and_safety reference data (Client A + B)
    -- 209 deduped accountant-classified transactions for the health & safety profile.
    -- Uses ON CONFLICT so existing C+D data (migration 47) is untouched.
    [55] = function()
        local sql_path = debug.getinfo(1, "S").source:match("@(.*/)")
            .. "sql/048_seed_health_safety_reference_data.sql"
        local f = assert(io.open(sql_path, "r"))
        local sql = f:read("*a")
        f:close()

        db.query(sql)
        local result = db.select("COUNT(*) as cnt FROM classification_reference_data WHERE client_business_type = 'health_and_safety'")
        local count = result and result[1] and result[1].cnt or 0
        print("[Tax Copilot] Seeded " .. count .. " health_and_safety reference transactions (Client A + B)")
    end,
}
