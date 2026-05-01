--[[
    Document Template System Migrations
    ====================================

    A document template system for generating professional PDFs (invoices,
    timesheets, receipts, reports) with versioning and per-namespace defaults.

    Tables:
    =======
    1. document_templates           - Reusable HTML/CSS templates (namespace-scoped)
    2. document_template_versions   - Version history for template changes
    3. generated_documents          - Records of rendered/generated documents
    4. Seed data                    - Default invoice and timesheet templates
]]

local db = require("lapis.db")

-- Helper to check if table exists
local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create document_templates table
    -- ========================================
    [1] = function()
        if table_exists("document_templates") then return end

        db.query([[
            CREATE TABLE document_templates (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                type TEXT NOT NULL CHECK (type IN ('invoice', 'timesheet', 'receipt', 'report')),
                name TEXT NOT NULL,
                description TEXT,
                is_default BOOLEAN DEFAULT false,
                template_html TEXT NOT NULL,
                template_css TEXT,
                header_html TEXT,
                footer_html TEXT,
                config JSONB DEFAULT '{}',
                variables JSONB DEFAULT '[]',
                page_size TEXT DEFAULT 'A4' CHECK (page_size IN ('A4', 'Letter', 'Legal')),
                page_orientation TEXT DEFAULT 'portrait' CHECK (page_orientation IN ('portrait', 'landscape')),
                margin_top TEXT DEFAULT '20mm',
                margin_bottom TEXT DEFAULT '20mm',
                margin_left TEXT DEFAULT '15mm',
                margin_right TEXT DEFAULT '15mm',
                version INTEGER DEFAULT 1,
                is_active BOOLEAN DEFAULT true,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- Composite index: namespace + type + active status
        db.query([[
            CREATE INDEX idx_document_templates_namespace_type_active
            ON document_templates (namespace_id, type, is_active)
        ]])

        -- Partial index: namespace defaults (only where is_default=true and not deleted)
        db.query([[
            CREATE INDEX idx_document_templates_namespace_default
            ON document_templates (namespace_id, is_default)
            WHERE is_default = true AND deleted_at IS NULL
        ]])

        -- Unique index on uuid
        db.query([[
            CREATE UNIQUE INDEX idx_document_templates_uuid
            ON document_templates (uuid)
        ]])

        -- BRIN index on created_at for time-range queries
        db.query([[
            CREATE INDEX idx_document_templates_created_at_brin
            ON document_templates USING BRIN (created_at)
        ]])
    end,

    -- ========================================
    -- [2] Create document_template_versions table
    -- ========================================
    [2] = function()
        if table_exists("document_template_versions") then return end

        db.query([[
            CREATE TABLE document_template_versions (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                template_id BIGINT NOT NULL REFERENCES document_templates(id) ON DELETE CASCADE,
                version INTEGER NOT NULL,
                template_html TEXT NOT NULL,
                template_css TEXT,
                header_html TEXT,
                footer_html TEXT,
                config JSONB DEFAULT '{}',
                change_notes TEXT,
                created_by_uuid TEXT,
                created_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Unique composite index: one version number per template
        db.query([[
            CREATE UNIQUE INDEX idx_template_versions_template_version
            ON document_template_versions (template_id, version)
        ]])

        -- BRIN index on created_at
        db.query([[
            CREATE INDEX idx_template_versions_created_at_brin
            ON document_template_versions USING BRIN (created_at)
        ]])
    end,

    -- ========================================
    -- [3] Create generated_documents table
    -- ========================================
    [3] = function()
        if table_exists("generated_documents") then return end

        db.query([[
            CREATE TABLE generated_documents (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                template_id BIGINT DEFAULT NULL REFERENCES document_templates(id) ON DELETE SET NULL,
                document_type TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                file_path TEXT,
                file_size BIGINT,
                file_format TEXT DEFAULT 'pdf',
                rendered_html TEXT,
                metadata JSONB DEFAULT '{}',
                generated_by_uuid TEXT NOT NULL,
                emailed_to TEXT,
                emailed_at TIMESTAMP,
                created_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Composite index: namespace + document type
        db.query([[
            CREATE INDEX idx_generated_documents_namespace_type
            ON generated_documents (namespace_id, document_type)
        ]])

        -- Composite index: entity lookup
        db.query([[
            CREATE INDEX idx_generated_documents_entity
            ON generated_documents (entity_type, entity_id)
        ]])

        -- Index on generated_by_uuid
        db.query([[
            CREATE INDEX idx_generated_documents_generated_by
            ON generated_documents (generated_by_uuid)
        ]])

        -- BRIN index on created_at
        db.query([[
            CREATE INDEX idx_generated_documents_created_at_brin
            ON generated_documents USING BRIN (created_at)
        ]])
    end,

    -- ========================================
    -- [4] Seed default templates
    -- ========================================
    [4] = function()
        -- Default Invoice Template
        db.query([[
            INSERT INTO document_templates (uuid, namespace_id, type, name, description, is_default, template_html, template_css, header_html, footer_html, config, variables, page_size, page_orientation)
            SELECT
                'dt-default-invoice-00000001',
                id,
                'invoice',
                'Default Invoice Template',
                'A clean, professional invoice template with company branding, line items, tax, discount, and payment terms.',
                true,
                '<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body>
  <div class="invoice-container">
    <div class="invoice-header">
      <div class="company-info">
        <div class="logo-placeholder">{{ company_logo }}</div>
        <h1 class="company-name">{{ company_name }}</h1>
        <p class="company-address">{{ company_address }}</p>
      </div>
      <div class="invoice-title">
        <h2>INVOICE</h2>
        <table class="invoice-meta">
          <tr><td class="label">Invoice #:</td><td>{{ invoice_number }}</td></tr>
          <tr><td class="label">Date:</td><td>{{ invoice_date }}</td></tr>
          <tr><td class="label">Due Date:</td><td>{{ due_date }}</td></tr>
        </table>
      </div>
    </div>

    <div class="bill-to">
      <h3>Bill To</h3>
      <p class="client-name">{{ client_name }}</p>
      <p class="client-address">{{ client_address }}</p>
      <p class="client-email">{{ client_email }}</p>
    </div>

    <table class="line-items">
      <thead>
        <tr>
          <th class="desc-col">Description</th>
          <th class="qty-col">Qty</th>
          <th class="rate-col">Rate</th>
          <th class="tax-col">Tax</th>
          <th class="amount-col">Amount</th>
        </tr>
      </thead>
      <tbody>
        {{# line_items }}
        <tr>
          <td>{{ description }}</td>
          <td class="text-right">{{ quantity }}</td>
          <td class="text-right">{{ rate }}</td>
          <td class="text-right">{{ tax }}</td>
          <td class="text-right">{{ amount }}</td>
        </tr>
        {{/ line_items }}
      </tbody>
    </table>

    <div class="totals">
      <table>
        <tr><td class="label">Subtotal:</td><td class="text-right">{{ subtotal }}</td></tr>
        <tr><td class="label">Tax:</td><td class="text-right">{{ tax_total }}</td></tr>
        <tr><td class="label">Discount:</td><td class="text-right">-{{ discount }}</td></tr>
        <tr class="total-row"><td class="label">Total:</td><td class="text-right">{{ total }}</td></tr>
      </table>
    </div>

    <div class="footer-section">
      <div class="payment-terms">
        <h4>Payment Terms</h4>
        <p>{{ payment_terms }}</p>
      </div>
      <div class="notes">
        <h4>Notes</h4>
        <p>{{ notes }}</p>
      </div>
    </div>
  </div>
</body>
</html>',
                'body { font-family: "Helvetica Neue", Arial, sans-serif; color: #333; margin: 0; padding: 0; }
.invoice-container { max-width: 800px; margin: 0 auto; padding: 40px; }
.invoice-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 40px; border-bottom: 3px solid #0052cc; padding-bottom: 20px; }
.company-info { flex: 1; }
.logo-placeholder { width: 120px; height: 60px; background: #f0f4f8; border: 1px dashed #ccc; display: flex; align-items: center; justify-content: center; margin-bottom: 10px; font-size: 12px; color: #999; }
.company-name { font-size: 22px; font-weight: 700; color: #0052cc; margin: 0 0 5px 0; }
.company-address { font-size: 13px; color: #666; margin: 0; line-height: 1.5; }
.invoice-title h2 { font-size: 32px; color: #0052cc; margin: 0 0 15px 0; text-align: right; }
.invoice-meta { font-size: 13px; }
.invoice-meta td { padding: 3px 0; }
.invoice-meta .label { font-weight: 600; padding-right: 15px; color: #555; }
.bill-to { background: #f7f9fc; padding: 20px; border-radius: 6px; margin-bottom: 30px; }
.bill-to h3 { font-size: 11px; text-transform: uppercase; letter-spacing: 1px; color: #0052cc; margin: 0 0 10px 0; }
.client-name { font-weight: 600; font-size: 15px; margin: 0 0 5px 0; }
.client-address, .client-email { font-size: 13px; color: #666; margin: 0 0 3px 0; }
.line-items { width: 100%; border-collapse: collapse; margin-bottom: 30px; }
.line-items th { background: #0052cc; color: #fff; padding: 10px 12px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; text-align: left; }
.line-items td { padding: 10px 12px; border-bottom: 1px solid #e8ecf0; font-size: 13px; }
.line-items tbody tr:hover { background: #f7f9fc; }
.desc-col { width: 40%; } .qty-col, .rate-col, .tax-col, .amount-col { width: 15%; }
.text-right { text-align: right; }
.totals { display: flex; justify-content: flex-end; margin-bottom: 40px; }
.totals table { min-width: 280px; }
.totals td { padding: 6px 0; font-size: 14px; }
.totals .label { font-weight: 600; padding-right: 30px; }
.total-row td { border-top: 2px solid #0052cc; font-size: 18px; font-weight: 700; color: #0052cc; padding-top: 10px; }
.footer-section { display: flex; gap: 40px; border-top: 1px solid #e8ecf0; padding-top: 20px; }
.footer-section h4 { font-size: 12px; text-transform: uppercase; color: #0052cc; margin: 0 0 8px 0; }
.footer-section p { font-size: 13px; color: #666; line-height: 1.5; margin: 0; }',
                '<div style="text-align:center;font-size:10px;color:#999;padding:10px 0;">{{ company_name }}</div>',
                '<div style="text-align:center;font-size:10px;color:#999;border-top:1px solid #eee;padding:10px 0;">Page {{ page }} of {{ pages }} | {{ company_name }}</div>',
                '{"currency_symbol": "$", "date_format": "YYYY-MM-DD"}',
                '["company_logo","company_name","company_address","invoice_number","invoice_date","due_date","client_name","client_address","client_email","line_items","subtotal","tax_total","discount","total","payment_terms","notes"]',
                'A4',
                'portrait'
            FROM namespaces
            WHERE slug = 'default'
            LIMIT 1
            ON CONFLICT (uuid) DO NOTHING
        ]])

        -- Default Timesheet Template
        db.query([[
            INSERT INTO document_templates (uuid, namespace_id, type, name, description, is_default, template_html, template_css, header_html, footer_html, config, variables, page_size, page_orientation)
            SELECT
                'dt-default-timesheet-00000001',
                id,
                'timesheet',
                'Default Timesheet Template',
                'A corporate timesheet template with daily entries, project tracking, hours summary, and approval workflow.',
                true,
                '<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body>
  <div class="timesheet-container">
    <div class="timesheet-header">
      <h1>TIMESHEET</h1>
      <div class="header-meta">
        <table>
          <tr><td class="label">Employee:</td><td>{{ employee_name }}</td></tr>
          <tr><td class="label">Period:</td><td>{{ period_start }} - {{ period_end }}</td></tr>
          <tr><td class="label">Manager:</td><td>{{ manager_name }}</td></tr>
          <tr><td class="label">Department:</td><td>{{ department }}</td></tr>
        </table>
      </div>
    </div>

    <table class="entries-table">
      <thead>
        <tr>
          <th class="date-col">Date</th>
          <th class="project-col">Project</th>
          <th class="task-col">Task</th>
          <th class="hours-col">Hours</th>
          <th class="desc-col">Description</th>
        </tr>
      </thead>
      <tbody>
        {{# entries }}
        <tr>
          <td>{{ date }}</td>
          <td>{{ project }}</td>
          <td>{{ task }}</td>
          <td class="text-right">{{ hours }}</td>
          <td>{{ description }}</td>
        </tr>
        {{/ entries }}
      </tbody>
    </table>

    <div class="summary-section">
      <h3>Summary</h3>
      <table class="summary-table">
        <tr><td class="label">Total Hours:</td><td class="text-right">{{ total_hours }}</td></tr>
        <tr><td class="label">Billable Hours:</td><td class="text-right">{{ billable_hours }}</td></tr>
        <tr><td class="label">Non-Billable Hours:</td><td class="text-right">{{ non_billable_hours }}</td></tr>
        <tr><td class="label">Overtime Hours:</td><td class="text-right">{{ overtime_hours }}</td></tr>
      </table>
    </div>

    <div class="approval-section">
      <h3>Approval</h3>
      <div class="approval-grid">
        <div class="approval-block">
          <div class="status-badge {{ approval_status }}">{{ approval_status }}</div>
          <p class="approval-date">Date: {{ approval_date }}</p>
        </div>
        <div class="signature-block">
          <div class="signature-line"></div>
          <p class="signature-label">Employee Signature</p>
        </div>
        <div class="signature-block">
          <div class="signature-line"></div>
          <p class="signature-label">Manager Signature</p>
        </div>
      </div>
    </div>
  </div>
</body>
</html>',
                'body { font-family: "Helvetica Neue", Arial, sans-serif; color: #333; margin: 0; padding: 0; }
.timesheet-container { max-width: 800px; margin: 0 auto; padding: 40px; }
.timesheet-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 30px; border-bottom: 3px solid #0052cc; padding-bottom: 20px; }
.timesheet-header h1 { font-size: 32px; color: #0052cc; margin: 0; }
.header-meta table { font-size: 13px; }
.header-meta .label { font-weight: 600; color: #555; padding-right: 15px; padding-bottom: 4px; }
.entries-table { width: 100%; border-collapse: collapse; margin-bottom: 30px; }
.entries-table th { background: #0052cc; color: #fff; padding: 10px 12px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; text-align: left; }
.entries-table td { padding: 9px 12px; border-bottom: 1px solid #e8ecf0; font-size: 13px; }
.entries-table tbody tr:nth-child(even) { background: #f7f9fc; }
.date-col { width: 12%; } .project-col { width: 20%; } .task-col { width: 18%; } .hours-col { width: 10%; } .desc-col { width: 40%; }
.text-right { text-align: right; }
.summary-section { background: #f7f9fc; padding: 20px; border-radius: 6px; margin-bottom: 30px; }
.summary-section h3 { font-size: 14px; text-transform: uppercase; letter-spacing: 1px; color: #0052cc; margin: 0 0 12px 0; }
.summary-table { width: 300px; }
.summary-table td { padding: 5px 0; font-size: 14px; }
.summary-table .label { font-weight: 600; }
.approval-section { border-top: 1px solid #e8ecf0; padding-top: 25px; }
.approval-section h3 { font-size: 14px; text-transform: uppercase; letter-spacing: 1px; color: #0052cc; margin: 0 0 20px 0; }
.approval-grid { display: flex; gap: 40px; align-items: flex-end; }
.approval-block { flex: 1; }
.status-badge { display: inline-block; padding: 4px 14px; border-radius: 12px; font-size: 12px; font-weight: 600; text-transform: uppercase; }
.status-badge.approved { background: #e6f9ed; color: #1a7f37; }
.status-badge.pending { background: #fff8e1; color: #b8860b; }
.status-badge.rejected { background: #ffeef0; color: #d1242f; }
.approval-date { font-size: 12px; color: #666; margin: 8px 0 0 0; }
.signature-block { flex: 1; text-align: center; }
.signature-line { border-bottom: 1px solid #333; height: 40px; margin-bottom: 5px; }
.signature-label { font-size: 11px; color: #666; margin: 0; }',
                '<div style="text-align:center;font-size:10px;color:#999;padding:10px 0;">Timesheet - {{ employee_name }}</div>',
                '<div style="text-align:center;font-size:10px;color:#999;border-top:1px solid #eee;padding:10px 0;">Page {{ page }} of {{ pages }} | Confidential</div>',
                '{"date_format": "YYYY-MM-DD", "hours_format": "decimal"}',
                '["employee_name","period_start","period_end","manager_name","department","entries","total_hours","billable_hours","non_billable_hours","overtime_hours","approval_status","approval_date"]',
                'A4',
                'portrait'
            FROM namespaces
            WHERE slug = 'default'
            LIMIT 1
            ON CONFLICT (uuid) DO NOTHING
        ]])
    end,
}
