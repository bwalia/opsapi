-- PDF Generation Service for OpsAPI
-- Wraps wkhtmltopdf for HTML-to-PDF conversion with fallback to HTML
-- Usage: local PdfService = require("lib.pdf-service")

local TemplateRenderer = require("lib.template-renderer")

local PdfService = {}

-- Constants
local PDF_OUTPUT_DIR = "/tmp/opsapi-docs"
local DEFAULT_PAGE_SIZE = "A4"
local DEFAULT_ORIENTATION = "Portrait"
local DEFAULT_MARGIN = "15mm"

-- ============================================================================
-- Utility Functions
-- ============================================================================

--- Generate a unique filename for PDF output
-- @param prefix string Optional prefix
-- @return string Unique file path
local function generate_filepath(prefix)
    prefix = prefix or "doc"
    local timestamp = os.time()
    local random_part = math.random(100000, 999999)
    return string.format("%s/%s_%d_%d.pdf", PDF_OUTPUT_DIR, prefix, timestamp, random_part)
end

--- Write content to a temporary file
-- @param content string
-- @param suffix string File extension (e.g. ".html")
-- @return string|nil file path, string|nil error
local function write_temp_file(content, suffix)
    suffix = suffix or ".html"
    local path = string.format("%s/tmp_%d_%d%s", PDF_OUTPUT_DIR, os.time(), math.random(100000, 999999), suffix)
    local f, err = io.open(path, "w")
    if not f then
        return nil, "Failed to write temp file: " .. (err or "unknown")
    end
    f:write(content)
    f:close()
    return path, nil
end

--- Get the file size in bytes
-- @param path string
-- @return number|nil
local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

--- Ensure the output directory exists
local function ensure_output_dir()
    os.execute("mkdir -p " .. PDF_OUTPUT_DIR)
end

--- Log a message (uses ngx.log if available, falls back to print)
local function log_warning(msg)
    local ok, ngx_mod = pcall(function() return ngx end)
    if ok and ngx_mod and ngx_mod.log then
        ngx_mod.log(ngx_mod.WARN, "pdf-service: " .. msg)
    else
        io.stderr:write("[pdf-service WARN] " .. msg .. "\n")
    end
end

local function log_info(msg)
    local ok, ngx_mod = pcall(function() return ngx end)
    if ok and ngx_mod and ngx_mod.log then
        ngx_mod.log(ngx_mod.INFO, "pdf-service: " .. msg)
    else
        io.stderr:write("[pdf-service INFO] " .. msg .. "\n")
    end
end

-- ============================================================================
-- wkhtmltopdf Integration
-- ============================================================================

--- Check if wkhtmltopdf is available on the system
-- @return boolean
function PdfService.isAvailable()
    local handle = io.popen("which wkhtmltopdf 2>/dev/null")
    if not handle then return false end
    local result = handle:read("*a")
    handle:close()
    return result and result:match("%S") ~= nil
end

--- Generate PDF from HTML content
-- @param html string Full HTML document
-- @param options table {page_size, orientation, margins, margin_top, margin_bottom, margin_left, margin_right, header_html, footer_html}
-- @return string file_path, number file_size
function PdfService.generateFromHtml(html, options)
    options = options or {}
    ensure_output_dir()

    local output_path = generate_filepath("doc")

    if not PdfService.isAvailable() then
        log_warning("wkhtmltopdf not available, returning HTML file instead")
        local html_path = output_path:gsub("%.pdf$", ".html")
        local f, err = io.open(html_path, "w")
        if not f then
            return nil, 0, "Failed to write HTML fallback: " .. (err or "unknown")
        end
        f:write(html)
        f:close()
        local size = file_size(html_path) or 0
        return html_path, size
    end

    -- Write HTML to temp file
    local html_path, err = write_temp_file(html, ".html")
    if not html_path then
        return nil, 0, err
    end

    -- Build wkhtmltopdf command
    local cmd_parts = { "wkhtmltopdf", "--quiet" }

    -- Page size
    cmd_parts[#cmd_parts + 1] = "--page-size"
    cmd_parts[#cmd_parts + 1] = options.page_size or DEFAULT_PAGE_SIZE

    -- Orientation
    cmd_parts[#cmd_parts + 1] = "--orientation"
    cmd_parts[#cmd_parts + 1] = options.orientation or DEFAULT_ORIENTATION

    -- Margins
    cmd_parts[#cmd_parts + 1] = "--margin-top"
    cmd_parts[#cmd_parts + 1] = options.margin_top or DEFAULT_MARGIN

    cmd_parts[#cmd_parts + 1] = "--margin-bottom"
    cmd_parts[#cmd_parts + 1] = options.margin_bottom or DEFAULT_MARGIN

    cmd_parts[#cmd_parts + 1] = "--margin-left"
    cmd_parts[#cmd_parts + 1] = options.margin_left or DEFAULT_MARGIN

    cmd_parts[#cmd_parts + 1] = "--margin-right"
    cmd_parts[#cmd_parts + 1] = options.margin_right or DEFAULT_MARGIN

    -- Header HTML (write to temp file if provided)
    if options.header_html and options.header_html ~= "" then
        local header_path = write_temp_file(options.header_html, ".html")
        if header_path then
            cmd_parts[#cmd_parts + 1] = "--header-html"
            cmd_parts[#cmd_parts + 1] = header_path
        end
    end

    -- Footer HTML (write to temp file if provided)
    if options.footer_html and options.footer_html ~= "" then
        local footer_path = write_temp_file(options.footer_html, ".html")
        if footer_path then
            cmd_parts[#cmd_parts + 1] = "--footer-html"
            cmd_parts[#cmd_parts + 1] = footer_path
        end
    end

    -- Input and output
    cmd_parts[#cmd_parts + 1] = html_path
    cmd_parts[#cmd_parts + 1] = output_path

    local cmd = table.concat(cmd_parts, " ")
    log_info("Executing: " .. cmd)

    local exit_code = os.execute(cmd)

    -- Clean up temp HTML
    os.remove(html_path)

    if exit_code ~= 0 and exit_code ~= true then
        return nil, 0, "wkhtmltopdf failed with exit code: " .. tostring(exit_code)
    end

    local size = file_size(output_path) or 0
    if size == 0 then
        return nil, 0, "wkhtmltopdf produced empty output"
    end

    log_info("Generated PDF: " .. output_path .. " (" .. size .. " bytes)")
    return output_path, size
end

-- ============================================================================
-- Default Templates
-- ============================================================================

local DEFAULT_TEMPLATES = {}

DEFAULT_TEMPLATES.invoice = [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Invoice {{invoice.number}}</title>
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; font-size: 14px; line-height: 1.5; }
    .invoice-container { max-width: 800px; margin: 0 auto; padding: 40px; }

    /* Header */
    .invoice-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 40px; border-bottom: 3px solid #0052cc; padding-bottom: 20px; }
    .company-info h1 { font-size: 24px; color: #0052cc; margin-bottom: 5px; }
    .company-info p { color: #666; font-size: 13px; }
    .invoice-title { text-align: right; }
    .invoice-title h2 { font-size: 32px; color: #0052cc; text-transform: uppercase; letter-spacing: 2px; }
    .invoice-title .invoice-number { font-size: 16px; color: #666; margin-top: 5px; }

    /* Addresses */
    .addresses { display: flex; justify-content: space-between; margin-bottom: 30px; }
    .address-block { width: 45%; }
    .address-block h3 { font-size: 12px; text-transform: uppercase; color: #0052cc; letter-spacing: 1px; margin-bottom: 8px; border-bottom: 1px solid #e0e0e0; padding-bottom: 5px; }
    .address-block p { font-size: 13px; color: #555; }

    /* Invoice Details */
    .invoice-details { display: flex; justify-content: flex-end; margin-bottom: 30px; }
    .detail-table { border-collapse: collapse; }
    .detail-table td { padding: 4px 12px; font-size: 13px; }
    .detail-table td:first-child { color: #666; text-align: right; }
    .detail-table td:last-child { font-weight: 600; }

    /* Line Items */
    .items-table { width: 100%; border-collapse: collapse; margin-bottom: 30px; }
    .items-table thead th { background-color: #0052cc; color: #fff; padding: 10px 12px; text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; }
    .items-table thead th:last-child, .items-table thead th:nth-child(3), .items-table thead th:nth-child(4) { text-align: right; }
    .items-table tbody td { padding: 10px 12px; border-bottom: 1px solid #e8e8e8; font-size: 13px; }
    .items-table tbody td:last-child, .items-table tbody td:nth-child(3), .items-table tbody td:nth-child(4) { text-align: right; }
    .items-table tbody tr:nth-child(even) { background-color: #f8f9fa; }

    /* Totals */
    .totals { display: flex; justify-content: flex-end; margin-bottom: 40px; }
    .totals-table { border-collapse: collapse; min-width: 280px; }
    .totals-table td { padding: 6px 12px; font-size: 14px; }
    .totals-table td:first-child { color: #666; text-align: right; }
    .totals-table td:last-child { text-align: right; font-weight: 500; }
    .totals-table .total-row td { border-top: 2px solid #0052cc; font-size: 18px; font-weight: 700; color: #0052cc; padding-top: 10px; }

    /* Notes */
    .notes { background-color: #f8f9fa; padding: 20px; border-radius: 4px; margin-bottom: 30px; }
    .notes h3 { font-size: 12px; text-transform: uppercase; color: #0052cc; letter-spacing: 1px; margin-bottom: 8px; }
    .notes p { font-size: 13px; color: #555; }

    /* Footer */
    .invoice-footer { text-align: center; color: #999; font-size: 11px; border-top: 1px solid #e0e0e0; padding-top: 15px; }
</style>
</head>
<body>
<div class="invoice-container">
    <div class="invoice-header">
        <div class="company-info">
            <h1>{{company.name}}</h1>
            <p>{{company.address}}</p>
            <p>{{company.city}}, {{company.postcode}}</p>
            <p>{{company.email}}</p>
            {% if company.phone %}<p>{{company.phone}}</p>{% endif %}
            {% if company.vat_number %}<p>VAT: {{company.vat_number}}</p>{% endif %}
        </div>
        <div class="invoice-title">
            <h2>Invoice</h2>
            <div class="invoice-number">#{{invoice.number}}</div>
        </div>
    </div>

    <div class="addresses">
        <div class="address-block">
            <h3>Bill To</h3>
            <p><strong>{{client.name}}</strong></p>
            <p>{{client.address}}</p>
            <p>{{client.city}}, {{client.postcode}}</p>
            {% if client.email %}<p>{{client.email}}</p>{% endif %}
            {% if client.vat_number %}<p>VAT: {{client.vat_number}}</p>{% endif %}
        </div>
        <div class="address-block">
            <h3>Invoice Details</h3>
            <table class="detail-table">
                <tr><td>Date:</td><td>{{invoice.date | date_format}}</td></tr>
                <tr><td>Due Date:</td><td>{{invoice.due_date | date_format}}</td></tr>
                {% if invoice.po_number %}<tr><td>PO Number:</td><td>{{invoice.po_number}}</td></tr>{% endif %}
                <tr><td>Status:</td><td>{{invoice.status | uppercase}}</td></tr>
            </table>
        </div>
    </div>

    <table class="items-table">
        <thead>
            <tr>
                <th>#</th>
                <th>Description</th>
                <th>Qty</th>
                <th>Unit Price</th>
                <th>Amount</th>
            </tr>
        </thead>
        <tbody>
            {% for item in invoice.line_items %}
            <tr>
                <td>{{forloop.index}}</td>
                <td>{{item.description}}</td>
                <td>{{item.quantity}}</td>
                <td>{{invoice.currency_symbol}}{{item.unit_price | currency}}</td>
                <td>{{invoice.currency_symbol}}{{item.amount | currency}}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>

    <div class="totals">
        <table class="totals-table">
            <tr><td>Subtotal:</td><td>{{invoice.currency_symbol}}{{invoice.subtotal | currency}}</td></tr>
            {% if invoice.discount_amount %}
            <tr><td>Discount:</td><td>-{{invoice.currency_symbol}}{{invoice.discount_amount | currency}}</td></tr>
            {% endif %}
            {% if invoice.tax_amount %}
            <tr><td>Tax ({{invoice.tax_rate}}%):</td><td>{{invoice.currency_symbol}}{{invoice.tax_amount | currency}}</td></tr>
            {% endif %}
            <tr class="total-row"><td>Total:</td><td>{{invoice.currency_symbol}}{{invoice.total | currency}}</td></tr>
        </table>
    </div>

    {% if invoice.notes %}
    <div class="notes">
        <h3>Notes</h3>
        <p>{{invoice.notes}}</p>
    </div>
    {% endif %}

    {% if company.payment_details %}
    <div class="notes">
        <h3>Payment Details</h3>
        <p>{{company.payment_details | raw}}</p>
    </div>
    {% endif %}

    <div class="invoice-footer">
        <p>{{company.name}} &mdash; Thank you for your business</p>
    </div>
</div>
</body>
</html>]]

DEFAULT_TEMPLATES.timesheet = [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Timesheet - {{timesheet.period}}</title>
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Helvetica Neue', Arial, sans-serif; color: #333; font-size: 14px; line-height: 1.5; }
    .timesheet-container { max-width: 800px; margin: 0 auto; padding: 40px; }

    /* Header */
    .timesheet-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 40px; border-bottom: 3px solid #0052cc; padding-bottom: 20px; }
    .company-info h1 { font-size: 24px; color: #0052cc; margin-bottom: 5px; }
    .company-info p { color: #666; font-size: 13px; }
    .timesheet-title { text-align: right; }
    .timesheet-title h2 { font-size: 28px; color: #0052cc; text-transform: uppercase; letter-spacing: 2px; }
    .timesheet-title .period { font-size: 14px; color: #666; margin-top: 5px; }

    /* Details Grid */
    .details-grid { display: flex; justify-content: space-between; margin-bottom: 30px; }
    .detail-block { width: 30%; }
    .detail-block h3 { font-size: 12px; text-transform: uppercase; color: #0052cc; letter-spacing: 1px; margin-bottom: 8px; border-bottom: 1px solid #e0e0e0; padding-bottom: 5px; }
    .detail-block p { font-size: 13px; color: #555; }
    .detail-block .value { font-weight: 600; color: #333; }

    /* Entries Table */
    .entries-table { width: 100%; border-collapse: collapse; margin-bottom: 30px; }
    .entries-table thead th { background-color: #0052cc; color: #fff; padding: 10px 12px; text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; }
    .entries-table thead th:nth-child(3), .entries-table thead th:nth-child(4) { text-align: right; }
    .entries-table tbody td { padding: 10px 12px; border-bottom: 1px solid #e8e8e8; font-size: 13px; }
    .entries-table tbody td:nth-child(3), .entries-table tbody td:nth-child(4) { text-align: right; }
    .entries-table tbody tr:nth-child(even) { background-color: #f8f9fa; }
    .entries-table tfoot td { padding: 10px 12px; font-weight: 700; border-top: 2px solid #0052cc; font-size: 14px; }
    .entries-table tfoot td:nth-child(3), .entries-table tfoot td:nth-child(4) { text-align: right; }

    /* Summary */
    .summary { display: flex; justify-content: flex-end; margin-bottom: 30px; }
    .summary-table { border-collapse: collapse; min-width: 280px; }
    .summary-table td { padding: 6px 12px; font-size: 14px; }
    .summary-table td:first-child { color: #666; text-align: right; }
    .summary-table td:last-child { text-align: right; font-weight: 500; }
    .summary-table .total-row td { border-top: 2px solid #0052cc; font-size: 18px; font-weight: 700; color: #0052cc; padding-top: 10px; }

    /* Notes */
    .notes { background-color: #f8f9fa; padding: 20px; border-radius: 4px; margin-bottom: 30px; }
    .notes h3 { font-size: 12px; text-transform: uppercase; color: #0052cc; letter-spacing: 1px; margin-bottom: 8px; }
    .notes p { font-size: 13px; color: #555; }

    /* Signatures */
    .signatures { display: flex; justify-content: space-between; margin-top: 50px; }
    .signature-block { width: 40%; text-align: center; }
    .signature-line { border-top: 1px solid #333; margin-top: 50px; padding-top: 8px; font-size: 12px; color: #666; }

    /* Footer */
    .timesheet-footer { text-align: center; color: #999; font-size: 11px; border-top: 1px solid #e0e0e0; padding-top: 15px; margin-top: 30px; }
</style>
</head>
<body>
<div class="timesheet-container">
    <div class="timesheet-header">
        <div class="company-info">
            <h1>{{company.name}}</h1>
            <p>{{company.address}}</p>
            <p>{{company.city}}, {{company.postcode}}</p>
        </div>
        <div class="timesheet-title">
            <h2>Timesheet</h2>
            <div class="period">{{timesheet.period}}</div>
        </div>
    </div>

    <div class="details-grid">
        <div class="detail-block">
            <h3>Employee</h3>
            <p class="value">{{timesheet.employee_name}}</p>
            {% if timesheet.employee_role %}<p>{{timesheet.employee_role}}</p>{% endif %}
            {% if timesheet.employee_id %}<p>ID: {{timesheet.employee_id}}</p>{% endif %}
        </div>
        <div class="detail-block">
            <h3>Client / Project</h3>
            {% if client.name %}<p class="value">{{client.name}}</p>{% endif %}
            {% if timesheet.project_name %}<p>{{timesheet.project_name}}</p>{% endif %}
        </div>
        <div class="detail-block">
            <h3>Period</h3>
            <p>From: <span class="value">{{timesheet.start_date | date_format}}</span></p>
            <p>To: <span class="value">{{timesheet.end_date | date_format}}</span></p>
        </div>
    </div>

    <table class="entries-table">
        <thead>
            <tr>
                <th>Date</th>
                <th>Description</th>
                <th>Hours</th>
                {% if timesheet.show_rate %}<th>Amount</th>{% endif %}
            </tr>
        </thead>
        <tbody>
            {% for entry in timesheet.entries %}
            <tr>
                <td>{{entry.date | date_format}}</td>
                <td>{{entry.description}}</td>
                <td>{{entry.hours}}</td>
                {% if timesheet.show_rate %}<td>{{timesheet.currency_symbol}}{{entry.amount | currency}}</td>{% endif %}
            </tr>
            {% endfor %}
        </tbody>
        <tfoot>
            <tr>
                <td colspan="2">Total</td>
                <td>{{timesheet.total_hours}}</td>
                {% if timesheet.show_rate %}<td>{{timesheet.currency_symbol}}{{timesheet.total_amount | currency}}</td>{% endif %}
            </tr>
        </tfoot>
    </table>

    {% if timesheet.show_rate %}
    <div class="summary">
        <table class="summary-table">
            <tr><td>Hourly Rate:</td><td>{{timesheet.currency_symbol}}{{timesheet.hourly_rate | currency}}</td></tr>
            <tr><td>Total Hours:</td><td>{{timesheet.total_hours}}</td></tr>
            <tr class="total-row"><td>Total Amount:</td><td>{{timesheet.currency_symbol}}{{timesheet.total_amount | currency}}</td></tr>
        </table>
    </div>
    {% endif %}

    {% if timesheet.notes %}
    <div class="notes">
        <h3>Notes</h3>
        <p>{{timesheet.notes}}</p>
    </div>
    {% endif %}

    <div class="signatures">
        <div class="signature-block">
            <div class="signature-line">Employee Signature</div>
        </div>
        <div class="signature-block">
            <div class="signature-line">Approved By</div>
        </div>
    </div>

    <div class="timesheet-footer">
        <p>{{company.name}} &mdash; Timesheet generated on {{timesheet.generated_date | date_format}}</p>
    </div>
</div>
</body>
</html>]]

-- ============================================================================
-- Public API
-- ============================================================================

--- Get default template HTML for a document type
-- @param doc_type string "invoice" or "timesheet"
-- @return string HTML template
function PdfService.getDefaultTemplate(doc_type)
    return DEFAULT_TEMPLATES[doc_type] or DEFAULT_TEMPLATES.invoice
end

--- Generate PDF for an invoice
-- @param invoice table Invoice data with line_items
-- @param template table Document template record (or nil for default)
-- @param company table Company/namespace branding data
-- @return string file_path, number file_size
function PdfService.generateInvoicePdf(invoice, template, company)
    local template_html
    if template and template.html_content and template.html_content ~= "" then
        template_html = template.html_content
    else
        template_html = PdfService.getDefaultTemplate("invoice")
    end

    -- Build data context
    local data = {
        invoice = invoice,
        company = company or {},
        client = invoice.client or {},
    }

    -- Default currency symbol
    if not data.invoice.currency_symbol then
        data.invoice.currency_symbol = "$"
    end

    -- Render template
    local css = (template and template.css_content) or ""
    local rendered = TemplateRenderer.render(template_html, data, { css = css })

    -- Generate PDF
    local options = {
        page_size = (template and template.page_size) or "A4",
        orientation = (template and template.orientation) or "Portrait",
        margin_top = (template and template.margin_top) or "15mm",
        margin_bottom = (template and template.margin_bottom) or "15mm",
        margin_left = (template and template.margin_left) or "15mm",
        margin_right = (template and template.margin_right) or "15mm",
    }

    return PdfService.generateFromHtml(rendered, options)
end

--- Generate PDF for a timesheet
-- @param timesheet table Timesheet data with entries
-- @param template table Document template record (or nil for default)
-- @param company table Company/namespace branding data
-- @return string file_path, number file_size
function PdfService.generateTimesheetPdf(timesheet, template, company)
    local template_html
    if template and template.html_content and template.html_content ~= "" then
        template_html = template.html_content
    else
        template_html = PdfService.getDefaultTemplate("timesheet")
    end

    -- Build data context
    local data = {
        timesheet = timesheet,
        company = company or {},
        client = timesheet.client or {},
    }

    -- Default currency symbol
    if not data.timesheet.currency_symbol then
        data.timesheet.currency_symbol = "$"
    end

    -- Set generated date if not present
    if not data.timesheet.generated_date then
        data.timesheet.generated_date = os.date("%Y-%m-%d")
    end

    -- Render template
    local css = (template and template.css_content) or ""
    local rendered = TemplateRenderer.render(template_html, data, { css = css })

    -- Generate PDF
    local options = {
        page_size = (template and template.page_size) or "A4",
        orientation = (template and template.orientation) or "Portrait",
        margin_top = (template and template.margin_top) or "15mm",
        margin_bottom = (template and template.margin_bottom) or "15mm",
        margin_left = (template and template.margin_left) or "15mm",
        margin_right = (template and template.margin_right) or "15mm",
    }

    return PdfService.generateFromHtml(rendered, options)
end

return PdfService
