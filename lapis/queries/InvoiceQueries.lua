--[[
    Invoice Queries
    ===============

    Database query functions for invoices, line items, payments, and tax rates.
    All invoice data is namespace-scoped for multi-tenant isolation.
]]

local InvoiceModel = require("models.InvoiceModel")
local InvoiceLineItemModel = require("models.InvoiceLineItemModel")
local InvoicePaymentModel = require("models.InvoicePaymentModel")
local InvoiceSequenceModel = require("models.InvoiceSequenceModel")
local InvoiceTaxRateModel = require("models.InvoiceTaxRateModel")
local Global = require("helper.global")
local InvoiceGenerator = require("helper.invoice-generator")
local db = require("lapis.db")
local cjson = require("cjson")

local InvoiceQueries = {}

-- ============================================================
-- Invoice Number Generation
-- ============================================================

--- Get or create sequence for namespace, increment, return formatted number
-- @param namespace_id number
-- @return string e.g. "INV-0001"
function InvoiceQueries._getNextInvoiceNumber(namespace_id)
    -- Try to find existing sequence
    local seq = InvoiceSequenceModel:find({ namespace_id = namespace_id })

    if not seq then
        -- Create sequence starting at 1
        seq = InvoiceSequenceModel:create({
            uuid = Global.generateUUID(),
            namespace_id = namespace_id,
            prefix = "INV",
            current_number = 1,
            created_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()")
        })
        return "INV-0001"
    end

    -- Increment the sequence
    local next_number = (seq.current_number or 0) + 1
    seq:update({
        current_number = next_number,
        updated_at = db.raw("NOW()")
    })

    local prefix = seq.prefix or "INV"
    return prefix .. "-" .. string.format("%04d", next_number)
end

-- ============================================================
-- Invoices
-- ============================================================

--- Create a new invoice
-- @param params table { namespace_id, customer_name, customer_email, customer_address, account_id, invoice_date, due_date, currency, notes, payment_terms, owner_user_uuid, line_items }
-- @return table { data = invoice }
function InvoiceQueries.create(params)
    local invoice_number = InvoiceQueries._getNextInvoiceNumber(params.namespace_id)

    local invoice = InvoiceModel:create({
        uuid = Global.generateUUID(),
        namespace_id = params.namespace_id,
        invoice_number = invoice_number,
        status = "draft",
        customer_name = params.customer_name,
        customer_email = params.customer_email,
        customer_address = params.customer_address,
        account_id = params.account_id,
        invoice_date = params.invoice_date or db.raw("CURRENT_DATE"),
        due_date = params.due_date,
        currency = params.currency or "GBP",
        notes = params.notes,
        payment_terms = params.payment_terms,
        owner_user_uuid = params.owner_user_uuid,
        subtotal = 0,
        tax_amount = 0,
        discount_amount = 0,
        total_amount = 0,
        amount_paid = 0,
        balance_due = 0,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    -- If line_items provided, create them
    if params.line_items and type(params.line_items) == "table" then
        for i, item in ipairs(params.line_items) do
            item.invoice_id = invoice.id
            item.sort_order = item.sort_order or i
            InvoiceQueries.addLineItem(invoice.id, item)
        end
        -- Recalculate totals after adding all items
        InvoiceQueries.recalculateTotals(invoice.id)
        -- Reload the invoice with updated totals
        invoice = InvoiceModel:find({ id = invoice.id })
    end

    invoice.internal_id = invoice.id
    invoice.id = invoice.uuid

    return { data = invoice }
end

--- List invoices with pagination and filtering
-- @param namespace_id number
-- @param params table { page, perPage, status, search, from_date, to_date, owner_user_uuid }
-- @return table { data, total, page, perPage }
function InvoiceQueries.list(namespace_id, params)
    local page = tonumber(params.page) or 1
    local perPage = tonumber(params.perPage) or 20
    local offset = (page - 1) * perPage

    local conditions = { "i.namespace_id = " .. db.escape_literal(namespace_id) }
    local where_values = {}

    -- Filter by status
    if params.status and params.status ~= "" and params.status ~= "all" then
        table.insert(conditions, "i.status = " .. db.escape_literal(params.status))
    end

    -- Filter by customer name search
    if params.search and params.search ~= "" then
        table.insert(conditions, "(i.customer_name ILIKE " .. db.escape_literal("%" .. params.search .. "%") ..
            " OR i.invoice_number ILIKE " .. db.escape_literal("%" .. params.search .. "%") ..
            " OR i.customer_email ILIKE " .. db.escape_literal("%" .. params.search .. "%") .. ")")
    end

    -- Filter by date range
    if params.from_date and params.from_date ~= "" then
        table.insert(conditions, "i.invoice_date >= " .. db.escape_literal(params.from_date))
    end
    if params.to_date and params.to_date ~= "" then
        table.insert(conditions, "i.invoice_date <= " .. db.escape_literal(params.to_date))
    end

    -- Filter by owner
    if params.owner_user_uuid and params.owner_user_uuid ~= "" then
        table.insert(conditions, "i.owner_user_uuid = " .. db.escape_literal(params.owner_user_uuid))
    end

    -- Exclude soft-deleted
    table.insert(conditions, "i.deleted_at IS NULL")

    local where_clause = table.concat(conditions, " AND ")

    -- Get total count
    local count_result = db.query(
        "SELECT COUNT(*) as total FROM invoices i WHERE " .. where_clause
    )
    local total = count_result and count_result[1] and tonumber(count_result[1].total) or 0

    -- Get paginated results
    local invoices = db.query([[
        SELECT
            i.id as internal_id,
            i.uuid as id,
            i.namespace_id,
            i.invoice_number,
            i.status,
            i.customer_name,
            i.customer_email,
            i.invoice_date,
            i.due_date,
            i.currency,
            i.subtotal,
            i.tax_amount,
            i.discount_amount,
            i.total_amount,
            i.amount_paid,
            i.balance_due,
            i.owner_user_uuid,
            i.sent_at,
            i.paid_at,
            i.created_at,
            i.updated_at
        FROM invoices i
        WHERE ]] .. where_clause .. [[
        ORDER BY i.created_at DESC
        LIMIT ]] .. perPage .. [[ OFFSET ]] .. offset
    )

    return {
        data = invoices or {},
        total = total,
        page = page,
        perPage = perPage
    }
end

--- Get a single invoice with line items and payments
-- @param uuid string
-- @return table|nil invoice with line_items and payments arrays
function InvoiceQueries.get(uuid)
    local invoice = InvoiceModel:find({ uuid = uuid })
    if not invoice then
        return nil
    end

    -- Check soft delete
    if invoice.deleted_at then
        return nil
    end

    invoice.internal_id = invoice.id
    local invoice_id = invoice.id
    invoice.id = invoice.uuid

    -- Get line items
    local line_items = db.query([[
        SELECT
            id as internal_id,
            uuid as id,
            invoice_id,
            description,
            quantity,
            unit_price,
            tax_rate,
            tax_amount,
            discount_percent,
            discount_amount,
            line_total,
            sort_order,
            created_at,
            updated_at
        FROM invoice_line_items
        WHERE invoice_id = ?
        ORDER BY sort_order ASC, created_at ASC
    ]], invoice_id)

    -- Get payments
    local payments = db.query([[
        SELECT
            id as internal_id,
            uuid as id,
            invoice_id,
            amount,
            payment_method,
            payment_reference,
            payment_date,
            notes,
            created_at
        FROM invoice_payments
        WHERE invoice_id = ?
        ORDER BY payment_date DESC, created_at DESC
    ]], invoice_id)

    invoice.line_items = line_items or {}
    invoice.payments = payments or {}

    return invoice
end

--- Update an invoice (only draft or sent status)
-- @param uuid string
-- @param params table
-- @return table|nil updated invoice
-- @return string|nil error message
function InvoiceQueries.update(uuid, params)
    local invoice = InvoiceModel:find({ uuid = uuid })
    if not invoice then
        return nil, "Invoice not found"
    end

    if invoice.status ~= "draft" and invoice.status ~= "sent" then
        return nil, "Cannot update invoice with status: " .. invoice.status
    end

    -- Fields allowed for update
    local update_data = {}
    local allowed_fields = {
        "customer_name", "customer_email", "customer_address", "account_id",
        "invoice_date", "due_date", "currency", "notes", "payment_terms"
    }

    for _, field in ipairs(allowed_fields) do
        if params[field] ~= nil then
            update_data[field] = params[field]
        end
    end

    update_data.updated_at = db.raw("NOW()")

    invoice:update(update_data, { returning = "*" })

    invoice.internal_id = invoice.id
    invoice.id = invoice.uuid

    return invoice
end

--- Soft delete an invoice (only draft status)
-- @param uuid string
-- @return boolean success
-- @return string|nil error message
function InvoiceQueries.delete(uuid)
    local invoice = InvoiceModel:find({ uuid = uuid })
    if not invoice then
        return false, "Invoice not found"
    end

    if invoice.status ~= "draft" then
        return false, "Can only delete draft invoices"
    end

    invoice:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })

    return true
end

--- Send an invoice (change status draft -> sent)
-- @param uuid string
-- @return table|nil updated invoice
-- @return string|nil error message
function InvoiceQueries.send(uuid)
    local invoice = InvoiceModel:find({ uuid = uuid })
    if not invoice then
        return nil, "Invoice not found"
    end

    if invoice.status ~= "draft" then
        return nil, "Can only send draft invoices"
    end

    invoice:update({
        status = "sent",
        sent_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    invoice.internal_id = invoice.id
    invoice.id = invoice.uuid

    return invoice
end

--- Mark an invoice as paid (when balance_due = 0)
-- @param uuid string
-- @return table|nil updated invoice
-- @return string|nil error message
function InvoiceQueries.markPaid(uuid)
    local invoice = InvoiceModel:find({ uuid = uuid })
    if not invoice then
        return nil, "Invoice not found"
    end

    if tonumber(invoice.balance_due) > 0 then
        return nil, "Invoice still has an outstanding balance of " .. invoice.balance_due
    end

    invoice:update({
        status = "paid",
        paid_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    invoice.internal_id = invoice.id
    invoice.id = invoice.uuid

    return invoice
end

--- Void an invoice
-- @param uuid string
-- @return table|nil updated invoice
-- @return string|nil error message
function InvoiceQueries.void(uuid)
    local invoice = InvoiceModel:find({ uuid = uuid })
    if not invoice then
        return nil, "Invoice not found"
    end

    if invoice.status == "void" then
        return nil, "Invoice is already void"
    end

    invoice:update({
        status = "void",
        voided_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    invoice.internal_id = invoice.id
    invoice.id = invoice.uuid

    return invoice
end

--- Recalculate invoice totals from line items and payments
-- @param invoice_id number (internal id)
function InvoiceQueries.recalculateTotals(invoice_id)
    local line_items = db.query([[
        SELECT quantity, unit_price, tax_amount, discount_amount, line_total
        FROM invoice_line_items
        WHERE invoice_id = ?
    ]], invoice_id)

    local totals = InvoiceGenerator.calculateInvoiceTotals(line_items or {})

    -- Get total payments
    local payment_result = db.query([[
        SELECT COALESCE(SUM(amount), 0) as total_paid
        FROM invoice_payments
        WHERE invoice_id = ?
    ]], invoice_id)

    local amount_paid = tonumber(payment_result and payment_result[1] and payment_result[1].total_paid) or 0
    local balance_due = totals.total_amount - amount_paid

    db.query([[
        UPDATE invoices
        SET subtotal = ?, tax_amount = ?, discount_amount = ?, total_amount = ?,
            amount_paid = ?, balance_due = ?, updated_at = NOW()
        WHERE id = ?
    ]], totals.subtotal, totals.tax_amount, totals.discount_amount, totals.total_amount,
       amount_paid, balance_due, invoice_id)
end

--- Create an invoice from an approved timesheet
-- @param namespace_id number
-- @param timesheet_id number|string timesheet UUID or ID
-- @param owner_user_uuid string
-- @param hourly_rate number
-- @return table { data = invoice }
-- @return string|nil error message
function InvoiceQueries.createFromTimesheet(namespace_id, timesheet_id, owner_user_uuid, hourly_rate)
    hourly_rate = tonumber(hourly_rate) or 0

    -- Get billable timesheet entries
    local entries = db.query([[
        SELECT te.id, te.description, te.hours, te.date, te.task_name
        FROM timesheet_entries te
        WHERE te.timesheet_id = ?
          AND te.is_billable = true
        ORDER BY te.date ASC
    ]], timesheet_id)

    if not entries or #entries == 0 then
        return nil, "No billable timesheet entries found"
    end

    -- Build line items from entries
    local line_items = {}
    for i, entry in ipairs(entries) do
        local description = (entry.task_name or "Work") .. " - " .. (entry.description or entry.date or "")
        local hours = tonumber(entry.hours) or 0
        local calc = InvoiceGenerator.calculateLineTotal(hours, hourly_rate, 0, 0)

        table.insert(line_items, {
            description = description,
            quantity = hours,
            unit_price = hourly_rate,
            tax_rate = 0,
            discount_percent = 0,
            tax_amount = 0,
            discount_amount = 0,
            line_total = calc.total,
            sort_order = i
        })
    end

    -- Create invoice with line items
    local result = InvoiceQueries.create({
        namespace_id = namespace_id,
        customer_name = "Timesheet Invoice",
        owner_user_uuid = owner_user_uuid,
        notes = "Generated from timesheet #" .. tostring(timesheet_id),
        line_items = line_items
    })

    return result
end

--- Get dashboard statistics for a namespace
-- @param namespace_id number
-- @return table { total_invoiced, total_paid, total_outstanding, overdue_count, by_status }
function InvoiceQueries.getDashboardStats(namespace_id)
    -- Overall totals
    local totals = db.query([[
        SELECT
            COALESCE(SUM(total_amount), 0) as total_invoiced,
            COALESCE(SUM(amount_paid), 0) as total_paid,
            COALESCE(SUM(balance_due), 0) as total_outstanding
        FROM invoices
        WHERE namespace_id = ?
          AND deleted_at IS NULL
          AND status != 'void'
    ]], namespace_id)

    -- Overdue count
    local overdue = db.query([[
        SELECT COUNT(*) as count
        FROM invoices
        WHERE namespace_id = ?
          AND deleted_at IS NULL
          AND status IN ('sent')
          AND due_date < CURRENT_DATE
          AND balance_due > 0
    ]], namespace_id)

    -- By status counts
    local by_status = db.query([[
        SELECT status, COUNT(*) as count, COALESCE(SUM(total_amount), 0) as total
        FROM invoices
        WHERE namespace_id = ?
          AND deleted_at IS NULL
        GROUP BY status
    ]], namespace_id)

    local stats_totals = totals and totals[1] or {}
    return {
        total_invoiced = tonumber(stats_totals.total_invoiced) or 0,
        total_paid = tonumber(stats_totals.total_paid) or 0,
        total_outstanding = tonumber(stats_totals.total_outstanding) or 0,
        overdue_count = overdue and overdue[1] and tonumber(overdue[1].count) or 0,
        by_status = by_status or {}
    }
end

-- ============================================================
-- Line Items
-- ============================================================

--- Add a line item to an invoice
-- @param invoice_id number (internal id)
-- @param params table { description, quantity, unit_price, tax_rate, discount_percent, sort_order }
-- @return table line item
function InvoiceQueries.addLineItem(invoice_id, params)
    local quantity = tonumber(params.quantity) or 1
    local unit_price = tonumber(params.unit_price) or 0
    local tax_rate = tonumber(params.tax_rate) or 0
    local discount_percent = tonumber(params.discount_percent) or 0

    local calc = InvoiceGenerator.calculateLineTotal(quantity, unit_price, tax_rate, discount_percent)

    local item = InvoiceLineItemModel:create({
        uuid = Global.generateUUID(),
        invoice_id = invoice_id,
        description = params.description,
        quantity = quantity,
        unit_price = unit_price,
        tax_rate = tax_rate,
        tax_amount = calc.tax,
        discount_percent = discount_percent,
        discount_amount = calc.discount,
        line_total = calc.total,
        sort_order = params.sort_order or 0,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    -- Recalculate invoice totals
    InvoiceQueries.recalculateTotals(invoice_id)

    item.internal_id = item.id
    item.id = item.uuid

    return item
end

--- Update a line item
-- @param uuid string
-- @param params table
-- @return table|nil updated item
-- @return string|nil error message
function InvoiceQueries.updateLineItem(uuid, params)
    local item = InvoiceLineItemModel:find({ uuid = uuid })
    if not item then
        return nil, "Line item not found"
    end

    local quantity = tonumber(params.quantity) or tonumber(item.quantity) or 1
    local unit_price = tonumber(params.unit_price) or tonumber(item.unit_price) or 0
    local tax_rate = tonumber(params.tax_rate) or tonumber(item.tax_rate) or 0
    local discount_percent = tonumber(params.discount_percent) or tonumber(item.discount_percent) or 0

    local calc = InvoiceGenerator.calculateLineTotal(quantity, unit_price, tax_rate, discount_percent)

    local update_data = {
        description = params.description or item.description,
        quantity = quantity,
        unit_price = unit_price,
        tax_rate = tax_rate,
        tax_amount = calc.tax,
        discount_percent = discount_percent,
        discount_amount = calc.discount,
        line_total = calc.total,
        sort_order = params.sort_order or item.sort_order,
        updated_at = db.raw("NOW()")
    }

    item:update(update_data, { returning = "*" })

    -- Recalculate invoice totals
    InvoiceQueries.recalculateTotals(item.invoice_id)

    item.internal_id = item.id
    item.id = item.uuid

    return item
end

--- Delete a line item and recalculate invoice totals
-- @param uuid string
-- @return boolean success
-- @return string|nil error message
function InvoiceQueries.deleteLineItem(uuid)
    local item = InvoiceLineItemModel:find({ uuid = uuid })
    if not item then
        return false, "Line item not found"
    end

    local invoice_id = item.invoice_id
    item:delete()

    -- Recalculate invoice totals
    InvoiceQueries.recalculateTotals(invoice_id)

    return true
end

--- Get line items for an invoice
-- @param invoice_id number (internal id)
-- @return table array of line items
function InvoiceQueries.getLineItems(invoice_id)
    local items = db.query([[
        SELECT
            id as internal_id,
            uuid as id,
            invoice_id,
            description,
            quantity,
            unit_price,
            tax_rate,
            tax_amount,
            discount_percent,
            discount_amount,
            line_total,
            sort_order,
            created_at,
            updated_at
        FROM invoice_line_items
        WHERE invoice_id = ?
        ORDER BY sort_order ASC, created_at ASC
    ]], invoice_id)

    return items or {}
end

-- ============================================================
-- Payments
-- ============================================================

--- Record a payment against an invoice
-- @param params table { invoice_id, amount, payment_method, payment_reference, payment_date, notes }
-- @return table payment
-- @return string|nil error message
function InvoiceQueries.recordPayment(params)
    local invoice = InvoiceModel:find({ id = params.invoice_id })
    if not invoice then
        -- Try by uuid
        invoice = InvoiceModel:find({ uuid = params.invoice_uuid })
        if not invoice then
            return nil, "Invoice not found"
        end
    end

    if invoice.status == "void" then
        return nil, "Cannot record payment on a voided invoice"
    end

    if invoice.status == "draft" then
        return nil, "Cannot record payment on a draft invoice. Send the invoice first."
    end

    local amount = tonumber(params.amount) or 0
    if amount <= 0 then
        return nil, "Payment amount must be greater than zero"
    end

    local payment = InvoicePaymentModel:create({
        uuid = Global.generateUUID(),
        invoice_id = invoice.id,
        amount = amount,
        payment_method = params.payment_method,
        payment_reference = params.payment_reference,
        payment_date = params.payment_date or db.raw("CURRENT_DATE"),
        notes = params.notes,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    -- Recalculate invoice totals (updates amount_paid and balance_due)
    InvoiceQueries.recalculateTotals(invoice.id)

    -- Reload invoice to check balance
    invoice = InvoiceModel:find({ id = invoice.id })
    if tonumber(invoice.balance_due) <= 0 then
        invoice:update({
            status = "paid",
            paid_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()")
        })
    end

    payment.internal_id = payment.id
    payment.id = payment.uuid

    return payment
end

--- Get payments for an invoice
-- @param invoice_id number (internal id)
-- @return table array of payments
function InvoiceQueries.getPayments(invoice_id)
    local payments = db.query([[
        SELECT
            id as internal_id,
            uuid as id,
            invoice_id,
            amount,
            payment_method,
            payment_reference,
            payment_date,
            notes,
            created_at
        FROM invoice_payments
        WHERE invoice_id = ?
        ORDER BY payment_date DESC, created_at DESC
    ]], invoice_id)

    return payments or {}
end

--- Delete a payment and recalculate invoice
-- @param uuid string
-- @return boolean success
-- @return string|nil error message
function InvoiceQueries.deletePayment(uuid)
    local payment = InvoicePaymentModel:find({ uuid = uuid })
    if not payment then
        return false, "Payment not found"
    end

    local invoice_id = payment.invoice_id
    payment:delete()

    -- Recalculate invoice totals
    InvoiceQueries.recalculateTotals(invoice_id)

    -- Check if invoice status needs to revert from paid
    local invoice = InvoiceModel:find({ id = invoice_id })
    if invoice and invoice.status == "paid" and tonumber(invoice.balance_due) > 0 then
        invoice:update({
            status = "sent",
            paid_at = db.NULL,
            updated_at = db.raw("NOW()")
        })
    end

    return true
end

-- ============================================================
-- Tax Rates
-- ============================================================

--- Create a tax rate configuration
-- @param params table { namespace_id, name, rate, description, is_default }
-- @return table tax rate
function InvoiceQueries.createTaxRate(params)
    local tax_rate = InvoiceTaxRateModel:create({
        uuid = Global.generateUUID(),
        namespace_id = params.namespace_id,
        name = params.name,
        rate = tonumber(params.rate) or 0,
        description = params.description,
        is_default = params.is_default or false,
        is_active = true,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    tax_rate.internal_id = tax_rate.id
    tax_rate.id = tax_rate.uuid

    return tax_rate
end

--- List active tax rates for a namespace
-- @param namespace_id number
-- @return table array of tax rates
function InvoiceQueries.getTaxRates(namespace_id)
    local rates = db.query([[
        SELECT
            id as internal_id,
            uuid as id,
            namespace_id,
            name,
            rate,
            description,
            is_default,
            is_active,
            created_at,
            updated_at
        FROM invoice_tax_rates
        WHERE namespace_id = ?
          AND is_active = true
        ORDER BY name ASC
    ]], namespace_id)

    return rates or {}
end

--- Update a tax rate
-- @param uuid string
-- @param params table
-- @return table|nil updated tax rate
-- @return string|nil error message
function InvoiceQueries.updateTaxRate(uuid, params)
    local rate = InvoiceTaxRateModel:find({ uuid = uuid })
    if not rate then
        return nil, "Tax rate not found"
    end

    local update_data = {}
    if params.name ~= nil then update_data.name = params.name end
    if params.rate ~= nil then update_data.rate = tonumber(params.rate) end
    if params.description ~= nil then update_data.description = params.description end
    if params.is_default ~= nil then update_data.is_default = params.is_default end
    update_data.updated_at = db.raw("NOW()")

    rate:update(update_data, { returning = "*" })

    rate.internal_id = rate.id
    rate.id = rate.uuid

    return rate
end

--- Deactivate a tax rate (soft delete)
-- @param uuid string
-- @return boolean success
-- @return string|nil error message
function InvoiceQueries.deleteTaxRate(uuid)
    local rate = InvoiceTaxRateModel:find({ uuid = uuid })
    if not rate then
        return false, "Tax rate not found"
    end

    rate:update({
        is_active = false,
        updated_at = db.raw("NOW()")
    })

    return true
end

return InvoiceQueries
