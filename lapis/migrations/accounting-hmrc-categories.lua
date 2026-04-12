--[[
    HMRC Categories & Bank Transaction Tags
    ========================================

    Adds:
    1. hmrc_expense_categories table (SA103F standard categories)
    2. tags and hmrc_category_id columns to accounting_bank_transactions
    3. Seed the 10 HMRC SA103F expense categories
    4. Seed dummy bank transactions for testing
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

local function column_exists(table_name, column_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.columns
            WHERE table_name = ? AND column_name = ?
        ) as exists
    ]], table_name, column_name)
    return result and result[1] and result[1].exists
end

return {
    -- [1] Create HMRC expense categories table
    function()
        if table_exists("hmrc_expense_categories") then return end

        db.query([[
            CREATE TABLE hmrc_expense_categories (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL DEFAULT 0,
                box_number INTEGER NOT NULL,
                key TEXT NOT NULL,
                label TEXT NOT NULL,
                description TEXT,
                is_deductible BOOLEAN DEFAULT true,
                is_active BOOLEAN DEFAULT true,
                sort_order INTEGER DEFAULT 0,
                keywords JSONB DEFAULT '[]',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        db.query("CREATE UNIQUE INDEX idx_hmrc_categories_key ON hmrc_expense_categories(key) WHERE namespace_id = 0")
        db.query("CREATE INDEX idx_hmrc_categories_namespace ON hmrc_expense_categories(namespace_id)")
        db.query("CREATE INDEX idx_hmrc_categories_box ON hmrc_expense_categories(box_number)")
    end,

    -- [2] Add tags and hmrc_category_id columns to bank transactions
    function()
        if not table_exists("accounting_bank_transactions") then return end

        if not column_exists("accounting_bank_transactions", "tags") then
            db.query("ALTER TABLE accounting_bank_transactions ADD COLUMN tags JSONB DEFAULT '[]'")
        end

        if not column_exists("accounting_bank_transactions", "hmrc_category_id") then
            db.query("ALTER TABLE accounting_bank_transactions ADD COLUMN hmrc_category_id BIGINT DEFAULT NULL")
        end

        if not column_exists("accounting_bank_transactions", "hmrc_category_key") then
            db.query("ALTER TABLE accounting_bank_transactions ADD COLUMN hmrc_category_key TEXT DEFAULT NULL")
        end

        -- Add user_category for custom user-defined categories
        if not column_exists("accounting_bank_transactions", "user_category") then
            db.query("ALTER TABLE accounting_bank_transactions ADD COLUMN user_category TEXT DEFAULT NULL")
        end

        -- Index for tag-based searches (GIN index on JSONB)
        pcall(function()
            db.query("CREATE INDEX idx_bank_txn_tags ON accounting_bank_transactions USING GIN (tags)")
        end)
        pcall(function()
            db.query("CREATE INDEX idx_bank_txn_hmrc_cat ON accounting_bank_transactions(hmrc_category_key)")
        end)
    end,

    -- [3] Seed the 10 HMRC SA103F expense categories
    function()
        if not table_exists("hmrc_expense_categories") then return end

        local categories = {
            {
                box = 17, key = "costOfGoods", label = "Cost of Goods",
                description = "Cost of goods bought for resale or goods used in providing services",
                is_deductible = true, sort_order = 1,
                keywords = '["stock", "inventory", "materials", "supplies", "wholesale", "raw materials", "packaging", "goods for resale"]'
            },
            {
                box = 19, key = "staffCosts", label = "Staff Costs",
                description = "Employee salaries, wages, bonuses, pensions, benefits, employer NIC",
                is_deductible = true, sort_order = 2,
                keywords = '["salary", "wages", "payroll", "pension", "nic", "national insurance", "bonus", "staff", "employee", "contractor"]'
            },
            {
                box = 20, key = "premisesRunningCosts", label = "Premises Running Costs",
                description = "Rent, rates, power, insurance, and other costs of business premises",
                is_deductible = true, sort_order = 3,
                keywords = '["rent", "rates", "electricity", "gas", "water", "office", "premises", "heating", "council tax", "business rates", "cleaning"]'
            },
            {
                box = 21, key = "maintenanceCosts", label = "Maintenance Costs",
                description = "Repairs and renewals of property, equipment, and vehicles",
                is_deductible = true, sort_order = 4,
                keywords = '["repair", "maintenance", "servicing", "fix", "replacement", "renewal", "plumber", "electrician", "MOT"]'
            },
            {
                box = 22, key = "adminCosts", label = "Admin Costs",
                description = "Phone, fax, stationery, printing, postage, and other office costs",
                is_deductible = true, sort_order = 5,
                keywords = '["phone", "mobile", "internet", "broadband", "stationery", "printing", "postage", "stamps", "office supplies", "amazon", "software", "subscription"]'
            },
            {
                box = 23, key = "travelCosts", label = "Travel Costs",
                description = "Vehicle running costs, train/bus/taxi fares, hotel and meal costs for business travel",
                is_deductible = true, sort_order = 6,
                keywords = '["travel", "train", "bus", "taxi", "uber", "fuel", "petrol", "diesel", "parking", "hotel", "flight", "mileage", "toll", "congestion"]'
            },
            {
                box = 24, key = "advertisingCosts", label = "Advertising Costs",
                description = "Advertising, marketing, and promotional costs",
                is_deductible = true, sort_order = 7,
                keywords = '["advertising", "marketing", "google ads", "facebook ads", "promotion", "flyer", "brochure", "website", "seo", "social media", "campaign"]'
            },
            {
                box = 25, key = "businessEntertainmentCosts", label = "Business Entertainment",
                description = "Entertainment costs for clients and business contacts (NOT tax deductible)",
                is_deductible = false, sort_order = 8,
                keywords = '["entertainment", "client dinner", "restaurant", "hospitality", "event", "gift", "client lunch", "drinks"]'
            },
            {
                box = 29, key = "professionalFees", label = "Professional Fees",
                description = "Accountant, solicitor, surveyor, and other professional fees",
                is_deductible = true, sort_order = 9,
                keywords = '["accountant", "solicitor", "lawyer", "legal", "audit", "consultant", "professional", "advisory", "bookkeeper", "tax agent"]'
            },
            {
                box = 31, key = "otherExpenses", label = "Other Expenses",
                description = "Any other business expenses not covered by the categories above",
                is_deductible = true, sort_order = 10,
                keywords = '["bank charges", "interest", "depreciation", "bad debt", "insurance", "licence", "membership", "trade body"]'
            },
        }

        for _, cat in ipairs(categories) do
            -- Use gen_random_uuid() for migration context (ngx not available)
            db.query([[
                INSERT INTO hmrc_expense_categories (uuid, namespace_id, box_number, key, label, description, is_deductible, sort_order, keywords, created_at, updated_at)
                VALUES (gen_random_uuid()::text, 0, ?, ?, ?, ?, ?, ?, ?::jsonb, NOW(), NOW())
                ON CONFLICT DO NOTHING
            ]],
                cat.box, cat.key, cat.label, cat.description,
                cat.is_deductible, cat.sort_order, cat.keywords
            )
        end
    end,

    -- [4] Seed dummy bank transactions for testing
    function()
        if not table_exists("accounting_bank_transactions") then return end

        -- Only seed if no transactions exist for namespace 1
        local count = db.query("SELECT COUNT(*) as cnt FROM accounting_bank_transactions WHERE namespace_id = 1")
        if count and count[1] and tonumber(count[1].cnt) > 0 then return end

        local transactions = {
            -- Revenue/Income
            { date = "2026-03-01", desc = "Client payment - Web Design Project", amount = 3500.00, type = "credit", balance = 15200.00, payee = "Acme Corp", category = "Sales Revenue", hmrc_key = nil, tags = '["client", "web-design", "project"]' },
            { date = "2026-03-05", desc = "Consulting fee - SEO audit", amount = 1200.00, type = "credit", balance = 16400.00, payee = "Widget Ltd", category = "Service Revenue", hmrc_key = nil, tags = '["consulting", "seo"]' },
            { date = "2026-03-15", desc = "Client retainer - Monthly support", amount = 800.00, type = "credit", balance = 18450.00, payee = "Beta Industries", category = "Service Revenue", hmrc_key = nil, tags = '["retainer", "support", "monthly"]' },

            -- Expenses with HMRC categories
            { date = "2026-03-02", desc = "Amazon - Printer cartridges and paper", amount = -45.99, type = "debit", balance = 15154.01, payee = "Amazon", category = "Office Supplies", hmrc_key = "adminCosts", tags = '["office", "stationery", "amazon"]' },
            { date = "2026-03-03", desc = "Google Workspace monthly subscription", amount = -11.50, type = "debit", balance = 15142.51, payee = "Google", category = "Software", hmrc_key = "adminCosts", tags = '["software", "subscription", "google"]' },
            { date = "2026-03-04", desc = "Train ticket London to Manchester", amount = -89.00, type = "debit", balance = 15053.51, payee = "Trainline", category = "Travel", hmrc_key = "travelCosts", tags = '["travel", "train", "business-trip"]' },
            { date = "2026-03-06", desc = "Office rent - March", amount = -950.00, type = "debit", balance = 14103.51, payee = "Landlord Properties", category = "Rent", hmrc_key = "premisesRunningCosts", tags = '["rent", "office", "monthly"]' },
            { date = "2026-03-07", desc = "British Gas - Electricity bill", amount = -125.30, type = "debit", balance = 13978.21, payee = "British Gas", category = "Utilities", hmrc_key = "premisesRunningCosts", tags = '["utilities", "electricity", "bills"]' },
            { date = "2026-03-08", desc = "Facebook Ads - March campaign", amount = -250.00, type = "debit", balance = 13728.21, payee = "Meta", category = "Marketing", hmrc_key = "advertisingCosts", tags = '["marketing", "facebook", "ads", "campaign"]' },
            { date = "2026-03-09", desc = "Client dinner - Project celebration", amount = -85.60, type = "debit", balance = 13642.61, payee = "The Ivy Restaurant", category = "Entertainment", hmrc_key = "businessEntertainmentCosts", tags = '["entertainment", "client", "dinner"]' },
            { date = "2026-03-10", desc = "Accountant quarterly review", amount = -350.00, type = "debit", balance = 13292.61, payee = "Smith & Co Accountants", category = "Professional Fees", hmrc_key = "professionalFees", tags = '["accountant", "quarterly", "professional"]' },
            { date = "2026-03-11", desc = "Uber business trips x3", amount = -42.50, type = "debit", balance = 13250.11, payee = "Uber", category = "Travel", hmrc_key = "travelCosts", tags = '["taxi", "uber", "travel"]' },
            { date = "2026-03-12", desc = "Plumber - Office toilet repair", amount = -180.00, type = "debit", balance = 13070.11, payee = "Quick Fix Plumbing", category = "Maintenance", hmrc_key = "maintenanceCosts", tags = '["repair", "plumber", "maintenance"]' },
            { date = "2026-03-14", desc = "Domain renewal - company website", amount = -12.99, type = "debit", balance = 13057.12, payee = "GoDaddy", category = "Admin", hmrc_key = "adminCosts", tags = '["domain", "website", "hosting"]' },
            { date = "2026-03-16", desc = "Wholesale stock purchase - widgets", amount = -620.00, type = "debit", balance = 12437.12, payee = "Widget Wholesale Ltd", category = "Cost of Goods", hmrc_key = "costOfGoods", tags = '["stock", "wholesale", "inventory"]' },
            { date = "2026-03-18", desc = "Staff salary - March (Jane Smith)", amount = -2200.00, type = "debit", balance = 10237.12, payee = "Jane Smith", category = "Wages", hmrc_key = "staffCosts", tags = '["salary", "staff", "payroll"]' },
            { date = "2026-03-20", desc = "Bank monthly service fee", amount = -6.50, type = "debit", balance = 10230.62, payee = "Barclays Bank", category = "Bank Charges", hmrc_key = "otherExpenses", tags = '["bank", "charges", "monthly"]' },
            { date = "2026-03-22", desc = "Professional indemnity insurance", amount = -45.00, type = "debit", balance = 10185.62, payee = "Hiscox", category = "Insurance", hmrc_key = "otherExpenses", tags = '["insurance", "professional", "annual"]' },
            { date = "2026-03-25", desc = "Google Ads - Search campaign", amount = -180.00, type = "debit", balance = 10005.62, payee = "Google", category = "Marketing", hmrc_key = "advertisingCosts", tags = '["google", "ads", "marketing", "search"]' },
            { date = "2026-03-28", desc = "Client payment - App Development", amount = 5000.00, type = "credit", balance = 15005.62, payee = "TechStart Ltd", category = "Sales Revenue", hmrc_key = nil, tags = '["client", "app-dev", "project", "milestone"]' },
        }

        for _, txn in ipairs(transactions) do
            local hmrc_key_sql = txn.hmrc_key and ("'" .. txn.hmrc_key .. "'") or "NULL"
            db.query([[
                INSERT INTO accounting_bank_transactions
                (uuid, namespace_id, transaction_date, description, amount, balance, transaction_type, payee, category, hmrc_category_key, tags, created_at, updated_at)
                VALUES (gen_random_uuid()::text, 1, ?, ?, ?, ?, ?, ?, ?, ]] .. hmrc_key_sql .. [[, ?::jsonb, NOW(), NOW())
            ]],
                txn.date, txn.desc, txn.amount, txn.balance, txn.type,
                txn.payee, txn.category, txn.tags
            )
        end
    end,
}
