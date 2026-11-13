-- luacheck: max line length 140
--[[
    Payment methods ("Getting paid"): pure rules, no database
    ==========================================================

    How a workspace gets paid: bank accounts (bank transfer), card, cheque, other. Shown on Order
    Authorisations, bank-transfer orders and invoices as a "How to pay" block. Storage and routes:
    queries/PaymentMethodQueries.lua, routes/namespace-payment-methods.lua.

      PM.clean(input, existing?)        -> (fields, nil) | (nil, message)   validation + normalisation
      PM.formatSortCode("123456")       -> "12-34-56" | nil
      PM.normaliseIban(" gb29 nwbk ...")-> "GB29NWBK60161331926819" | nil (mod-97 checked)
      PM.publicShape(row)               -> the fields customers see
      PM.forDocuments(rows)             -> active + show_on_documents, default first, then sort_order
      PM.bankTransferAllowed(quote, methods) -> (true) | (false, reason)
      PM.invoiceLinesFromOrder(order)   -> invoice line items (pounds) for an accounting invoice
]]

local PM = {}

PM.KINDS = { bank_transfer = true, card = true, cheque = true, other = true }
PM.KIND_LIST = { "bank_transfer", "card", "cheque", "other" }
PM.MANUAL_PAID_METHODS = { bank_transfer = true, cheque = true, other = true }

local LIMITS = {
    label = 120, account_name = 160, bank_name = 120, sort_code = 8, account_number = 16, iban = 34,
    swift_bic = 11, currency = 3, instructions = 1000,
}

local function trim(v)
    if v == nil then return nil end
    if type(v) ~= "string" and type(v) ~= "number" then return nil end
    local s = tostring(v):gsub("%c", " "):match("^%s*(.-)%s*$")
    if s == "" then return nil end
    return s
end

local function truthy(v)
    return v == true or v == "true" or v == 1 or v == "1"
end

local function falsy(v)
    return v == false or v == "false" or v == 0 or v == "0"
end

--- "12 34 56" / "123456" / "12-34-56" -> "12-34-56"; anything else -> nil.
function PM.formatSortCode(v)
    local s = trim(v)
    if not s then return nil end
    local digits = s:gsub("[%s%-]", "")
    if not digits:match("^%d%d%d%d%d%d$") then return nil end
    return digits:sub(1, 2) .. "-" .. digits:sub(3, 4) .. "-" .. digits:sub(5, 6)
end

--- UK account numbers are 8 digits (some banks issue 7; we accept 6–10 digits).
function PM.cleanAccountNumber(v)
    local s = trim(v)
    if not s then return nil end
    local digits = s:gsub("[%s%-]", "")
    if not digits:match("^%d+$") or #digits < 6 or #digits > 10 then return nil end
    return digits
end

--- IBAN: spaces removed, upper case, ISO 13616 mod-97 check. nil when invalid.
function PM.normaliseIban(v)
    local s = trim(v)
    if not s then return nil end
    s = s:gsub("%s", ""):upper()
    if not s:match("^%u%u%d%d%w+$") or #s < 15 or #s > 34 then return nil end
    local moved = s:sub(5) .. s:sub(1, 4)
    local rem = 0
    for ch in moved:gmatch(".") do
        local d
        if ch:match("%d") then d = ch else d = tostring(ch:byte() - 55) end
        for digit in d:gmatch(".") do
            rem = (rem * 10 + tonumber(digit)) % 97
        end
    end
    if rem ~= 1 then return nil end
    return s
end

--- SWIFT/BIC: 8 or 11 characters (bank 4 letters, country 2 letters, location 2, branch 3).
function PM.cleanBic(v)
    local s = trim(v)
    if not s then return nil end
    s = s:gsub("%s", ""):upper()
    if not s:match("^%u%u%u%u%u%u%w%w$") and not s:match("^%u%u%u%u%u%u%w%w%w%w%w$") then return nil end
    return s
end

--- Validate and normalise a payment method. `existing` (a stored row) fills fields the input leaves
-- out, so a PUT may send only what changes. Returns (fields, nil) or (nil, message).
-- fields: kind, label, account_name, bank_name, sort_code, account_number, iban, swift_bic, currency,
--         instructions, is_default, show_on_documents, is_active, sort_order
function PM.clean(input, existing)
    if type(input) ~= "table" then return nil, "body must be an object" end
    existing = type(existing) == "table" and existing or {}
    local function pick(k)
        if input[k] ~= nil then return input[k] end
        return existing[k]
    end
    local out = {}
    out.kind = trim(pick("kind")) or "bank_transfer"
    if not PM.KINDS[out.kind] then
        return nil, "kind must be one of bank_transfer, card, cheque, other"
    end

    for _, k in ipairs({ "label", "account_name", "bank_name", "instructions" }) do
        local v = trim(pick(k))
        if v and #v > LIMITS[k] then return nil, k .. " is too long (max " .. LIMITS[k] .. " characters)" end
        out[k] = v
    end

    local currency = trim(pick("currency")) or "GBP"
    currency = currency:upper()
    if not currency:match("^%u%u%u$") then return nil, "currency must be a 3-letter ISO code, e.g. GBP" end
    out.currency = currency

    local raw_sort, raw_acc = trim(pick("sort_code")), trim(pick("account_number"))
    local raw_iban, raw_bic = trim(pick("iban")), trim(pick("swift_bic"))
    if raw_sort then
        out.sort_code = PM.formatSortCode(raw_sort)
        if not out.sort_code then return nil, "sort_code must be 6 digits, e.g. 12-34-56" end
    end
    if raw_acc then
        out.account_number = PM.cleanAccountNumber(raw_acc)
        if not out.account_number then return nil, "account_number must be 6 to 10 digits" end
    end
    if raw_iban then
        out.iban = PM.normaliseIban(raw_iban)
        if not out.iban then return nil, "iban is not a valid IBAN (check the characters and the check digits)" end
    end
    if raw_bic then
        out.swift_bic = PM.cleanBic(raw_bic)
        if not out.swift_bic then return nil, "swift_bic must be 8 or 11 characters" end
    end

    if out.kind == "bank_transfer" then
        if not out.account_name then return nil, "account_name is required for a bank account" end
        local uk = out.sort_code and out.account_number
        if (out.sort_code and not out.account_number) or (out.account_number and not out.sort_code) then
            return nil, "a UK bank account needs both sort_code and account_number"
        end
        if not uk and not out.iban then
            return nil, "a bank account needs a sort code and account number, or an IBAN"
        end
    else
        -- Bank details only make sense on a bank account.
        out.sort_code, out.account_number, out.iban, out.swift_bic = nil, nil, nil, nil
    end

    if not out.label then
        if out.kind == "bank_transfer" then
            out.label = ((out.bank_name and (out.bank_name .. " ")) or "") .. out.currency .. " account"
        elseif out.kind == "card" then
            out.label = "Card"
        elseif out.kind == "cheque" then
            out.label = "Cheque"
        else
            out.label = "Other"
        end
    end

    local function flag(k, default)
        local v = pick(k)
        if truthy(v) then return true end
        if falsy(v) then return false end
        return default
    end
    out.is_default = flag("is_default", false)
    out.show_on_documents = flag("show_on_documents", true)
    out.is_active = flag("is_active", true)
    if not out.is_active then out.is_default = false end
    local so = tonumber(pick("sort_order"))
    out.sort_order = so and math.floor(so) or 0
    return out
end

local PUBLIC_FIELDS = { "kind", "label", "account_name", "bank_name", "sort_code", "account_number", "iban", "swift_bic",
    "currency", "instructions" }
PM.PUBLIC_FIELDS = PUBLIC_FIELDS

--- What customers see. `null` is the JSON null sentinel (cjson.null) for absent fields.
function PM.publicShape(row, null)
    local out = {}
    for _, k in ipairs(PUBLIC_FIELDS) do
        local v = row[k]
        if v == nil or v == "" then v = null end
        out[k] = v
    end
    return out
end

--- Methods to print on documents: active + show_on_documents, the default first, then sort_order, then id.
function PM.forDocuments(rows)
    local out = {}
    for _, r in ipairs(rows or {}) do
        if r.is_active ~= false and r.show_on_documents ~= false then out[#out + 1] = r end
    end
    table.sort(out, function(a, b)
        local da, db_ = a.is_default == true, b.is_default == true
        if da ~= db_ then return da end
        local sa, sb = tonumber(a.sort_order) or 0, tonumber(b.sort_order) or 0
        if sa ~= sb then return sa < sb end
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    return out
end

--- Is there a bank account to pay into among these (already filtered) methods?
function PM.hasBankAccount(methods)
    for _, m in ipairs(methods or {}) do
        if m.kind == "bank_transfer" then return true end
    end
    return false
end

--- Can the customer choose bank transfer for this quote? Only an authorised (accepted) Order
-- Authorisation (kind 'order'), still within validity, fully priced, with something to pay, and only when
-- the workspace has a bank account on its documents. `q.unpriced` = count of unpriced lines.
function PM.bankTransferAllowed(q, methods)
    if type(q) ~= "table" then return false, "QUOTE_NOT_FOUND" end
    if q.kind ~= "order" then return false, "NOT_AN_ORDER_AUTHORISATION" end
    if q.status ~= "accepted" then return false, "NOT_AUTHORISED" end
    if q.is_past_validity == true then return false, "QUOTE_EXPIRED" end
    if (tonumber(q.unpriced) or 0) > 0 then return false, "QUOTE_PRICING_PENDING" end
    if (tonumber(q.total_minor) or 0) <= 0 then return false, "NOTHING_TO_PAY" end
    if not PM.hasBankAccount(methods) then return false, "NO_BANK_ACCOUNT" end
    return true
end

local function round2(n)
    return math.floor((tonumber(n) or 0) * 100 + 0.5) / 100
end

local function round4(n)
    return math.floor((tonumber(n) or 0) * 10000 + 0.5) / 10000
end

--- Accounting invoice lines (pounds, tax_rate in percent) for a shop order:
--   one line per order line at its own price and VAT rate,
--   a "Discount" line (negative, at the basket's effective VAT rate) for everything the order took off
--   (staff discount, VIP Trade discount, Workstation credit) — the gap between the lines and the order's
--   own ex-VAT subtotal — and a zero-rated "Delivery" line for shipping.
-- order: { lines = {…}, subtotal_minor, vat_minor, shipping_minor, discount_label? }
function PM.invoiceLinesFromOrder(order)
    local items = {}
    local list_sub, list_vat = 0, 0
    for _, l in ipairs(type(order.lines) == "table" and order.lines or {}) do
        local qty = math.max(1, math.floor(tonumber(l.qty) or 1))
        local unit = tonumber(l.unit_price_minor) or 0
        local sub = tonumber(l.line_subtotal_minor) or (unit * qty)
        list_sub = list_sub + sub
        list_vat = list_vat + (tonumber(l.line_vat_minor) or 0)
        local desc = tostring(l.label or l.product_name or "Item")
        if l.product_name and l.label and l.label ~= l.product_name then
            desc = tostring(l.product_name) .. " — " .. tostring(l.label)
        end
        if l.sku and l.sku ~= "" then desc = desc .. " (SKU " .. tostring(l.sku) .. ")" end
        items[#items + 1] = {
            description = desc,
            quantity = qty,
            unit_price = round2(unit / 100),
            tax_rate = round4((tonumber(l.vat_rate) or 0.2) * 100),
        }
    end
    local discount = list_sub - (tonumber(order.subtotal_minor) or list_sub)
    if discount > 0 then
        local rate = list_sub > 0 and (list_vat / list_sub) or 0.2
        items[#items + 1] = {
            description = order.discount_label and tostring(order.discount_label) or "Discount",
            quantity = 1,
            unit_price = -round2(discount / 100),
            tax_rate = round4(rate * 100),
        }
    end
    local ship = tonumber(order.shipping_minor) or 0
    if ship > 0 then
        items[#items + 1] = { description = "Delivery", quantity = 1, unit_price = round2(ship / 100), tax_rate = 0 }
    end
    return items
end

return PM
