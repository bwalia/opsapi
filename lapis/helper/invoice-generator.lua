--[[
    Invoice Generator Helper
    ========================

    Utility module for invoice number generation and calculation logic.
    Used by InvoiceQueries for consistent invoice math.
]]

local InvoiceGenerator = {}

--- Generate next invoice number for a namespace
-- Delegates to InvoiceQueries._getNextInvoiceNumber
-- @param namespace_id number
-- @return string formatted invoice number (e.g., "INV-0001")
function InvoiceGenerator.generateNumber(namespace_id)
    local InvoiceQueries = require("queries.InvoiceQueries")
    return InvoiceQueries._getNextInvoiceNumber(namespace_id)
end

--- Calculate line item total from quantity, unit price, tax rate, and discount
-- @param quantity number
-- @param unit_price number
-- @param tax_rate number (percentage, e.g., 20 for 20%)
-- @param discount_percent number (percentage, e.g., 10 for 10%)
-- @return table { subtotal, discount, tax, total }
function InvoiceGenerator.calculateLineTotal(quantity, unit_price, tax_rate, discount_percent)
    quantity = tonumber(quantity) or 0
    unit_price = tonumber(unit_price) or 0
    tax_rate = tonumber(tax_rate) or 0
    discount_percent = tonumber(discount_percent) or 0

    local subtotal = quantity * unit_price
    local discount = subtotal * (discount_percent / 100)
    local taxable = subtotal - discount
    local tax = taxable * (tax_rate / 100)
    return {
        subtotal = subtotal,
        discount = discount,
        tax = tax,
        total = taxable + tax
    }
end

--- Calculate invoice totals from an array of line items
-- @param line_items table array of line item records
-- @return table { subtotal, tax_amount, discount_amount, total_amount }
function InvoiceGenerator.calculateInvoiceTotals(line_items)
    local subtotal = 0
    local tax_amount = 0
    local discount_amount = 0
    local total_amount = 0

    for _, item in ipairs(line_items or {}) do
        local qty = tonumber(item.quantity) or 0
        local price = tonumber(item.unit_price) or 0
        local item_subtotal = qty * price
        local item_discount = tonumber(item.discount_amount) or 0
        local item_tax = tonumber(item.tax_amount) or 0
        local item_total = tonumber(item.line_total) or (item_subtotal - item_discount + item_tax)

        subtotal = subtotal + item_subtotal
        tax_amount = tax_amount + item_tax
        discount_amount = discount_amount + item_discount
        total_amount = total_amount + item_total
    end

    return {
        subtotal = subtotal,
        tax_amount = tax_amount,
        discount_amount = discount_amount,
        total_amount = total_amount
    }
end

return InvoiceGenerator
