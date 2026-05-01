--[[
    Default Templates Module
    ========================

    Production-quality HTML templates for invoices and timesheets.
    Designed for Liquid-style template engine rendering and wkhtmltopdf conversion.

    Templates use {{variable}} and {% for %} syntax compatible with Liquid/Tera engines.
    All CSS is inline -- no external dependencies required.

    Usage:
        local DefaultTemplates = require("helper.default-templates")
        local html = DefaultTemplates.getInvoiceTemplate()
        local css  = DefaultTemplates.getInvoiceCSS()
        local data = DefaultTemplates.getInvoiceSampleData()
]]

local DefaultTemplates = {}

-- ---------------------------------------------------------------------------
-- Invoice CSS
-- ---------------------------------------------------------------------------
function DefaultTemplates.getInvoiceCSS()
    return [[
@page {
    size: A4;
    margin: 20mm 15mm 25mm 15mm;
}

@media print {
    html, body {
        width: 210mm;
        margin: 0;
        padding: 0;
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
    }
    .page-break {
        page-break-before: always;
    }
    .no-break {
        break-inside: avoid;
        page-break-inside: avoid;
    }
    .footer-space {
        height: 30mm;
    }
}

* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    font-size: 13px;
    line-height: 1.5;
    color: #1a202c;
    background: #ffffff;
    max-width: 210mm;
    margin: 0 auto;
    padding: 0;
}

/* ---- Header ---- */
.invoice-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding-bottom: 24px;
    border-bottom: 3px solid {{theme.primary_color | default: '#0052cc'}};
    margin-bottom: 32px;
}

.company-block {
    max-width: 55%;
}

.company-logo {
    max-height: 56px;
    max-width: 200px;
    margin-bottom: 10px;
    object-fit: contain;
}

.company-name {
    font-size: 22px;
    font-weight: 700;
    color: {{theme.primary_color | default: '#0052cc'}};
    margin-bottom: 4px;
    letter-spacing: -0.02em;
}

.company-details {
    font-size: 12px;
    color: #4a5568;
    line-height: 1.6;
}

.invoice-title-block {
    text-align: right;
}

.invoice-title {
    font-size: 36px;
    font-weight: 800;
    color: {{theme.primary_color | default: '#0052cc'}};
    letter-spacing: -0.03em;
    line-height: 1;
    margin-bottom: 12px;
}

.invoice-meta {
    font-size: 12px;
    color: #4a5568;
    line-height: 1.8;
}

.invoice-meta strong {
    color: #1a202c;
    display: inline-block;
    min-width: 90px;
    text-align: right;
}

.invoice-number {
    font-size: 14px;
    font-weight: 600;
    color: #1a202c;
}

/* ---- Billing Section ---- */
.billing-section {
    display: flex;
    justify-content: space-between;
    margin-bottom: 32px;
    gap: 40px;
}

.billing-block {
    flex: 1;
}

.billing-label {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #718096;
    margin-bottom: 8px;
    padding-bottom: 4px;
    border-bottom: 1px solid #e2e8f0;
}

.billing-name {
    font-size: 15px;
    font-weight: 600;
    color: #1a202c;
    margin-bottom: 4px;
}

.billing-details {
    font-size: 12px;
    color: #4a5568;
    line-height: 1.7;
}

/* ---- Line Items Table ---- */
.items-table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 28px;
    font-size: 12.5px;
}

.items-table thead th {
    background-color: {{theme.primary_color | default: '#0052cc'}};
    color: #ffffff;
    font-weight: 600;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding: 10px 12px;
    text-align: left;
    border: none;
}

.items-table thead th:first-child {
    border-radius: 4px 0 0 0;
    width: 36px;
    text-align: center;
}

.items-table thead th:last-child {
    border-radius: 0 4px 0 0;
}

.items-table thead th.text-right {
    text-align: right;
}

.items-table tbody td {
    padding: 10px 12px;
    border-bottom: 1px solid #e2e8f0;
    vertical-align: top;
}

.items-table tbody td:first-child {
    text-align: center;
    color: #718096;
    font-size: 11px;
}

.items-table tbody tr:nth-child(even) {
    background-color: #f8f9fa;
}

.items-table tbody tr:last-child td {
    border-bottom: 2px solid {{theme.primary_color | default: '#0052cc'}};
}

.items-table tbody tr {
    break-inside: avoid;
    page-break-inside: avoid;
}

.items-table .text-right {
    text-align: right;
}

.item-description {
    font-weight: 500;
    color: #1a202c;
}

.item-detail {
    font-size: 11px;
    color: #718096;
    margin-top: 2px;
}

/* ---- Totals ---- */
.totals-wrapper {
    display: flex;
    justify-content: flex-end;
    margin-bottom: 32px;
}

.totals-table {
    width: 280px;
    border-collapse: collapse;
}

.totals-table td {
    padding: 6px 0;
    font-size: 13px;
}

.totals-table .label {
    color: #4a5568;
    text-align: left;
}

.totals-table .value {
    text-align: right;
    font-weight: 500;
    color: #1a202c;
}

.totals-table .subtotal-row td {
    padding-bottom: 10px;
}

.totals-table .discount-row .value {
    color: #e53e3e;
}

.totals-table .total-divider td {
    border-top: 2px solid #1a202c;
    padding-top: 10px;
}

.totals-table .grand-total .label,
.totals-table .grand-total .value {
    font-size: 18px;
    font-weight: 700;
    color: #1a202c;
}

.balance-due-box {
    background-color: {{theme.primary_color | default: '#0052cc'}};
    color: #ffffff;
    padding: 14px 20px;
    border-radius: 6px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-top: 12px;
    width: 280px;
    margin-left: auto;
}

.balance-due-box .balance-label {
    font-size: 13px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
}

.balance-due-box .balance-amount {
    font-size: 22px;
    font-weight: 800;
    letter-spacing: -0.02em;
}

/* ---- Notes & Terms ---- */
.notes-section {
    margin-top: 36px;
    padding-top: 20px;
    border-top: 1px solid #e2e8f0;
    break-inside: avoid;
    page-break-inside: avoid;
}

.notes-section .section-title {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #718096;
    margin-bottom: 6px;
}

.notes-section .section-body {
    font-size: 12px;
    color: #4a5568;
    line-height: 1.6;
    margin-bottom: 16px;
}

/* ---- Footer ---- */
.invoice-footer {
    margin-top: 40px;
    padding-top: 16px;
    border-top: 1px solid #e2e8f0;
    text-align: center;
    font-size: 11px;
    color: #a0aec0;
    line-height: 1.6;
}

.invoice-footer .footer-thank-you {
    font-size: 14px;
    font-weight: 600;
    color: {{theme.primary_color | default: '#0052cc'}};
    margin-bottom: 6px;
}
]]
end

-- ---------------------------------------------------------------------------
-- Invoice Template
-- ---------------------------------------------------------------------------
function DefaultTemplates.getInvoiceTemplate()
    return [[<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Invoice {{invoice.number}}</title>
    <style>]] .. DefaultTemplates.getInvoiceCSS() .. [[</style>
</head>
<body>

    <!-- Header -->
    <div class="invoice-header">
        <div class="company-block">
            {% if company.logo_url %}
            <img src="{{company.logo_url}}" alt="{{company.name}}" class="company-logo">
            {% endif %}
            <div class="company-name">{{company.name}}</div>
            <div class="company-details">
                {{company.address_line1}}<br>
                {% if company.address_line2 %}{{company.address_line2}}<br>{% endif %}
                {{company.city}}, {{company.state}} {{company.postal_code}}<br>
                {% if company.country %}{{company.country}}<br>{% endif %}
                {% if company.phone %}Phone: {{company.phone}}<br>{% endif %}
                {% if company.email %}{{company.email}}{% endif %}
                {% if company.tax_id %}<br>Tax ID: {{company.tax_id}}{% endif %}
            </div>
        </div>
        <div class="invoice-title-block">
            <div class="invoice-title">INVOICE</div>
            <div class="invoice-meta">
                <strong>Invoice #:</strong> <span class="invoice-number">{{invoice.number}}</span><br>
                <strong>Date:</strong> {{invoice.date}}<br>
                <strong>Due Date:</strong> {{invoice.due_date}}<br>
                {% if invoice.po_number %}<strong>PO #:</strong> {{invoice.po_number}}<br>{% endif %}
            </div>
        </div>
    </div>

    <!-- Billing -->
    <div class="billing-section">
        <div class="billing-block">
            <div class="billing-label">Bill To</div>
            <div class="billing-name">{{client.name}}</div>
            <div class="billing-details">
                {% if client.company %}{{client.company}}<br>{% endif %}
                {% if client.address_line1 %}{{client.address_line1}}<br>{% endif %}
                {% if client.address_line2 %}{{client.address_line2}}<br>{% endif %}
                {% if client.city %}{{client.city}}, {{client.state}} {{client.postal_code}}<br>{% endif %}
                {% if client.country %}{{client.country}}<br>{% endif %}
                {% if client.email %}{{client.email}}{% endif %}
                {% if client.phone %}<br>{{client.phone}}{% endif %}
            </div>
        </div>
        {% if client.shipping_address %}
        <div class="billing-block">
            <div class="billing-label">Ship To</div>
            <div class="billing-details">{{client.shipping_address}}</div>
        </div>
        {% endif %}
    </div>

    <!-- Line Items -->
    <table class="items-table">
        <thead>
            <tr>
                <th>#</th>
                <th>Description</th>
                <th class="text-right">Qty</th>
                <th class="text-right">Unit Price</th>
                <th class="text-right">Tax</th>
                <th class="text-right">Amount</th>
            </tr>
        </thead>
        <tbody>
            {% for item in invoice.items %}
            <tr>
                <td>{{forloop.counter}}</td>
                <td>
                    <div class="item-description">{{item.description}}</div>
                    {% if item.detail %}<div class="item-detail">{{item.detail}}</div>{% endif %}
                </td>
                <td class="text-right">{{item.quantity}}</td>
                <td class="text-right">{{invoice.currency_symbol}}{{item.unit_price}}</td>
                <td class="text-right">{{item.tax_rate}}%</td>
                <td class="text-right">{{invoice.currency_symbol}}{{item.line_total}}</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>

    <!-- Totals -->
    <div class="totals-wrapper">
        <table class="totals-table">
            <tr class="subtotal-row">
                <td class="label">Subtotal</td>
                <td class="value">{{invoice.currency_symbol}}{{invoice.subtotal}}</td>
            </tr>
            {% if invoice.tax_amount and invoice.tax_amount != '0.00' %}
            <tr>
                <td class="label">Tax</td>
                <td class="value">{{invoice.currency_symbol}}{{invoice.tax_amount}}</td>
            </tr>
            {% endif %}
            {% if invoice.discount_amount and invoice.discount_amount != '0.00' %}
            <tr class="discount-row">
                <td class="label">Discount</td>
                <td class="value">-{{invoice.currency_symbol}}{{invoice.discount_amount}}</td>
            </tr>
            {% endif %}
            <tr class="total-divider grand-total">
                <td class="label">Total</td>
                <td class="value">{{invoice.currency_symbol}}{{invoice.total_amount}}</td>
            </tr>
        </table>
    </div>

    <div class="balance-due-box">
        <span class="balance-label">Balance Due</span>
        <span class="balance-amount">{{invoice.currency_symbol}}{{invoice.balance_due}}</span>
    </div>

    <!-- Notes & Terms -->
    {% if invoice.terms or invoice.notes %}
    <div class="notes-section no-break">
        {% if invoice.terms %}
        <div class="section-title">Payment Terms</div>
        <div class="section-body">{{invoice.terms}}</div>
        {% endif %}
        {% if invoice.notes %}
        <div class="section-title">Notes</div>
        <div class="section-body">{{invoice.notes}}</div>
        {% endif %}
    </div>
    {% endif %}

    <!-- Footer -->
    <div class="invoice-footer">
        <div class="footer-thank-you">Thank you for your business!</div>
        {% if theme.footer_text %}
        <div>{{theme.footer_text}}</div>
        {% endif %}
    </div>

</body>
</html>]]
end

-- ---------------------------------------------------------------------------
-- Timesheet CSS
-- ---------------------------------------------------------------------------
function DefaultTemplates.getTimesheetCSS()
    return [[
@page {
    size: A4;
    margin: 20mm 15mm 25mm 15mm;
}

@media print {
    html, body {
        width: 210mm;
        margin: 0;
        padding: 0;
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
    }
    .page-break {
        page-break-before: always;
    }
    .no-break {
        break-inside: avoid;
        page-break-inside: avoid;
    }
}

* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    font-size: 13px;
    line-height: 1.5;
    color: #1a202c;
    background: #ffffff;
    max-width: 210mm;
    margin: 0 auto;
    padding: 0;
}

/* ---- Header ---- */
.ts-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding-bottom: 24px;
    border-bottom: 3px solid {{theme.primary_color | default: '#0052cc'}};
    margin-bottom: 28px;
}

.ts-company-block {
    max-width: 55%;
}

.ts-company-logo {
    max-height: 56px;
    max-width: 200px;
    margin-bottom: 10px;
    object-fit: contain;
}

.ts-company-name {
    font-size: 22px;
    font-weight: 700;
    color: {{theme.primary_color | default: '#0052cc'}};
    margin-bottom: 4px;
    letter-spacing: -0.02em;
}

.ts-company-details {
    font-size: 12px;
    color: #4a5568;
    line-height: 1.6;
}

.ts-title-block {
    text-align: right;
}

.ts-title {
    font-size: 36px;
    font-weight: 800;
    color: {{theme.primary_color | default: '#0052cc'}};
    letter-spacing: -0.03em;
    line-height: 1;
    margin-bottom: 12px;
}

/* ---- Info Grid ---- */
.ts-info-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 20px;
    margin-bottom: 28px;
}

.ts-info-card {
    flex: 1;
    min-width: 180px;
    background: #f8f9fa;
    border-radius: 6px;
    padding: 14px 16px;
    border-left: 3px solid {{theme.primary_color | default: '#0052cc'}};
}

.ts-info-label {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #718096;
    margin-bottom: 4px;
}

.ts-info-value {
    font-size: 14px;
    font-weight: 600;
    color: #1a202c;
}

.ts-info-detail {
    font-size: 12px;
    color: #4a5568;
    margin-top: 2px;
}

/* ---- Status Badge ---- */
.ts-status-badge {
    display: inline-block;
    padding: 4px 14px;
    border-radius: 100px;
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
}

.ts-status-draft {
    background-color: #fef3c7;
    color: #92400e;
}

.ts-status-submitted {
    background-color: #dbeafe;
    color: #1e40af;
}

.ts-status-approved {
    background-color: #d1fae5;
    color: #065f46;
}

.ts-status-rejected {
    background-color: #fee2e2;
    color: #991b1b;
}

/* ---- Entries Table ---- */
.ts-entries-table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 24px;
    font-size: 12.5px;
}

.ts-entries-table thead th {
    background-color: {{theme.primary_color | default: '#0052cc'}};
    color: #ffffff;
    font-weight: 600;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding: 10px 12px;
    text-align: left;
    border: none;
}

.ts-entries-table thead th:first-child {
    border-radius: 4px 0 0 0;
}

.ts-entries-table thead th:last-child {
    border-radius: 0 4px 0 0;
}

.ts-entries-table thead th.text-right {
    text-align: right;
}

.ts-entries-table thead th.text-center {
    text-align: center;
}

.ts-entries-table tbody td {
    padding: 9px 12px;
    border-bottom: 1px solid #e2e8f0;
    vertical-align: top;
}

.ts-entries-table tbody tr:nth-child(even) {
    background-color: #f8f9fa;
}

.ts-entries-table tbody tr:last-child td {
    border-bottom: 2px solid {{theme.primary_color | default: '#0052cc'}};
}

.ts-entries-table tbody tr {
    break-inside: avoid;
    page-break-inside: avoid;
}

.ts-entries-table .text-right {
    text-align: right;
}

.ts-entries-table .text-center {
    text-align: center;
}

.ts-billable-yes {
    color: #065f46;
    font-weight: 600;
}

.ts-billable-no {
    color: #991b1b;
}

/* ---- Summary Section ---- */
.ts-summary-row {
    display: flex;
    gap: 20px;
    margin-bottom: 28px;
}

.ts-summary-card {
    flex: 1;
    text-align: center;
    padding: 16px;
    border-radius: 6px;
    border: 1px solid #e2e8f0;
}

.ts-summary-card.primary {
    background-color: {{theme.primary_color | default: '#0052cc'}};
    border-color: {{theme.primary_color | default: '#0052cc'}};
    color: #ffffff;
}

.ts-summary-number {
    font-size: 28px;
    font-weight: 800;
    letter-spacing: -0.02em;
    line-height: 1.1;
}

.ts-summary-card.primary .ts-summary-number {
    color: #ffffff;
}

.ts-summary-label {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #718096;
    margin-top: 4px;
}

.ts-summary-card.primary .ts-summary-label {
    color: rgba(255, 255, 255, 0.8);
}

/* ---- Project Breakdown ---- */
.ts-project-section {
    margin-bottom: 28px;
    break-inside: avoid;
    page-break-inside: avoid;
}

.ts-section-heading {
    font-size: 14px;
    font-weight: 700;
    color: #1a202c;
    margin-bottom: 12px;
    padding-bottom: 6px;
    border-bottom: 2px solid #e2e8f0;
}

.ts-project-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 12.5px;
}

.ts-project-table thead th {
    background-color: #f8f9fa;
    color: #4a5568;
    font-weight: 600;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding: 8px 12px;
    text-align: left;
    border-bottom: 2px solid #e2e8f0;
}

.ts-project-table tbody td {
    padding: 8px 12px;
    border-bottom: 1px solid #e2e8f0;
}

.ts-project-table tfoot td {
    padding: 10px 12px;
    font-weight: 700;
    border-top: 2px solid #1a202c;
    font-size: 13px;
}

.ts-project-table .text-right {
    text-align: right;
}

.ts-project-bar {
    height: 6px;
    background-color: #e2e8f0;
    border-radius: 3px;
    overflow: hidden;
    min-width: 80px;
}

.ts-project-bar-fill {
    height: 100%;
    background-color: {{theme.primary_color | default: '#0052cc'}};
    border-radius: 3px;
}

/* ---- Approval Section ---- */
.ts-approval-section {
    margin-top: 36px;
    padding: 20px;
    background: #f8f9fa;
    border-radius: 6px;
    border: 1px solid #e2e8f0;
    break-inside: avoid;
    page-break-inside: avoid;
}

.ts-approval-title {
    font-size: 14px;
    font-weight: 700;
    color: #1a202c;
    margin-bottom: 16px;
}

.ts-approval-grid {
    display: flex;
    gap: 40px;
}

.ts-approval-field {
    flex: 1;
}

.ts-approval-field-label {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #718096;
    margin-bottom: 4px;
}

.ts-approval-field-value {
    font-size: 13px;
    color: #1a202c;
    font-weight: 500;
}

.ts-signature-line {
    margin-top: 32px;
    display: flex;
    gap: 60px;
}

.ts-signature-block {
    flex: 1;
}

.ts-signature-rule {
    border: none;
    border-top: 1px solid #1a202c;
    margin-bottom: 6px;
}

.ts-signature-caption {
    font-size: 11px;
    color: #718096;
}

/* ---- Footer ---- */
.ts-footer {
    margin-top: 40px;
    padding-top: 16px;
    border-top: 1px solid #e2e8f0;
    text-align: center;
    font-size: 11px;
    color: #a0aec0;
    line-height: 1.6;
}
]]
end

-- ---------------------------------------------------------------------------
-- Timesheet Template
-- ---------------------------------------------------------------------------
function DefaultTemplates.getTimesheetTemplate()
    return [[<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Timesheet - {{employee.name}} - {{timesheet.period_start}} to {{timesheet.period_end}}</title>
    <style>]] .. DefaultTemplates.getTimesheetCSS() .. [[</style>
</head>
<body>

    <!-- Header -->
    <div class="ts-header">
        <div class="ts-company-block">
            {% if company.logo_url %}
            <img src="{{company.logo_url}}" alt="{{company.name}}" class="ts-company-logo">
            {% endif %}
            <div class="ts-company-name">{{company.name}}</div>
            <div class="ts-company-details">
                {{company.address_line1}}<br>
                {% if company.address_line2 %}{{company.address_line2}}<br>{% endif %}
                {{company.city}}, {{company.state}} {{company.postal_code}}
            </div>
        </div>
        <div class="ts-title-block">
            <div class="ts-title">TIMESHEET</div>
        </div>
    </div>

    <!-- Info Cards -->
    <div class="ts-info-grid">
        <div class="ts-info-card">
            <div class="ts-info-label">Employee</div>
            <div class="ts-info-value">{{employee.name}}</div>
            <div class="ts-info-detail">{{employee.email}}</div>
            {% if employee.department %}
            <div class="ts-info-detail">{{employee.department}}</div>
            {% endif %}
            {% if employee.employee_id %}
            <div class="ts-info-detail">ID: {{employee.employee_id}}</div>
            {% endif %}
        </div>
        <div class="ts-info-card">
            <div class="ts-info-label">Period</div>
            <div class="ts-info-value">{{timesheet.period_start}}</div>
            <div class="ts-info-detail">to {{timesheet.period_end}}</div>
        </div>
        <div class="ts-info-card">
            <div class="ts-info-label">Manager</div>
            <div class="ts-info-value">{{timesheet.approved_by}}</div>
        </div>
        <div class="ts-info-card">
            <div class="ts-info-label">Status</div>
            <div class="ts-info-value">
                <span class="ts-status-badge ts-status-{{timesheet.status | downcase}}">{{timesheet.status}}</span>
            </div>
        </div>
    </div>

    <!-- Summary Cards -->
    <div class="ts-summary-row">
        <div class="ts-summary-card primary">
            <div class="ts-summary-number">{{timesheet.total_hours}}</div>
            <div class="ts-summary-label">Total Hours</div>
        </div>
        <div class="ts-summary-card">
            <div class="ts-summary-number">{{timesheet.billable_hours}}</div>
            <div class="ts-summary-label">Billable Hours</div>
        </div>
        <div class="ts-summary-card">
            <div class="ts-summary-number">{{timesheet.non_billable_hours}}</div>
            <div class="ts-summary-label">Non-Billable</div>
        </div>
        {% if timesheet.overtime_hours %}
        <div class="ts-summary-card">
            <div class="ts-summary-number">{{timesheet.overtime_hours}}</div>
            <div class="ts-summary-label">Overtime</div>
        </div>
        {% endif %}
    </div>

    <!-- Time Entries -->
    <table class="ts-entries-table">
        <thead>
            <tr>
                <th>Date</th>
                <th>Project</th>
                <th>Description</th>
                <th>Category</th>
                <th class="text-right">Hours</th>
                <th class="text-center">Billable</th>
            </tr>
        </thead>
        <tbody>
            {% for entry in timesheet.entries %}
            <tr>
                <td style="white-space:nowrap;">{{entry.date}}</td>
                <td style="font-weight:500;">{{entry.project}}</td>
                <td>{{entry.description}}</td>
                <td>{{entry.category}}</td>
                <td class="text-right" style="font-weight:600;">{{entry.hours}}</td>
                <td class="text-center">
                    {% if entry.billable %}
                    <span class="ts-billable-yes">Yes</span>
                    {% else %}
                    <span class="ts-billable-no">No</span>
                    {% endif %}
                </td>
            </tr>
            {% endfor %}
        </tbody>
    </table>

    <!-- Hours by Project -->
    <div class="ts-project-section">
        <div class="ts-section-heading">Hours by Project</div>
        <table class="ts-project-table">
            <thead>
                <tr>
                    <th>Project</th>
                    <th class="text-right">Hours</th>
                    <th>Distribution</th>
                    <th class="text-right">% of Total</th>
                </tr>
            </thead>
            <tbody>
                {% for project in timesheet.by_project %}
                <tr>
                    <td style="font-weight:500;">{{project.name}}</td>
                    <td class="text-right">{{project.hours}}</td>
                    <td>
                        <div class="ts-project-bar">
                            <div class="ts-project-bar-fill" style="width: {{project.percentage}}%;"></div>
                        </div>
                    </td>
                    <td class="text-right">{{project.percentage}}%</td>
                </tr>
                {% endfor %}
            </tbody>
            <tfoot>
                <tr>
                    <td>Total</td>
                    <td class="text-right">{{timesheet.total_hours}}</td>
                    <td></td>
                    <td class="text-right">100%</td>
                </tr>
            </tfoot>
        </table>
    </div>

    <!-- Approval Section -->
    <div class="ts-approval-section">
        <div class="ts-approval-title">Approval</div>
        <div class="ts-approval-grid">
            <div class="ts-approval-field">
                <div class="ts-approval-field-label">Status</div>
                <div class="ts-approval-field-value">
                    <span class="ts-status-badge ts-status-{{timesheet.status | downcase}}">{{timesheet.status}}</span>
                </div>
            </div>
            <div class="ts-approval-field">
                <div class="ts-approval-field-label">Approved By</div>
                <div class="ts-approval-field-value">{{timesheet.approved_by}}</div>
            </div>
            <div class="ts-approval-field">
                <div class="ts-approval-field-label">Date</div>
                <div class="ts-approval-field-value">{{timesheet.approval_date}}</div>
            </div>
        </div>
        <div class="ts-signature-line">
            <div class="ts-signature-block">
                <hr class="ts-signature-rule">
                <div class="ts-signature-caption">Employee Signature</div>
            </div>
            <div class="ts-signature-block">
                <hr class="ts-signature-rule">
                <div class="ts-signature-caption">Manager Signature</div>
            </div>
            <div class="ts-signature-block">
                <hr class="ts-signature-rule">
                <div class="ts-signature-caption">Date</div>
            </div>
        </div>
    </div>

    <!-- Footer -->
    <div class="ts-footer">
        {% if theme.footer_text %}
        <div>{{theme.footer_text}}</div>
        {% endif %}
    </div>

</body>
</html>]]
end

-- ---------------------------------------------------------------------------
-- Invoice Sample Data
-- ---------------------------------------------------------------------------
function DefaultTemplates.getInvoiceSampleData()
    return {
        company = {
            name = "Acme Corporation",
            logo_url = "",
            address_line1 = "100 Innovation Drive",
            address_line2 = "Suite 400",
            city = "San Francisco",
            state = "CA",
            postal_code = "94105",
            country = "United States",
            phone = "+1 (415) 555-0100",
            email = "billing@acmecorp.com",
            tax_id = "US-12-3456789"
        },
        client = {
            name = "Sarah Chen",
            company = "Widget Manufacturing Ltd.",
            address_line1 = "250 Commerce Boulevard",
            address_line2 = "Building C",
            city = "Austin",
            state = "TX",
            postal_code = "73301",
            country = "United States",
            email = "accounts@widgetmfg.com",
            phone = "+1 (512) 555-0200"
        },
        invoice = {
            number = "INV-2026-0042",
            date = "2026-03-15",
            due_date = "2026-04-14",
            po_number = "PO-78432",
            currency = "USD",
            currency_symbol = "$",
            status = "sent",
            items = {
                {
                    description = "Enterprise Platform License",
                    detail = "Annual subscription - 50 seats",
                    quantity = 1,
                    unit_price = "4,500.00",
                    tax_rate = "8.25",
                    line_total = "4,871.25"
                },
                {
                    description = "Custom API Integration",
                    detail = "REST API connector for ERP system",
                    quantity = 40,
                    unit_price = "150.00",
                    tax_rate = "8.25",
                    line_total = "6,495.00"
                },
                {
                    description = "Data Migration Service",
                    detail = "Migration of 2.4M records from legacy system",
                    quantity = 1,
                    unit_price = "3,200.00",
                    tax_rate = "8.25",
                    line_total = "3,464.00"
                },
                {
                    description = "Staff Training Workshop",
                    detail = "2-day on-site training for 15 team members",
                    quantity = 2,
                    unit_price = "1,800.00",
                    tax_rate = "0",
                    line_total = "3,600.00"
                },
                {
                    description = "Priority Support Plan",
                    detail = "12-month premium support with 4-hour SLA",
                    quantity = 12,
                    unit_price = "299.00",
                    tax_rate = "8.25",
                    line_total = "3,884.01"
                }
            },
            subtotal = "18,488.00",
            tax_amount = "1,526.26",
            discount_amount = "500.00",
            total_amount = "19,514.26",
            balance_due = "19,514.26",
            terms = "Payment is due within 30 days of the invoice date. Late payments are subject to a 1.5% monthly finance charge. Please include the invoice number on all payments.",
            notes = "Thank you for choosing Acme Corporation. For questions about this invoice, contact billing@acmecorp.com or call +1 (415) 555-0100."
        },
        theme = {
            primary_color = "#0052cc",
            footer_text = "Acme Corporation | 100 Innovation Drive, Suite 400, San Francisco, CA 94105 | acmecorp.com"
        }
    }
end

-- ---------------------------------------------------------------------------
-- Timesheet Sample Data
-- ---------------------------------------------------------------------------
function DefaultTemplates.getTimesheetSampleData()
    return {
        company = {
            name = "Acme Corporation",
            logo_url = "",
            address_line1 = "100 Innovation Drive, Suite 400",
            city = "San Francisco",
            state = "CA",
            postal_code = "94105"
        },
        employee = {
            name = "John Smith",
            email = "john.smith@acmecorp.com",
            department = "Engineering",
            employee_id = "EMP-1042"
        },
        timesheet = {
            period_start = "2026-01-01",
            period_end = "2026-01-15",
            status = "Approved",
            approved_by = "Lisa Rodriguez",
            approval_date = "2026-01-17",
            total_hours = "86.5",
            billable_hours = "72.0",
            non_billable_hours = "14.5",
            overtime_hours = "6.5",
            entries = {
                {
                    date = "2026-01-02",
                    project = "Widget Platform",
                    description = "API endpoint development for order processing module",
                    category = "Development",
                    hours = "8.0",
                    billable = true
                },
                {
                    date = "2026-01-03",
                    project = "Widget Platform",
                    description = "Unit tests for order processing endpoints",
                    category = "Testing",
                    hours = "6.5",
                    billable = true
                },
                {
                    date = "2026-01-03",
                    project = "Internal",
                    description = "Sprint planning and backlog refinement",
                    category = "Meeting",
                    hours = "1.5",
                    billable = false
                },
                {
                    date = "2026-01-06",
                    project = "Widget Platform",
                    description = "Database schema optimisation for inventory queries",
                    category = "Development",
                    hours = "7.0",
                    billable = true
                },
                {
                    date = "2026-01-06",
                    project = "Internal",
                    description = "Code review for junior developer pull requests",
                    category = "Review",
                    hours = "1.5",
                    billable = false
                },
                {
                    date = "2026-01-07",
                    project = "Data Migration",
                    description = "ETL pipeline development for legacy system migration",
                    category = "Development",
                    hours = "8.5",
                    billable = true
                },
                {
                    date = "2026-01-08",
                    project = "Data Migration",
                    description = "Data validation scripts and reconciliation testing",
                    category = "Testing",
                    hours = "8.0",
                    billable = true
                },
                {
                    date = "2026-01-09",
                    project = "Widget Platform",
                    description = "Integration testing with third-party payment gateway",
                    category = "Testing",
                    hours = "6.0",
                    billable = true
                },
                {
                    date = "2026-01-09",
                    project = "Internal",
                    description = "Team retrospective and process improvement session",
                    category = "Meeting",
                    hours = "2.0",
                    billable = false
                },
                {
                    date = "2026-01-10",
                    project = "Widget Platform",
                    description = "Production deployment and monitoring setup",
                    category = "DevOps",
                    hours = "9.0",
                    billable = true
                },
                {
                    date = "2026-01-13",
                    project = "Client Portal",
                    description = "Dashboard UI implementation with real-time charts",
                    category = "Development",
                    hours = "8.0",
                    billable = true
                },
                {
                    date = "2026-01-14",
                    project = "Client Portal",
                    description = "Responsive layout and cross-browser testing",
                    category = "Development",
                    hours = "7.5",
                    billable = true
                },
                {
                    date = "2026-01-14",
                    project = "Internal",
                    description = "Knowledge sharing presentation on caching patterns",
                    category = "Training",
                    hours = "1.5",
                    billable = false
                },
                {
                    date = "2026-01-15",
                    project = "Client Portal",
                    description = "API integration and end-to-end testing",
                    category = "Testing",
                    hours = "5.5",
                    billable = true
                },
                {
                    date = "2026-01-15",
                    project = "Internal",
                    description = "1:1 with manager, quarterly goal review",
                    category = "Meeting",
                    hours = "1.0",
                    billable = false
                }
            },
            by_project = {
                {
                    name = "Widget Platform",
                    hours = "36.5",
                    percentage = "42"
                },
                {
                    name = "Client Portal",
                    hours = "21.0",
                    percentage = "24"
                },
                {
                    name = "Data Migration",
                    hours = "16.5",
                    percentage = "19"
                },
                {
                    name = "Internal",
                    hours = "12.5",
                    percentage = "15"
                }
            }
        },
        theme = {
            primary_color = "#0052cc",
            footer_text = "Acme Corporation | Timesheet generated on 2026-01-17 | Confidential"
        }
    }
end

return DefaultTemplates
