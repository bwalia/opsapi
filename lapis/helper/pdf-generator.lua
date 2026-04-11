--[[
    PDF Generator Helper
    ====================

    Simple utility module for generating invoice HTML and converting to PDF.
    Actual PDF rendering depends on external tool availability (wkhtmltopdf).
]]

local PdfGenerator = {}

--- Generate invoice HTML for PDF conversion
-- @param invoice table invoice record
-- @param line_items table array of line item records
-- @param company_info table { name, address, phone, email, logo_url, tax_id }
-- @return string HTML content
function PdfGenerator.generateInvoiceHtml(invoice, line_items, company_info)
    company_info = company_info or {}
    line_items = line_items or {}

    local html = [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Invoice ]] .. (invoice.invoice_number or "") .. [[</title>
<style>
    body { font-family: Arial, sans-serif; margin: 40px; color: #333; }
    .header { display: flex; justify-content: space-between; margin-bottom: 40px; }
    .company-info { text-align: left; }
    .company-info h1 { margin: 0 0 5px 0; font-size: 24px; color: #2c3e50; }
    .invoice-info { text-align: right; }
    .invoice-info h2 { margin: 0 0 10px 0; font-size: 28px; color: #2c3e50; }
    .customer-info { margin-bottom: 30px; }
    .customer-info h3 { margin: 0 0 5px 0; color: #7f8c8d; font-size: 12px; text-transform: uppercase; }
    table { width: 100%; border-collapse: collapse; margin-bottom: 30px; }
    th { background-color: #2c3e50; color: white; padding: 10px; text-align: left; font-size: 12px; }
    td { padding: 10px; border-bottom: 1px solid #ecf0f1; font-size: 13px; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    .totals { float: right; width: 300px; }
    .totals table { margin-bottom: 0; }
    .totals td { border-bottom: 1px solid #ecf0f1; }
    .totals .total-row td { font-weight: bold; font-size: 16px; border-top: 2px solid #2c3e50; }
    .footer { clear: both; margin-top: 60px; padding-top: 20px; border-top: 1px solid #ecf0f1; font-size: 11px; color: #7f8c8d; }
    .status-badge { display: inline-block; padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: bold; }
    .status-draft { background: #f39c12; color: white; }
    .status-sent { background: #3498db; color: white; }
    .status-paid { background: #27ae60; color: white; }
    .status-overdue { background: #e74c3c; color: white; }
    .status-void { background: #95a5a6; color: white; }
</style>
</head>
<body>

<div class="header">
    <div class="company-info">
        <h1>]] .. (company_info.name or "Company Name") .. [[</h1>
        <p>]] .. (company_info.address or "") .. [[</p>
        <p>]] .. (company_info.phone or "") .. [[</p>
        <p>]] .. (company_info.email or "") .. [[</p>]]

    if company_info.tax_id then
        html = html .. "\n        <p>Tax ID: " .. company_info.tax_id .. "</p>"
    end

    html = html .. [[

    </div>
    <div class="invoice-info">
        <h2>INVOICE</h2>
        <p><strong>Invoice #:</strong> ]] .. (invoice.invoice_number or "N/A") .. [[</p>
        <p><strong>Date:</strong> ]] .. (invoice.invoice_date or "") .. [[</p>
        <p><strong>Due Date:</strong> ]] .. (invoice.due_date or "") .. [[</p>
        <p><strong>Status:</strong> <span class="status-badge status-]] .. (invoice.status or "draft") .. [[">]] .. string.upper(invoice.status or "DRAFT") .. [[</span></p>
    </div>
</div>

<div class="customer-info">
    <h3>Bill To</h3>
    <p><strong>]] .. (invoice.customer_name or "") .. [[</strong></p>
    <p>]] .. (invoice.customer_email or "") .. [[</p>
    <p>]] .. (invoice.customer_address or "") .. [[</p>
</div>

<table>
    <thead>
        <tr>
            <th>#</th>
            <th>Description</th>
            <th>Quantity</th>
            <th>Unit Price</th>
            <th>Tax</th>
            <th>Discount</th>
            <th>Total</th>
        </tr>
    </thead>
    <tbody>]]

    for i, item in ipairs(line_items) do
        html = html .. [[

        <tr>
            <td>]] .. i .. [[</td>
            <td>]] .. (item.description or "") .. [[</td>
            <td>]] .. (item.quantity or 0) .. [[</td>
            <td>]] .. string.format("%.2f", tonumber(item.unit_price) or 0) .. [[</td>
            <td>]] .. string.format("%.2f", tonumber(item.tax_amount) or 0) .. [[</td>
            <td>]] .. string.format("%.2f", tonumber(item.discount_amount) or 0) .. [[</td>
            <td>]] .. string.format("%.2f", tonumber(item.line_total) or 0) .. [[</td>
        </tr>]]
    end

    html = html .. [[

    </tbody>
</table>

<div class="totals">
    <table>
        <tr><td>Subtotal:</td><td style="text-align:right">]] .. string.format("%.2f", tonumber(invoice.subtotal) or 0) .. [[</td></tr>
        <tr><td>Tax:</td><td style="text-align:right">]] .. string.format("%.2f", tonumber(invoice.tax_amount) or 0) .. [[</td></tr>
        <tr><td>Discount:</td><td style="text-align:right">-]] .. string.format("%.2f", tonumber(invoice.discount_amount) or 0) .. [[</td></tr>
        <tr class="total-row"><td>Total:</td><td style="text-align:right">]] .. string.format("%.2f", tonumber(invoice.total_amount) or 0) .. [[</td></tr>
        <tr><td>Amount Paid:</td><td style="text-align:right">]] .. string.format("%.2f", tonumber(invoice.amount_paid) or 0) .. [[</td></tr>
        <tr class="total-row"><td>Balance Due:</td><td style="text-align:right">]] .. string.format("%.2f", tonumber(invoice.balance_due) or 0) .. [[</td></tr>
    </table>
</div>

<div class="footer">]]

    if invoice.notes then
        html = html .. "\n    <p><strong>Notes:</strong> " .. invoice.notes .. "</p>"
    end

    if invoice.payment_terms then
        html = html .. "\n    <p><strong>Payment Terms:</strong> " .. invoice.payment_terms .. "</p>"
    end

    html = html .. [[

    <p>Thank you for your business.</p>
</div>

</body>
</html>]]

    return html
end

--- Convert HTML to PDF using wkhtmltopdf
-- @param html_content string HTML content
-- @param output_path string path for output PDF file
-- @return string|nil output path on success, nil on failure
-- @return string|nil error message on failure
function PdfGenerator.htmlToPdf(html_content, output_path)
    local handle = io.popen("which wkhtmltopdf 2>/dev/null")
    local result = handle:read("*a")
    handle:close()

    if not result or result == "" then
        return nil, "wkhtmltopdf not installed"
    end

    -- Write HTML to temp file
    local tmp = os.tmpname() .. ".html"
    local f = io.open(tmp, "w")
    if not f then
        return nil, "Failed to create temporary file"
    end
    f:write(html_content)
    f:close()

    -- Convert to PDF
    local exit_code = os.execute("wkhtmltopdf --quiet " .. tmp .. " " .. output_path)
    os.remove(tmp)

    if exit_code ~= 0 then
        return nil, "wkhtmltopdf conversion failed"
    end

    return output_path
end

return PdfGenerator
