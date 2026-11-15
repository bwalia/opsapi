-- E-invoicing readiness (VAT plan phase 11, docs/plans/VAT_MTD.md).
--
-- Invoices as structured data: UBL 2.1 in the Peppol BIS Billing 3.0 profile (the
-- EN 16931 European standard; the UK is consulting on mandatory B2B e-invoicing
-- from April 2029 and Peppol is the leading candidate model).
--
--   build(invoice, lines, supplier)  our invoice -> UBL XML
--   check(xml)                       the EN 16931 / Peppol business rules that matter
--                                    for a UK VAT invoice (a subset: not the full XSD or
--                                    Schematron, see RULES below)
--   read(xml)                        a supplier's UBL invoice -> structured data with
--                                    our VAT codes, ready to record as a purchase
--
-- XML is parsed with libxml2 (lib/saml/xml.lua): DTDs refused, no network, no
-- entity expansion. Amounts are computed here, never by the AI.

local VAT = require("lib.vat")
local VatInvoice = require("lib.vat-invoice")

local M = {}

local round2 = VAT.round2
local function num(x) return tonumber(x) or 0 end

-- Lists that must stay JSON arrays when empty.
local ok_cjson, cjson = pcall(require, "cjson")
local function array(t)
    if ok_cjson and cjson.array_mt then setmetatable(t, cjson.array_mt) end
    return t
end

M.CUSTOMIZATION_ID = "urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0"
M.PROFILE_ID = "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"
M.FORMAT = "ubl-peppol-bis3"
M.NS = {
    inv = "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
    cac = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
    cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2",
}
-- Peppol electronic address schemes (EAS).
M.EAS_UK_VAT = "9932"
M.EAS_EMAIL = "EM"

-- Our VAT codes -> EN 16931 VAT category (UNCL5305), with the exemption reason
-- an invoice must carry for the categories that aren't charged.
M.CATEGORY = {
    STD20 = { id = "S", rate = 20 },
    RED5 = { id = "S", rate = 5 },
    ZERO = { id = "Z", rate = 0 },
    EXEMPT = { id = "E", rate = 0, reason = "Exempt from VAT" },
    OUTSIDE = { id = "O", reason_code = "VATEX-EU-O", reason = "Not subject to VAT" },
    RC_SERVICES = { id = "AE", rate = 0, reason_code = "VATEX-EU-AE",
        reason = "Reverse charge: the customer must account for the VAT" },
    RC_CIS = { id = "AE", rate = 0, reason_code = "VATEX-EU-AE",
        reason = "Reverse charge: customer to pay the VAT to HMRC" },
    NI_EU_GOODS = { id = "K", rate = 0, reason_code = "VATEX-EU-IC", reason = "Intra-community supply of goods" },
    MARGIN = { id = "E", rate = 0, reason_code = "VATEX-EU-F", reason = "Margin scheme - second-hand goods" },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function esc(s)
    s = tostring(s == nil and "" or s)
    -- Drop control characters XML 1.0 can't carry.
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
M._esc = esc

local function present(v)
    return v ~= nil and v ~= "" and not (ngx and v == ngx.null) and type(v) ~= "userdata"
end

local function amount(x) return string.format("%.2f", round2(num(x))) end

-- Quantities and prices: up to 4 decimals, no trailing zeros.
local function decimal(x)
    local s = string.format("%.4f", num(x)):gsub("0+$", ""):gsub("%.$", "")
    if s == "-0" then s = "0" end
    return s
end

local function date(s)
    local d = tostring(s or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
    return d
end

local POSTCODE = "(%u%u?%d[%u%d]?%s*%d%u%u)"

--- A postal address from free text ("1 High St, Leeds, LS1 4AB") or a table
-- ({ line1, line2, city, postcode, country } and common variants).
function M.address(v)
    local a = { country = "GB" }
    if type(v) == "table" then
        a.street = v.line1 or v.address_line1 or v.street or v.address1 or v.address
        a.additional = v.line2 or v.address_line2 or v.address2
        a.city = v.city or v.town
        a.postcode = v.postcode or v.postal_code or v.zip or v.post_code
        local c = v.country_code or v.country
        if type(c) == "string" and #c == 2 then a.country = c:upper()
        elseif type(c) == "string" and c:lower():find("united kingdom") then a.country = "GB" end
        for k, val in pairs(a) do if not present(val) then a[k] = nil end end
        a.country = a.country or "GB"
        return a
    end
    local text = tostring(v or ""):gsub("\r", "")
    if text == "" then return a end
    local pc = text:upper():match(POSTCODE)
    if pc then
        a.postcode = pc
        local s, e = text:upper():find(pc, 1, true)
        text = (text:sub(1, s - 1) .. text:sub(e + 1))
    end
    local parts = {}
    for p in text:gmatch("[^,\n]+") do
        p = p:gsub("^%s+", ""):gsub("%s+$", "")
        if p ~= "" and not p:lower():match("^united kingdom$") and not p:lower():match("^uk$") then
            parts[#parts + 1] = p
        end
    end
    a.street = parts[1]
    if #parts >= 3 then a.additional = parts[2] end
    if #parts >= 2 then a.city = parts[#parts] end
    return a
end

--- Our VAT code for an EN 16931 category (reading a supplier's invoice).
function M.code_for_category(cat, rate, reason_code, supplier_country)
    cat = tostring(cat or ""):upper()
    rate = tonumber(rate) or 0
    if cat == "S" then
        if math.abs(rate - 20) < 0.001 then return "STD20" end
        if math.abs(rate - 5) < 0.001 then return "RED5" end
        return nil
    end
    if cat == "Z" or cat == "G" then return "ZERO" end
    if cat == "E" then return (reason_code == "VATEX-EU-F") and "MARGIN" or "EXEMPT" end
    if cat == "O" or cat == "L" or cat == "M" then return "OUTSIDE" end
    if cat == "AE" then return (supplier_country == "GB") and "RC_CIS" or "RC_SERVICES" end
    if cat == "K" then return "NI_EU_GOODS" end
    return nil
end

local function vat_id(v)
    if not present(v) then return nil end
    local s = tostring(v):upper():gsub("[%s%.%-]", "")
    if s:match("^%d%d%d%d%d%d%d%d%d$") then s = "GB" .. s end
    return s
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function party(x, p)
    -- p: { endpoint = {scheme, id}, name, address, vat_id, email }
    x[#x + 1] = "<cac:Party>"
    if p.endpoint then
        x[#x + 1] = string.format('<cbc:EndpointID schemeID="%s">%s</cbc:EndpointID>', esc(p.endpoint.scheme),
            esc(p.endpoint.id))
    end
    x[#x + 1] = "<cac:PartyName><cbc:Name>" .. esc(p.name) .. "</cbc:Name></cac:PartyName>"
    local a = p.address or {}
    x[#x + 1] = "<cac:PostalAddress>"
    if a.street then x[#x + 1] = "<cbc:StreetName>" .. esc(a.street) .. "</cbc:StreetName>" end
    if a.additional then
        x[#x + 1] = "<cbc:AdditionalStreetName>" .. esc(a.additional) .. "</cbc:AdditionalStreetName>"
    end
    if a.city then x[#x + 1] = "<cbc:CityName>" .. esc(a.city) .. "</cbc:CityName>" end
    if a.postcode then x[#x + 1] = "<cbc:PostalZone>" .. esc(a.postcode) .. "</cbc:PostalZone>" end
    x[#x + 1] = "<cac:Country><cbc:IdentificationCode>" .. esc(a.country or "GB")
        .. "</cbc:IdentificationCode></cac:Country></cac:PostalAddress>"
    if p.vat_id then
        x[#x + 1] = "<cac:PartyTaxScheme><cbc:CompanyID>" .. esc(p.vat_id)
            .. "</cbc:CompanyID><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:PartyTaxScheme>"
    end
    x[#x + 1] = "<cac:PartyLegalEntity><cbc:RegistrationName>" .. esc(p.name)
        .. "</cbc:RegistrationName></cac:PartyLegalEntity>"
    if p.email then
        x[#x + 1] = "<cac:Contact><cbc:ElectronicMail>" .. esc(p.email) .. "</cbc:ElectronicMail></cac:Contact>"
    end
    x[#x + 1] = "</cac:Party>"
end

local function tax_category(x, tag, cat, with_reason)
    x[#x + 1] = "<cac:" .. tag .. "><cbc:ID>" .. cat.id .. "</cbc:ID>"
    if cat.id ~= "O" then x[#x + 1] = "<cbc:Percent>" .. decimal(cat.rate or 0) .. "</cbc:Percent>" end
    if with_reason and cat.reason then
        if cat.reason_code then
            x[#x + 1] = "<cbc:TaxExemptionReasonCode>" .. cat.reason_code .. "</cbc:TaxExemptionReasonCode>"
        end
        x[#x + 1] = "<cbc:TaxExemptionReason>" .. esc(cat.reason) .. "</cbc:TaxExemptionReason>"
    end
    x[#x + 1] = "<cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:" .. tag .. ">"
end

--- Our invoice as a Peppol BIS Billing 3.0 UBL invoice.
-- invoice: { invoice_number, issue_date, due_date?, tax_point?, currency, customer_name, customer_email?,
--   customer_address? (text or table), customer_vat_number?, notes?, po_number?, amount_paid? }
-- lines: invoice_line_items rows { description, quantity, unit_price, tax_rate, discount_percent, vat_code? }
-- supplier: { name, vrn, address, email? }
-- @return xml, problems (lines that can't be expressed; the XML leaves them out)
function M.build(invoice, lines, supplier)
    invoice, lines, supplier = invoice or {}, lines or {}, supplier or {}
    local cur = present(invoice.currency) and tostring(invoice.currency):upper() or "GBP"
    local problems = {}
    local out_lines, groups, order = {}, {}, {}
    local line_total = 0
    for i, l in ipairs(lines) do
        local net, _, code = VatInvoice.line_amounts(l)
        local cat = code and M.CATEGORY[code]
        if not cat then
            problems[#problems + 1] = string.format("Line %d's tax rate (%s%%) isn't a UK VAT rate", i,
                tostring(l.tax_rate))
        else
            local qty = tonumber(l.quantity) or 1
            local price = tonumber(l.unit_price) or 0
            local gross = round2(qty * price)
            out_lines[#out_lines + 1] = { n = #out_lines + 1, line = l, net = net, cat = cat, qty = qty,
                price = price, allowance = round2(gross - net), disc = tonumber(l.discount_percent) or 0 }
            line_total = line_total + net
            local key = cat.id .. ":" .. tostring(cat.rate or "") .. ":" .. tostring(cat.reason_code or "")
            if not groups[key] then groups[key] = { cat = cat, taxable = 0 }; order[#order + 1] = key end
            groups[key].taxable = groups[key].taxable + net
        end
    end
    line_total = round2(line_total)
    -- VAT per category: taxable amount x rate, rounded (EN 16931 BR-CO-17).
    local tax_total = 0
    for _, k in ipairs(order) do
        local g = groups[k]
        g.taxable = round2(g.taxable)
        g.tax = round2(g.taxable * num(g.cat.rate) / 100)
        tax_total = tax_total + g.tax
    end
    tax_total = round2(tax_total)
    local inclusive = round2(line_total + tax_total)
    local prepaid = round2(math.max(0, num(invoice.amount_paid)))
    local payable = round2(inclusive - prepaid)

    local sup_vat = vat_id(supplier.vrn)
    local buy_vat = vat_id(invoice.customer_vat_number)
    local buyer_endpoint
    if buy_vat and buy_vat:sub(1, 2) == "GB" then
        buyer_endpoint = { scheme = M.EAS_UK_VAT, id = buy_vat }
    elseif present(invoice.customer_email) then
        buyer_endpoint = { scheme = M.EAS_EMAIL, id = invoice.customer_email }
    end

    local x = { '<?xml version="1.0" encoding="UTF-8"?>',
        '<Invoice xmlns="' .. M.NS.inv .. '" xmlns:cac="' .. M.NS.cac .. '" xmlns:cbc="' .. M.NS.cbc .. '">',
        "<cbc:CustomizationID>" .. M.CUSTOMIZATION_ID .. "</cbc:CustomizationID>",
        "<cbc:ProfileID>" .. M.PROFILE_ID .. "</cbc:ProfileID>",
        "<cbc:ID>" .. esc(invoice.invoice_number) .. "</cbc:ID>",
        "<cbc:IssueDate>" .. esc(date(invoice.issue_date)) .. "</cbc:IssueDate>" }
    if date(invoice.due_date) then x[#x + 1] = "<cbc:DueDate>" .. date(invoice.due_date) .. "</cbc:DueDate>" end
    x[#x + 1] = "<cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>"
    if present(invoice.notes) then
        x[#x + 1] = "<cbc:Note>" .. esc(tostring(invoice.notes):sub(1, 1000)) .. "</cbc:Note>"
    end
    if date(invoice.tax_point) and date(invoice.tax_point) ~= date(invoice.issue_date) then
        x[#x + 1] = "<cbc:TaxPointDate>" .. date(invoice.tax_point) .. "</cbc:TaxPointDate>"
    end
    x[#x + 1] = "<cbc:DocumentCurrencyCode>" .. esc(cur) .. "</cbc:DocumentCurrencyCode>"
    -- Peppol needs a buyer reference or an order reference: the PO, else our number.
    x[#x + 1] = "<cbc:BuyerReference>" .. esc(present(invoice.po_number) and invoice.po_number
        or invoice.invoice_number) .. "</cbc:BuyerReference>"
    x[#x + 1] = "<cac:AccountingSupplierParty>"
    party(x, { endpoint = sup_vat and { scheme = M.EAS_UK_VAT, id = sup_vat } or nil, name = supplier.name,
        address = M.address(supplier.address), vat_id = sup_vat, email = supplier.email })
    x[#x + 1] = "</cac:AccountingSupplierParty><cac:AccountingCustomerParty>"
    party(x, { endpoint = buyer_endpoint, name = invoice.customer_name,
        address = M.address(invoice.customer_address), vat_id = buy_vat, email = present(invoice.customer_email)
        and invoice.customer_email or nil })
    x[#x + 1] = "</cac:AccountingCustomerParty>"
    x[#x + 1] = '<cac:TaxTotal><cbc:TaxAmount currencyID="' .. esc(cur) .. '">' .. amount(tax_total)
        .. "</cbc:TaxAmount>"
    for _, k in ipairs(order) do
        local g = groups[k]
        x[#x + 1] = '<cac:TaxSubtotal><cbc:TaxableAmount currencyID="' .. esc(cur) .. '">' .. amount(g.taxable)
            .. '</cbc:TaxableAmount><cbc:TaxAmount currencyID="' .. esc(cur) .. '">' .. amount(g.tax)
            .. "</cbc:TaxAmount>"
        tax_category(x, "TaxCategory", g.cat, true)
        x[#x + 1] = "</cac:TaxSubtotal>"
    end
    x[#x + 1] = "</cac:TaxTotal>"
    local c = ' currencyID="' .. esc(cur) .. '"'
    x[#x + 1] = "<cac:LegalMonetaryTotal><cbc:LineExtensionAmount" .. c .. ">" .. amount(line_total)
        .. "</cbc:LineExtensionAmount><cbc:TaxExclusiveAmount" .. c .. ">" .. amount(line_total)
        .. "</cbc:TaxExclusiveAmount><cbc:TaxInclusiveAmount" .. c .. ">" .. amount(inclusive)
        .. "</cbc:TaxInclusiveAmount>"
    if prepaid > 0 then x[#x + 1] = "<cbc:PrepaidAmount" .. c .. ">" .. amount(prepaid) .. "</cbc:PrepaidAmount>" end
    x[#x + 1] = "<cbc:PayableAmount" .. c .. ">" .. amount(payable) .. "</cbc:PayableAmount></cac:LegalMonetaryTotal>"
    for _, ol in ipairs(out_lines) do
        x[#x + 1] = "<cac:InvoiceLine><cbc:ID>" .. ol.n .. '</cbc:ID><cbc:InvoicedQuantity unitCode="C62">'
            .. decimal(ol.qty) .. "</cbc:InvoicedQuantity><cbc:LineExtensionAmount" .. c .. ">" .. amount(ol.net)
            .. "</cbc:LineExtensionAmount>"
        if ol.allowance ~= 0 then
            x[#x + 1] = "<cac:AllowanceCharge><cbc:ChargeIndicator>false</cbc:ChargeIndicator>"
                .. "<cbc:AllowanceChargeReason>Discount</cbc:AllowanceChargeReason><cbc:Amount" .. c .. ">"
                .. amount(ol.allowance) .. "</cbc:Amount></cac:AllowanceCharge>"
        end
        local name = present(ol.line.description) and tostring(ol.line.description) or ("Line " .. ol.n)
        x[#x + 1] = "<cac:Item><cbc:Name>" .. esc(name:sub(1, 200)) .. "</cbc:Name>"
        tax_category(x, "ClassifiedTaxCategory", ol.cat, false)
        x[#x + 1] = "</cac:Item><cac:Price><cbc:PriceAmount" .. c .. ">" .. decimal(math.abs(ol.price))
            .. "</cbc:PriceAmount></cac:Price></cac:InvoiceLine>"
    end
    x[#x + 1] = "</Invoice>"
    return table.concat(x, "\n") .. "\n", problems
end

-- ---------------------------------------------------------------------------
-- Read and check
-- ---------------------------------------------------------------------------

local function xml_lib()
    local ok, X = pcall(require, "lib.saml.xml")
    if not ok then return nil, "XML support isn't available here" end
    return X
end

local VALID_TYPES = { ["380"] = true, ["381"] = true, ["383"] = true, ["384"] = true, ["386"] = true,
    ["389"] = true, ["751"] = true }

--- Parse a UBL invoice. @return data table or nil, message
function M.read(xml)
    local X, xerr = xml_lib()
    if not X then return nil, xerr end
    local doc, perr = X.parse(xml, M.NS)
    if not doc then return nil, perr end
    local root = doc:root()
    if not root or not X.is_ns(root, M.NS.inv, "Invoice") then
        return nil, "This isn't a UBL invoice (the root element must be Invoice)"
    end
    local function t(expr, node) return doc:text(expr, node) end
    local function party_of(base)
        local p = doc:one(base .. "/cac:Party")
        if not p then return {} end
        local ep = doc:one("cbc:EndpointID", p)
        return {
            name = t("cac:PartyLegalEntity/cbc:RegistrationName", p) or t("cac:PartyName/cbc:Name", p),
            vat_id = t("cac:PartyTaxScheme[cac:TaxScheme/cbc:ID='VAT']/cbc:CompanyID", p),
            endpoint = ep and { scheme = X.attr(ep, "schemeID"), id = t("cbc:EndpointID", p) } or nil,
            address = {
                street = t("cac:PostalAddress/cbc:StreetName", p),
                city = t("cac:PostalAddress/cbc:CityName", p),
                postcode = t("cac:PostalAddress/cbc:PostalZone", p),
                country = t("cac:PostalAddress/cac:Country/cbc:IdentificationCode", p),
            },
        }
    end
    local d = {
        customization_id = t("cbc:CustomizationID"), profile_id = t("cbc:ProfileID"),
        invoice_number = t("cbc:ID"), issue_date = t("cbc:IssueDate"), due_date = t("cbc:DueDate"),
        type_code = t("cbc:InvoiceTypeCode"), currency = t("cbc:DocumentCurrencyCode"),
        tax_point = t("cbc:TaxPointDate"), buyer_reference = t("cbc:BuyerReference"),
        order_reference = t("cac:OrderReference/cbc:ID"),
        supplier = party_of("cac:AccountingSupplierParty"), buyer = party_of("cac:AccountingCustomerParty"),
        totals = {
            line_extension = tonumber(t("cac:LegalMonetaryTotal/cbc:LineExtensionAmount")),
            tax_exclusive = tonumber(t("cac:LegalMonetaryTotal/cbc:TaxExclusiveAmount")),
            tax_inclusive = tonumber(t("cac:LegalMonetaryTotal/cbc:TaxInclusiveAmount")),
            allowances = tonumber(t("cac:LegalMonetaryTotal/cbc:AllowanceTotalAmount")) or 0,
            charges = tonumber(t("cac:LegalMonetaryTotal/cbc:ChargeTotalAmount")) or 0,
            prepaid = tonumber(t("cac:LegalMonetaryTotal/cbc:PrepaidAmount")) or 0,
            rounding = tonumber(t("cac:LegalMonetaryTotal/cbc:PayableRoundingAmount")) or 0,
            payable = tonumber(t("cac:LegalMonetaryTotal/cbc:PayableAmount")),
        },
        breakdown = {}, lines = {},
    }
    d.totals.tax = tonumber(t("cac:TaxTotal[cbc:TaxAmount/@currencyID='" .. tostring(d.currency or "")
        .. "']/cbc:TaxAmount")) or tonumber(t("cac:TaxTotal/cbc:TaxAmount"))
    local country = d.supplier.address and d.supplier.address.country
    for _, st in ipairs(doc:find("cac:TaxTotal/cac:TaxSubtotal")) do
        local cat = t("cac:TaxCategory/cbc:ID", st)
        local rate = tonumber(t("cac:TaxCategory/cbc:Percent", st))
        local reason_code = t("cac:TaxCategory/cbc:TaxExemptionReasonCode", st)
        d.breakdown[#d.breakdown + 1] = { category = cat, rate = rate,
            taxable = tonumber(t("cbc:TaxableAmount", st)), tax = tonumber(t("cbc:TaxAmount", st)),
            reason_code = reason_code, reason = t("cac:TaxCategory/cbc:TaxExemptionReason", st),
            vat_code = M.code_for_category(cat, rate, reason_code, country) }
    end
    for _, ln in ipairs(doc:find("cac:InvoiceLine")) do
        local cat = t("cac:Item/cac:ClassifiedTaxCategory/cbc:ID", ln)
        local rate = tonumber(t("cac:Item/cac:ClassifiedTaxCategory/cbc:Percent", ln))
        d.lines[#d.lines + 1] = { id = t("cbc:ID", ln), name = t("cac:Item/cbc:Name", ln),
            quantity = tonumber(t("cbc:InvoicedQuantity", ln)), unit_code = X.attr(doc:one("cbc:InvoicedQuantity", ln),
            "unitCode"), net = tonumber(t("cbc:LineExtensionAmount", ln)),
            price = tonumber(t("cac:Price/cbc:PriceAmount", ln)), category = cat, rate = rate,
            vat_code = M.code_for_category(cat, rate, nil, country) }
    end
    return d
end

--- Check a UBL invoice against the EN 16931 / Peppol BIS 3.0 rules that matter for
-- a UK VAT invoice. @return { valid, errors = { {rule, message} }, warnings, data }
function M.check(xml)
    local d, err = M.read(xml)
    if not d then return { valid = false, errors = { { rule = "XML", message = err } }, warnings = array({}) } end
    local errors, warnings = array({}), array({})
    local function e(rule, msg) errors[#errors + 1] = { rule = rule, message = msg } end
    local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 0.005 end

    if d.customization_id ~= M.CUSTOMIZATION_ID then
        e("PEPPOL-EN16931-R004", "CustomizationID must be the Peppol BIS Billing 3.0 identifier")
    end
    if d.profile_id ~= M.PROFILE_ID then e("PEPPOL-EN16931-R007", "ProfileID must be the Peppol billing process") end
    if not present(d.invoice_number) then e("BR-02", "The invoice needs a number") end
    if not (d.issue_date and d.issue_date:match("^%d%d%d%d%-%d%d%-%d%d$")) then
        e("BR-03", "The invoice needs an issue date (YYYY-MM-DD)")
    end
    if not VALID_TYPES[d.type_code or ""] then e("BR-04", "InvoiceTypeCode must be an invoice type such as 380") end
    if not (d.currency and d.currency:match("^%u%u%u$")) then e("BR-05", "The invoice needs a currency code") end
    if not present(d.buyer_reference) and not present(d.order_reference) then
        e("PEPPOL-EN16931-R003", "Give a buyer reference or an order reference")
    end
    local s, b = d.supplier, d.buyer
    if not present(s.name) then e("BR-06", "The seller's name is missing") end
    if not present(b.name) then e("BR-07", "The buyer's name is missing") end
    if not (s.address and present(s.address.country)) then e("BR-09", "The seller's address needs a country") end
    if not (b.address and present(b.address.country)) then e("BR-11", "The buyer's address needs a country") end
    if not (s.endpoint and present(s.endpoint.id) and present(s.endpoint.scheme)) then
        e("PEPPOL-EN16931-R020", "The seller needs an electronic address (EndpointID with a scheme)")
    end
    if not (b.endpoint and present(b.endpoint.id) and present(b.endpoint.scheme)) then
        e("PEPPOL-EN16931-R010", "The buyer needs an electronic address (EndpointID with a scheme)")
    end
    if #d.lines == 0 then e("BR-16", "The invoice needs at least one line") end
    local sum = 0
    for _, l in ipairs(d.lines) do
        local n = l.id or "?"
        if l.quantity == nil then e("BR-22", "Line " .. n .. " needs a quantity") end
        if not present(l.unit_code) then e("BR-23", "Line " .. n .. " needs a unit of measure") end
        if l.net == nil then e("BR-24", "Line " .. n .. " needs a net amount") else sum = sum + l.net end
        if not present(l.name) then e("BR-25", "Line " .. n .. " needs an item name") end
        if l.price == nil or l.price < 0 then e("BR-26/27", "Line " .. n .. " needs a price that isn't negative") end
        if not present(l.category) then e("BR-CO-04", "Line " .. n .. " needs a VAT category") end
    end
    local tt = d.totals
    if tt.line_extension == nil then e("BR-12", "The sum of line net amounts is missing")
    elseif not near(round2(sum), tt.line_extension) then
        e("BR-CO-10", string.format("Line net amounts add up to %.2f, not %.2f", sum, tt.line_extension))
    end
    if tt.tax_exclusive == nil then e("BR-13", "The total without VAT is missing")
    elseif tt.line_extension and not near(tt.line_extension - tt.allowances + tt.charges, tt.tax_exclusive) then
        e("BR-CO-13", "Total without VAT must be line total − allowances + charges")
    end
    if tt.tax_inclusive == nil then e("BR-14", "The total with VAT is missing")
    elseif tt.tax_exclusive and not near(tt.tax_exclusive + (tt.tax or 0), tt.tax_inclusive) then
        e("BR-CO-15", "Total with VAT must be total without VAT + VAT")
    end
    if tt.payable == nil then e("BR-15", "The amount due is missing")
    elseif tt.tax_inclusive and not near(tt.tax_inclusive - tt.prepaid + tt.rounding, tt.payable) then
        e("BR-CO-16", "Amount due must be total with VAT − paid + rounding")
    end
    local cats, tax_sum, taxable_by_cat = {}, 0, {}
    for _, l in ipairs(d.lines) do
        local k = tostring(l.category) .. ":" .. tostring(l.rate or "")
        taxable_by_cat[k] = (taxable_by_cat[k] or 0) + (l.net or 0)
    end
    for _, g in ipairs(d.breakdown) do
        cats[g.category or "?"] = true
        tax_sum = tax_sum + (g.tax or 0)
        local k = tostring(g.category) .. ":" .. tostring(g.rate or "")
        if g.taxable == nil or g.tax == nil then
            e("BR-45/46", "Each VAT breakdown needs a taxable amount and a VAT amount")
        else
            if g.category ~= "O" and not near(round2(g.taxable * (g.rate or 0) / 100), g.tax) then
                e("BR-CO-17", string.format("VAT for category %s at %s%% must be %.2f", tostring(g.category),
                    tostring(g.rate), round2(g.taxable * (g.rate or 0) / 100)))
            end
            if taxable_by_cat[k] and not near(round2(taxable_by_cat[k]), g.taxable) then
                e("BR-" .. tostring(g.category) .. "-08", "The taxable amount for category " .. tostring(g.category)
                    .. " doesn't match its lines")
            end
        end
        if g.category == "S" and (g.rate or 0) <= 0 then e("BR-S-05", "Standard-rated VAT needs a rate above 0") end
        if ({ Z = 1, E = 1, AE = 1, K = 1 })[g.category or ""] and (g.rate or 0) ~= 0 then
            e("BR-" .. g.category .. "-05", "Category " .. g.category .. " must have a 0% rate")
        end
        if ({ E = 1, AE = 1, K = 1, O = 1, G = 1 })[g.category or ""] and not present(g.reason)
            and not present(g.reason_code) then
            e("BR-" .. g.category .. "-10", "Category " .. g.category .. " needs an exemption reason")
        end
    end
    if tt.tax ~= nil and not near(round2(tax_sum), tt.tax) then
        e("BR-CO-14", "The invoice VAT total must equal the sum of the VAT breakdown")
    end
    for k in pairs(taxable_by_cat) do
        local cat = k:match("^([^:]+)")
        if not cats[cat] then e("BR-CO-18", "No VAT breakdown for category " .. cat .. " used on a line") end
    end
    if (cats.S or cats.Z or cats.E or cats.AE or cats.K) and not present(s.vat_id) then
        e("BR-S-02", "The seller's VAT number is required when VAT categories S, Z, E, AE or K are used")
    end
    if (cats.AE or cats.K) and not present(b.vat_id) then
        e("BR-AE-02", "Reverse charge and intra-community supplies need the buyer's VAT number")
    end
    if present(s.vat_id) and not tostring(s.vat_id):match("^%u%u") then
        e("BR-CO-09", "The seller's VAT number must start with a country prefix (e.g. GB)")
    end
    if d.currency and d.currency ~= "GBP" then
        warnings[#warnings + 1] = "Not in pounds: a UK VAT return needs the VAT in sterling too."
    end
    for _, l in ipairs(d.lines) do
        if not l.vat_code then
            warnings[#warnings + 1] = "Line " .. tostring(l.id) .. " has a VAT category we can't map to a UK VAT code."
        end
    end
    return { valid = #errors == 0, errors = errors, warnings = warnings, data = d }
end

--- Purchase records from a supplier's e-invoice: one per VAT category, gross
-- = taxable + VAT, with our VAT code (lib/vat). @return list or nil, message
function M.purchase_lines(d)
    local out = {}
    for _, g in ipairs(d.breakdown or {}) do
        if not g.vat_code then
            return nil, "VAT category " .. tostring(g.category) .. " can't be mapped to a UK VAT code"
        end
        local def = VAT.code(g.vat_code)
        local net, tax = round2(num(g.taxable)), round2(num(g.tax))
        out[#out + 1] = { vat_code = g.vat_code, net = net, vat = tax, gross = round2(net + tax),
            notional_vat = def.reverse and round2(net * def.rate / 100) or 0, rate = g.rate }
    end
    return out
end

return M
