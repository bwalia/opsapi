--[[
    Accounting System Migrations
    ============================

    A comprehensive double-entry bookkeeping/accounting system with support
    for Chart of Accounts, journal entries, bank transactions, expenses,
    and VAT returns. Designed for UK small business compliance.

    Tables:
    =======
    1. accounting_accounts          - Chart of Accounts (hierarchical)
    2. accounting_journal_entries    - Double-entry journal headers
    3. accounting_journal_lines      - Debit/Credit lines per journal entry
    4. accounting_bank_transactions  - Bank feed / imported transactions
    5. accounting_expenses           - Expense claims and tracking
    6. accounting_vat_returns        - HMRC VAT return periods
    7. (seed) Default UK Chart of Accounts
]]

local db = require("lapis.db")

-- Helper to check if table exists
local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create accounting_accounts table (Chart of Accounts)
    -- ========================================
    [1] = function()
        if table_exists("accounting_accounts") then return end

        db.query([[
            CREATE TABLE accounting_accounts (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                parent_id BIGINT DEFAULT NULL REFERENCES accounting_accounts(id) ON DELETE SET NULL,
                code TEXT NOT NULL,
                name TEXT NOT NULL,
                account_type TEXT NOT NULL CHECK (account_type IN ('asset','liability','equity','revenue','expense')),
                sub_type TEXT,
                description TEXT,
                is_system BOOLEAN DEFAULT false,
                is_active BOOLEAN DEFAULT true,
                normal_balance TEXT NOT NULL CHECK (normal_balance IN ('debit','credit')),
                currency TEXT DEFAULT 'GBP',
                opening_balance DECIMAL(15,2) DEFAULT 0,
                current_balance DECIMAL(15,2) DEFAULT 0,
                depth INTEGER DEFAULT 0,
                path TEXT,
                tax_rate_id BIGINT DEFAULT NULL,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- Unique constraint on code per namespace (only for non-deleted)
        db.query([[
            CREATE UNIQUE INDEX idx_accounting_accounts_namespace_code_unique
            ON accounting_accounts (namespace_id, code)
            WHERE deleted_at IS NULL
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_accounting_accounts_namespace_type ON accounting_accounts (namespace_id, account_type)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_accounts_parent_id ON accounting_accounts (parent_id)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_accounts_is_active ON accounting_accounts (is_active)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_accounts_created_at ON accounting_accounts USING BRIN (created_at)
        ]])
    end,

    -- ========================================
    -- [2] Create accounting_journal_entries table
    -- ========================================
    [2] = function()
        if table_exists("accounting_journal_entries") then return end

        db.query([[
            CREATE TABLE accounting_journal_entries (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                entry_number TEXT NOT NULL,
                entry_date DATE NOT NULL,
                description TEXT NOT NULL,
                reference TEXT,
                source_type TEXT,
                source_id TEXT,
                status TEXT DEFAULT 'posted' CHECK (status IN ('draft','posted','void')),
                total_amount DECIMAL(15,2) NOT NULL DEFAULT 0,
                currency TEXT DEFAULT 'GBP',
                exchange_rate DECIMAL(10,6) DEFAULT 1,
                notes TEXT,
                created_by_uuid TEXT NOT NULL,
                approved_by_uuid TEXT,
                posted_at TIMESTAMP,
                voided_at TIMESTAMP,
                void_reason TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Unique constraint on entry_number per namespace
        db.query([[
            CREATE UNIQUE INDEX idx_accounting_journal_entries_namespace_number_unique
            ON accounting_journal_entries (namespace_id, entry_number)
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_accounting_journal_entries_namespace_date ON accounting_journal_entries (namespace_id, entry_date)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_journal_entries_namespace_status ON accounting_journal_entries (namespace_id, status)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_journal_entries_source ON accounting_journal_entries (source_type, source_id)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_journal_entries_created_at ON accounting_journal_entries USING BRIN (created_at)
        ]])
    end,

    -- ========================================
    -- [3] Create accounting_journal_lines table
    -- ========================================
    [3] = function()
        if table_exists("accounting_journal_lines") then return end

        db.query([[
            CREATE TABLE accounting_journal_lines (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                journal_entry_id BIGINT NOT NULL REFERENCES accounting_journal_entries(id) ON DELETE CASCADE,
                account_id BIGINT NOT NULL REFERENCES accounting_accounts(id),
                debit_amount DECIMAL(15,2) DEFAULT 0,
                credit_amount DECIMAL(15,2) DEFAULT 0,
                description TEXT,
                tax_rate DECIMAL(5,2) DEFAULT 0,
                tax_amount DECIMAL(15,2) DEFAULT 0,
                created_at TIMESTAMP DEFAULT NOW(),
                CONSTRAINT chk_journal_lines_non_negative CHECK (debit_amount >= 0 AND credit_amount >= 0),
                CONSTRAINT chk_journal_lines_single_side CHECK (NOT (debit_amount > 0 AND credit_amount > 0))
            )
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_accounting_journal_lines_journal_entry_id ON accounting_journal_lines (journal_entry_id)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_journal_lines_account_id ON accounting_journal_lines (account_id)
        ]])
    end,

    -- ========================================
    -- [4] Create accounting_bank_transactions table
    -- ========================================
    [4] = function()
        if table_exists("accounting_bank_transactions") then return end

        db.query([[
            CREATE TABLE accounting_bank_transactions (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                bank_account_id BIGINT DEFAULT NULL,
                transaction_date DATE NOT NULL,
                description TEXT NOT NULL,
                amount DECIMAL(15,2) NOT NULL,
                balance DECIMAL(15,2),
                transaction_type TEXT CHECK (transaction_type IN ('credit','debit')),
                reference TEXT,
                payee TEXT,
                category TEXT,
                vat_amount DECIMAL(15,2) DEFAULT 0,
                vat_rate DECIMAL(5,2) DEFAULT 0,
                is_reconciled BOOLEAN DEFAULT false,
                reconciled_journal_id BIGINT DEFAULT NULL REFERENCES accounting_journal_entries(id) ON DELETE SET NULL,
                ai_category_suggestion TEXT,
                ai_vat_suggestion TEXT,
                ai_confidence DECIMAL(3,2),
                import_source TEXT,
                import_batch_id TEXT,
                metadata JSONB DEFAULT '{}',
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_accounting_bank_transactions_namespace_date ON accounting_bank_transactions (namespace_id, transaction_date)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_bank_transactions_namespace_reconciled ON accounting_bank_transactions (namespace_id, is_reconciled)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_bank_transactions_category ON accounting_bank_transactions (category)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_bank_transactions_import_batch ON accounting_bank_transactions (import_batch_id)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_bank_transactions_created_at ON accounting_bank_transactions USING BRIN (created_at)
        ]])
    end,

    -- ========================================
    -- [5] Create accounting_expenses table
    -- ========================================
    [5] = function()
        if table_exists("accounting_expenses") then return end

        db.query([[
            CREATE TABLE accounting_expenses (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                account_id BIGINT DEFAULT NULL REFERENCES accounting_accounts(id) ON DELETE SET NULL,
                bank_transaction_id BIGINT DEFAULT NULL REFERENCES accounting_bank_transactions(id) ON DELETE SET NULL,
                journal_entry_id BIGINT DEFAULT NULL REFERENCES accounting_journal_entries(id) ON DELETE SET NULL,
                expense_date DATE NOT NULL,
                description TEXT NOT NULL,
                amount DECIMAL(15,2) NOT NULL,
                currency TEXT DEFAULT 'GBP',
                category TEXT NOT NULL,
                sub_category TEXT,
                vendor TEXT,
                receipt_url TEXT,
                vat_rate DECIMAL(5,2) DEFAULT 0,
                vat_amount DECIMAL(15,2) DEFAULT 0,
                is_vat_reclaimable BOOLEAN DEFAULT true,
                payment_method TEXT,
                status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','posted')),
                submitted_by_uuid TEXT NOT NULL,
                approved_by_uuid TEXT,
                notes TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_accounting_expenses_namespace_category ON accounting_expenses (namespace_id, category)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_expenses_namespace_date ON accounting_expenses (namespace_id, expense_date)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_expenses_namespace_status ON accounting_expenses (namespace_id, status)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_expenses_submitted_by ON accounting_expenses (submitted_by_uuid)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_expenses_created_at ON accounting_expenses USING BRIN (created_at)
        ]])
    end,

    -- ========================================
    -- [6] Create accounting_vat_returns table
    -- ========================================
    [6] = function()
        if table_exists("accounting_vat_returns") then return end

        db.query([[
            CREATE TABLE accounting_vat_returns (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                period_start DATE NOT NULL,
                period_end DATE NOT NULL,
                status TEXT DEFAULT 'draft' CHECK (status IN ('draft','calculated','submitted','accepted','rejected')),
                box1_vat_due_sales DECIMAL(15,2) DEFAULT 0,
                box2_vat_due_acquisitions DECIMAL(15,2) DEFAULT 0,
                box3_total_vat_due DECIMAL(15,2) DEFAULT 0,
                box4_vat_reclaimed DECIMAL(15,2) DEFAULT 0,
                box5_net_vat DECIMAL(15,2) DEFAULT 0,
                box6_total_sales DECIMAL(15,2) DEFAULT 0,
                box7_total_purchases DECIMAL(15,2) DEFAULT 0,
                box8_total_supplies_eu DECIMAL(15,2) DEFAULT 0,
                box9_total_acquisitions_eu DECIMAL(15,2) DEFAULT 0,
                notes TEXT,
                submitted_at TIMESTAMP,
                submitted_by_uuid TEXT,
                hmrc_receipt_id TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_accounting_vat_returns_namespace_period ON accounting_vat_returns (namespace_id, period_start, period_end)
        ]])
        db.query([[
            CREATE INDEX idx_accounting_vat_returns_namespace_status ON accounting_vat_returns (namespace_id, status)
        ]])
    end,

    -- ========================================
    -- [7] Seed default UK Chart of Accounts
    -- ========================================
    [7] = function()
        if not table_exists("accounting_accounts") then return end

        -- Default UK Chart of Accounts for namespace_id=1
        -- Uses INSERT...ON CONFLICT DO NOTHING to be idempotent
        db.query([[
            INSERT INTO accounting_accounts (uuid, namespace_id, code, name, account_type, normal_balance, is_system, is_active, depth)
            VALUES
                -- Assets (normal_balance = debit)
                ('acct-seed-1000', 1, '1000', 'Bank Account',              'asset',     'debit',  true, true, 0),
                ('acct-seed-1010', 1, '1010', 'Petty Cash',                'asset',     'debit',  true, true, 0),
                ('acct-seed-1100', 1, '1100', 'Accounts Receivable',       'asset',     'debit',  true, true, 0),
                ('acct-seed-1200', 1, '1200', 'Prepayments',               'asset',     'debit',  true, true, 0),
                ('acct-seed-1500', 1, '1500', 'Equipment',                 'asset',     'debit',  true, true, 0),
                ('acct-seed-1510', 1, '1510', 'Accumulated Depreciation',  'asset',     'debit',  true, true, 0),

                -- Liabilities (normal_balance = credit)
                ('acct-seed-2000', 1, '2000', 'Accounts Payable',          'liability', 'credit', true, true, 0),
                ('acct-seed-2100', 1, '2100', 'VAT Payable',               'liability', 'credit', true, true, 0),
                ('acct-seed-2200', 1, '2200', 'PAYE Payable',              'liability', 'credit', true, true, 0),
                ('acct-seed-2300', 1, '2300', 'Loans',                     'liability', 'credit', true, true, 0),

                -- Equity (normal_balance = credit)
                ('acct-seed-3000', 1, '3000', 'Owner''s Equity',           'equity',    'credit', true, true, 0),
                ('acct-seed-3100', 1, '3100', 'Retained Earnings',         'equity',    'credit', true, true, 0),

                -- Revenue (normal_balance = credit)
                ('acct-seed-4000', 1, '4000', 'Sales Revenue',             'revenue',   'credit', true, true, 0),
                ('acct-seed-4010', 1, '4010', 'Service Revenue',           'revenue',   'credit', true, true, 0),
                ('acct-seed-4100', 1, '4100', 'Other Income',              'revenue',   'credit', true, true, 0),
                ('acct-seed-4200', 1, '4200', 'Interest Income',           'revenue',   'credit', true, true, 0),

                -- Expenses (normal_balance = debit)
                ('acct-seed-5000', 1, '5000', 'Cost of Goods Sold',        'expense',   'debit',  true, true, 0),
                ('acct-seed-6000', 1, '6000', 'Rent',                      'expense',   'debit',  true, true, 0),
                ('acct-seed-6010', 1, '6010', 'Utilities',                 'expense',   'debit',  true, true, 0),
                ('acct-seed-6020', 1, '6020', 'Office Supplies',           'expense',   'debit',  true, true, 0),
                ('acct-seed-6030', 1, '6030', 'Marketing',                 'expense',   'debit',  true, true, 0),
                ('acct-seed-6040', 1, '6040', 'Travel',                    'expense',   'debit',  true, true, 0),
                ('acct-seed-6050', 1, '6050', 'Insurance',                 'expense',   'debit',  true, true, 0),
                ('acct-seed-6060', 1, '6060', 'Professional Fees',         'expense',   'debit',  true, true, 0),
                ('acct-seed-6070', 1, '6070', 'Software',                  'expense',   'debit',  true, true, 0),
                ('acct-seed-6080', 1, '6080', 'Entertainment',             'expense',   'debit',  true, true, 0),
                ('acct-seed-6090', 1, '6090', 'Telephone',                 'expense',   'debit',  true, true, 0),
                ('acct-seed-6100', 1, '6100', 'Wages',                     'expense',   'debit',  true, true, 0),
                ('acct-seed-6200', 1, '6200', 'Bank Charges',              'expense',   'debit',  true, true, 0),
                ('acct-seed-6300', 1, '6300', 'Depreciation',              'expense',   'debit',  true, true, 0),
                ('acct-seed-6400', 1, '6400', 'Miscellaneous',             'expense',   'debit',  true, true, 0)
            ON CONFLICT DO NOTHING
        ]])
    end
}
