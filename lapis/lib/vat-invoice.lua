-- VAT on our own invoices (VAT plan phase 9, docs/plans/VAT_MTD.md).
--
-- Invoices raised in OpsAPI's Invoicing module are the business's sales records:
--   * each line has a VAT code (from its tax rate, or set explicitly: exempt, outside
--     the scope, zero-rated, CIS reverse charge);
--   * check() lists what a valid VAT invoice must show and is missing (VAT Notice
--     700/21 §16): a simplified invoice is allowed up to £250 including VAT;
--   * engine_lines() turns issued invoices into sale lines for the 9-box engine —
--     by the invoice (tax point) date, or, on cash accounting, by payment.
-- Pure: no database.

local VAT = require("lib.vat")

local M = {}

M.SIMPLIFIED_LIMIT = 250
-- HMRC's wording for invoices under the reverse charge.
M.REVERSE_CHARGE_TEXT = {
    RC_CIS = "Reverse charge: customer to pay the VAT to HMRC",
    RC_SERVICES = "Reverse charge: the customer must account for the VAT",
}
-- Statuses that mean the invoice was issued (drafts, cancelled and void are not sales).
M.ISSUED = { sent = true, paid = true, partially_paid = true, overdue = true }

--- A line's VAT code: its own code if set, else from its tax rate.
function M.code_for_line(line)
    if line.vat_code and line.vat_code ~= "" and VAT.code(line.vat_code) then return VAT.code(line.vat_code).code end
    local r = tonumber(line.tax_rate) or 0
    if r == 20 then return "STD20" end
    if r == 5 then return "RED5" end
    if r == 0 then return "ZERO" end
    return nil -- a rate that isn't a UK VAT rate
end

local function money(x) return VAT.round2(tonumber(x) or 0) end

--- One line's net (after its discount) and VAT.
function M.line_amounts(line)
    local qty = tonumber(line.quantity) or 1
    local net = qty * (tonumber(line.unit_price) or 0)
    local disc = tonumber(line.discount_percent) or 0
    if disc > 0 then net = net * (1 - disc / 100) end
    net = money(net)
    local code = M.code_for_line(line)
    local def = code and VAT.code(code)
    local vat = 0
    if def and not def.no_vat and not def.reverse and def.rate > 0 then vat = money(net * def.rate / 100) end
    return net, vat, code
end

--- VAT by rate (for the invoice and for checks).
function M.breakdown(lines)
    local by, net_total, vat_total = {}, 0, 0
    for _, l in ipairs(lines or {}) do
        local net, vat, code = M.line_amounts(l)
        local k = code or "UNKNOWN"
        by[k] = by[k] or { vat_code = k, label = (VAT.code(k) or {}).label or "Not a UK VAT rate", net = 0, vat = 0 }
        by[k].net = money(by[k].net + net)
        by[k].vat = money(by[k].vat + vat)
        net_total, vat_total = net_total + net, vat_total + vat
    end
    local list = {}
    for _, v in pairs(by) do list[#list + 1] = v end
    table.sort(list, function(a, b) return a.vat_code < b.vat_code end)
    return list, money(net_total), money(vat_total)
end

--- What a valid VAT invoice must show and this one doesn't.
-- supplier: { name, address, vrn }; invoice: { invoice_number, issue_date, tax_point, customer_name,
-- customer_address, currency, total_amount }
-- @return { ok, missing = {...}, simplified_allowed, reverse_charge_text?, breakdown, net, vat }
function M.check(invoice, lines, supplier)
    invoice, lines, supplier = invoice or {}, lines or {}, supplier or {}
    local missing = {}
    local function need(cond, what) if not cond then missing[#missing + 1] = what end end
    local function present(v) return v ~= nil and v ~= "" and v ~= (ngx and ngx.null) end
    local breakdown, net, vat = M.breakdown(lines)
    local gross = net + vat
    local simplified = gross <= M.SIMPLIFIED_LIMIT

    need(present(invoice.invoice_number), "A unique invoice number")
    need(present(supplier.name), "Your business name")
    need(present(supplier.address), "Your business address")
    need(present(supplier.vrn) and VAT.valid_vrn(supplier.vrn), "Your VAT registration number")
    need(present(invoice.issue_date), "The invoice date")
    if not simplified then
        need(present(invoice.customer_name), "The customer's name")
        need(present(invoice.customer_address) and invoice.customer_address ~= "{}", "The customer's address")
    end
    need(#lines > 0, "At least one line describing the goods or services")
    for i, l in ipairs(lines) do
        if not present(l.description) then missing[#missing + 1] = "A description on line " .. i end
        if not M.code_for_line(l) then
            missing[#missing + 1] = string.format("Line %d's tax rate (%s%%) isn't a UK VAT rate", i,
                tostring(l.tax_rate))
        end
    end
    if invoice.currency and invoice.currency ~= "" and invoice.currency ~= "GBP" then
        missing[#missing + 1] = "The VAT in pounds sterling (the invoice is in " .. invoice.currency .. ")"
    end

    local rc_text
    for _, b in ipairs(breakdown) do
        if M.REVERSE_CHARGE_TEXT[b.vat_code] then rc_text = M.REVERSE_CHARGE_TEXT[b.vat_code] end
    end
    return { ok = #missing == 0, missing = missing, simplified_allowed = simplified,
        reverse_charge_text = rc_text, breakdown = breakdown, net = net, vat = vat, gross = money(gross) }
end

--- Sale lines for the 9-box engine from issued invoices in a period.
-- invoices: { { id, status, issue_date, tax_point, currency, lines = {...}, payments = { {amount, payment_date} } } }
-- opts: { period_start, period_end, scheme }
-- @return lines, skipped = { foreign_currency = n, unknown_rate = n }
function M.engine_lines(invoices, opts)
    opts = opts or {}
    local cash = opts.scheme == "cash"
    local out, skipped = {}, { foreign_currency = 0, unknown_rate = 0 }
    local function in_period(d) return d and d >= opts.period_start and d <= opts.period_end end
    for _, inv in ipairs(invoices or {}) do
        if M.ISSUED[inv.status or ""] then
            if inv.currency and inv.currency ~= "" and inv.currency ~= "GBP" then
                skipped.foreign_currency = skipped.foreign_currency + 1
            else
                local _, net_total, vat_total = M.breakdown(inv.lines)
                local gross_total = net_total + vat_total
                -- The share of the invoice that counts in this period.
                local share
                if cash then
                    local paid = 0
                    for _, p in ipairs(inv.payments or {}) do
                        if in_period(tostring(p.payment_date)) then paid = paid + (tonumber(p.amount) or 0) end
                    end
                    share = gross_total > 0 and math.min(1, paid / gross_total) or 0
                else
                    local tp = tostring(inv.tax_point or inv.issue_date or "")
                    share = in_period(tp) and 1 or 0
                end
                if share > 0 then
                    for i, l in ipairs(inv.lines or {}) do
                        local net, vat, code = M.line_amounts(l)
                        if not code then
                            skipped.unknown_rate = skipped.unknown_rate + 1
                        else
                            local def = VAT.code(code)
                            out[#out + 1] = { id = "i" .. tostring(inv.id) .. ":" .. i, direction = "sale",
                                vat_code = code, net = money(net * share), vat = money(vat * share),
                                notional_vat = def.reverse and money(net * share * def.rate / 100) or 0,
                                gross = money((net + vat) * share), description = l.description }
                        end
                    end
                end
            end
        end
    end
    return out, skipped
end

return M
