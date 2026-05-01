--[[
    Invoicing System Migrations
    ===========================

    A comprehensive invoicing system with support for line items, payments,
    tax rates, and invoice number sequences. Integrated with CRM (optional)
    and timesheet modules when available.

    Tables:
    =======
    1. invoices              - Main invoice records (namespace-scoped)
    2. invoice_line_items    - Line items belonging to invoices
    3. invoice_payments      - Payment records against invoices
    4. invoice_tax_rates     - Configurable tax rates per namespace
    5. invoice_sequences     - Auto-increment invoice number sequences
]]

local db = require("lapis.db")

-- Helper to check if table exists
local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create invoices table
    -- ========================================
    [1] = function()
        if table_exists("invoices") then return end

        db.query([[
            CREATE TABLE invoices (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                invoice_number TEXT NOT NULL,
                customer_name TEXT,
                customer_email TEXT,
                customer_address JSONB DEFAULT '{}',
                account_id BIGINT DEFAULT NULL,
                contact_id BIGINT DEFAULT NULL,
                status TEXT DEFAULT 'draft' CHECK (status IN ('draft','sent','paid','partially_paid','overdue','cancelled','void')),
                issue_date DATE NOT NULL DEFAULT CURRENT_DATE,
                due_date DATE,
                currency TEXT DEFAULT 'USD',
                subtotal DECIMAL(15,2) DEFAULT 0,
                tax_amount DECIMAL(15,2) DEFAULT 0,
                discount_amount DECIMAL(15,2) DEFAULT 0,
                total_amount DECIMAL(15,2) DEFAULT 0,
                amount_paid DECIMAL(15,2) DEFAULT 0,
                balance_due DECIMAL(15,2) DEFAULT 0,
                notes TEXT,
                terms TEXT,
                payment_terms_days INTEGER DEFAULT 30,
                owner_user_uuid TEXT NOT NULL,
                billing_address JSONB DEFAULT '{}',
                sent_at TIMESTAMP,
                paid_at TIMESTAMP,
                voided_at TIMESTAMP,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- Unique constraint on invoice_number per namespace (only for non-deleted)
        db.query([[
            CREATE UNIQUE INDEX idx_invoices_namespace_number_unique
            ON invoices (namespace_id, invoice_number)
            WHERE deleted_at IS NULL
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_invoices_namespace_status ON invoices (namespace_id, status)
        ]])
        db.query([[
            CREATE INDEX idx_invoices_owner_user_uuid ON invoices (owner_user_uuid)
        ]])
        db.query([[
            CREATE INDEX idx_invoices_due_date ON invoices (due_date)
        ]])
        db.query([[
            CREATE INDEX idx_invoices_created_at ON invoices USING BRIN (created_at)
        ]])

        -- Conditional FK to crm_accounts
        if table_exists("crm_accounts") then
            db.query([[
                ALTER TABLE invoices
                ADD CONSTRAINT invoices_account_fk
                FOREIGN KEY (account_id) REFERENCES crm_accounts(id) ON DELETE SET NULL
            ]])
        end

        -- Conditional FK to crm_contacts
        if table_exists("crm_contacts") then
            db.query([[
                ALTER TABLE invoices
                ADD CONSTRAINT invoices_contact_fk
                FOREIGN KEY (contact_id) REFERENCES crm_contacts(id) ON DELETE SET NULL
            ]])
        end
    end,

    -- ========================================
    -- [2] Create invoice_line_items table
    -- ========================================
    [2] = function()
        if table_exists("invoice_line_items") then return end

        db.query([[
            CREATE TABLE invoice_line_items (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
                description TEXT NOT NULL,
                quantity DECIMAL(10,3) DEFAULT 1,
                unit_price DECIMAL(15,2) DEFAULT 0,
                tax_rate DECIMAL(5,2) DEFAULT 0,
                tax_amount DECIMAL(15,2) DEFAULT 0,
                discount_percent DECIMAL(5,2) DEFAULT 0,
                line_total DECIMAL(15,2) DEFAULT 0,
                sort_order INTEGER DEFAULT 0,
                timesheet_entry_id BIGINT DEFAULT NULL,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_invoice_line_items_invoice_id ON invoice_line_items (invoice_id)
        ]])
        db.query([[
            CREATE INDEX idx_invoice_line_items_timesheet_entry_id ON invoice_line_items (timesheet_entry_id)
        ]])

        -- Conditional FK to timesheet_entries
        if table_exists("timesheet_entries") then
            db.query([[
                ALTER TABLE invoice_line_items
                ADD CONSTRAINT invoice_line_items_timesheet_fk
                FOREIGN KEY (timesheet_entry_id) REFERENCES timesheet_entries(id) ON DELETE SET NULL
            ]])
        end
    end,

    -- ========================================
    -- [3] Create invoice_payments table
    -- ========================================
    [3] = function()
        if table_exists("invoice_payments") then return end

        db.query([[
            CREATE TABLE invoice_payments (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
                amount DECIMAL(15,2) NOT NULL,
                currency TEXT DEFAULT 'USD',
                payment_method TEXT,
                payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
                reference_number TEXT,
                notes TEXT,
                stripe_payment_intent_id TEXT,
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_invoice_payments_invoice_id ON invoice_payments (invoice_id)
        ]])
        db.query([[
            CREATE INDEX idx_invoice_payments_namespace_id ON invoice_payments (namespace_id)
        ]])
        db.query([[
            CREATE INDEX idx_invoice_payments_payment_date ON invoice_payments (payment_date)
        ]])
    end,

    -- ========================================
    -- [4] Create invoice_tax_rates table
    -- ========================================
    [4] = function()
        if table_exists("invoice_tax_rates") then return end

        db.query([[
            CREATE TABLE invoice_tax_rates (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                rate DECIMAL(5,4) NOT NULL,
                description TEXT,
                is_default BOOLEAN DEFAULT false,
                is_active BOOLEAN DEFAULT true,
                country_code TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Indexes
        db.query([[
            CREATE INDEX idx_invoice_tax_rates_namespace_active ON invoice_tax_rates (namespace_id, is_active)
        ]])
        db.query([[
            CREATE INDEX idx_invoice_tax_rates_country_code ON invoice_tax_rates (country_code)
        ]])
    end,

    -- ========================================
    -- [5] Create invoice_sequences table
    -- ========================================
    [5] = function()
        if table_exists("invoice_sequences") then return end

        db.query([[
            CREATE TABLE invoice_sequences (
                id BIGSERIAL PRIMARY KEY,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                prefix TEXT DEFAULT 'INV',
                current_number BIGINT DEFAULT 0,
                format TEXT DEFAULT '{prefix}-{number}',
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                UNIQUE (namespace_id)
            )
        ]])
    end
}
