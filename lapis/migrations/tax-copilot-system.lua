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
}
