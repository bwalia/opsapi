-- luacheck: max line length 140
--[[
    Message templates (shop)
    ========================
    Pre-written subjects and bodies for the messages staff send, one or more per use case (kind), with
    {{placeholders}} filled in when a message is drafted. Pure functions; storage is
    queries/ShopMessageTemplateQueries.lua.

      KINDS          price_request   "Ask a supplier" from a quote (price, availability, delivery)
                     stock_enquiry   "Ask suppliers" from a product (in stock? lead time? price?)
                     supplier_intro  introduce the customer to a supplier, with the customer's agreement
      PLACEHOLDERS   which {{names}} each kind may use. Customer details are allowed ONLY in supplier_intro:
                     a price request or stock enquiry must never tell a supplier who the customer is.
      validate(kind, subject, body)  → true | nil, message
      render(text, vars)             → text with {{name}} replaced ({{ name }} with spaces works too);
                                       an empty value leaves its line out when the line is only that placeholder
      DEFAULTS[kind]                 the built-in wording, used until a workspace writes its own
]]

local M = {}

M.KINDS = {
    price_request = "Price request",
    stock_enquiry = "Stock enquiry",
    supplier_intro = "Supplier introduction",
}
M.KIND_ORDER = { "price_request", "stock_enquiry", "supplier_intro" }

local COMMON = {
    ["supplier.name"] = "The supplier's name",
    ["supplier.contact"] = "The supplier's contact name (or the supplier's name)",
    ["sender.name"] = "Your name",
    ["sender.email"] = "Your email address",
    ["company"] = "Our company name",
    ["date"] = "Today's date",
}

local function with(extra)
    local out = {}
    for k, v in pairs(COMMON) do out[k] = v end
    for k, v in pairs(extra) do out[k] = v end
    return out
end

M.PLACEHOLDERS = {
    price_request = with({
        ["deal.code"] = "The private deal code (the supplier's only reference)",
        ["lines"] = "The quote's lines, numbered, with each configured line's parts",
    }),
    stock_enquiry = with({
        ["product"] = "The product (brand and name)",
        ["qty"] = "How many we want",
        ["product.code"] = "Their code for it, when the product is linked to their price file",
        ["product.mpn"] = "The manufacturer's part number, when known",
        ["note"] = "The spec typed when asking (one item per line)",
    }),
    supplier_intro = with({
        ["deal.code"] = "The private deal code (so the supplier can quote it back to us)",
        ["lines"] = "What the customer needs: the quote's lines with parts",
        ["customer.name"] = "The customer's name",
        ["customer.company"] = "The customer's organisation",
        ["customer.email"] = "The customer's email address",
        ["customer.phone"] = "The customer's phone number",
        ["customer.contact"] = "The customer's name, email and phone on one line",
    }),
}

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

--- Every {{name}} in `text`, in order (names trimmed).
function M.names(text)
    local out = {}
    for n in tostring(text or ""):gmatch("{{%s*([%w%._]-)%s*}}") do out[#out + 1] = n end
    return out
end

function M.validate(kind, subject, body)
    local allowed = M.PLACEHOLDERS[kind]
    if not allowed then return nil, "Choose what the template is for" end
    if trim(subject) == "" then return nil, "Write a subject" end
    if trim(body) == "" then return nil, "Write the message" end
    if #tostring(subject) > 200 then return nil, "The subject is too long (200 characters at most)" end
    if #tostring(body) > 8000 then return nil, "The message is too long (8,000 characters at most)" end
    for _, text in ipairs({ subject, body }) do
        for _, n in ipairs(M.names(text)) do
            if not allowed[n] then
                if n:match("^customer%.") then
                    return nil, "{{" .. n .. "}} is only allowed in a supplier introduction: a " .. M.KINDS[kind]:lower()
                        .. " must never tell the supplier who the customer is"
                end
                return nil, "{{" .. n .. "}} isn't a placeholder a " .. M.KINDS[kind]:lower() .. " can use"
            end
        end
    end
    -- Unbalanced braces are almost always a typo.
    local open = select(2, tostring(body):gsub("{{", "")) + select(2, tostring(subject):gsub("{{", ""))
    local close = select(2, tostring(body):gsub("}}", "")) + select(2, tostring(subject):gsub("}}", ""))
    if open ~= close then return nil, "A placeholder is missing a {{ or }}" end
    return true
end

--- Fill in {{placeholders}}. A line that is only a placeholder whose value is empty is dropped, so optional
-- details (part number, phone) don't leave blank bullets.
function M.render(text, vars)
    vars = vars or {}
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local names = M.names(line)
        local only_empty = #names > 0
        local rendered = line:gsub("{{%s*([%w%._]-)%s*}}", function(n)
            local v = vars[n]
            if v == nil then v = "" end
            v = tostring(v)
            if v ~= "" then only_empty = false end
            return v
        end)
        -- Every placeholder on the line is empty: drop the line if what's left is only punctuation, or a
        -- label ending in ":" ("   - Part number: {{product.mpn}}" with no part number).
        local rest = trim((line:gsub("{{%s*[%w%._]-%s*}}", "")))
        if not (only_empty and (not rest:match("%w") or rest:sub(-1) == ":")) then
            out[#out + 1] = rendered
        end
    end
    -- the loop adds one line for the trailing newline we appended
    return (table.concat(out, "\n"):gsub("\n+$", ""))
end

--- Quote lines for {{lines}}: "1. 2 x Description", each configured line's parts indented below
-- (the same layout lib/deal-codes.lua request_email has always used).
-- lines: {{ description, qty, parts? = { "1 x 9950X", ... } }}
function M.lines_text(lines)
    local out = {}
    for i, l in ipairs(type(lines) == "table" and lines or {}) do
        local qty = tonumber(l.qty) or 1
        out[#out + 1] = i .. ". " .. qty .. " x " .. tostring(l.description or ""):gsub("\n+", "; ")
        for _, part in ipairs(type(l.parts) == "table" and l.parts or {}) do
            out[#out + 1] = "   - " .. tostring(part):gsub("\n+", "; ")
        end
    end
    return table.concat(out, "\n")
end

--- Free-text spec lines for {{note}}: one "   - item" per non-empty line.
function M.note_text(note)
    local out = {}
    for line in (tostring(note or "") .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("%S") then out[#out + 1] = "   - " .. (line:gsub("^%s*%-?%s*", ""):gsub("%s+$", "")) end
    end
    return table.concat(out, "\n")
end

M.DEFAULTS = {
    price_request = {
        name = "Price request (built-in)",
        subject = "Price request: {{deal.code}}",
        body = table.concat({
            "Hello {{supplier.contact}},",
            "",
            "Please could you quote for the following. Our reference is {{deal.code}}: please put it on your quote.",
            "",
            "{{lines}}",
            "",
            "For each line, please let us know: whether it is available (in stock, or the lead time), your price ex VAT, "
                .. "when you could deliver, and how long the price is valid.",
            "",
            "Thank you,",
            "{{sender.name}}",
            "{{company}}",
        }, "\n"),
    },
    stock_enquiry = {
        name = "Stock enquiry (built-in)",
        subject = "Stock enquiry: {{product}}",
        body = table.concat({
            "Hello {{supplier.contact}},",
            "",
            "Do you have the following in stock?",
            "",
            "{{qty}} x {{product}}",
            "   - Your code: {{product.code}}",
            "   - Part number: {{product.mpn}}",
            "{{note}}",
            "",
            "Please let us know how many you have in stock (or the lead time), your trade price ex VAT, "
                .. "when you could deliver, and how long the price is valid.",
            "",
            "Thank you,",
            "{{sender.name}}",
            "{{company}}",
        }, "\n"),
    },
    supplier_intro = {
        name = "Introduction to a supplier (built-in)",
        subject = "Introduction: {{customer.company}} ({{deal.code}})",
        body = table.concat({
            "Hello {{supplier.contact}},",
            "",
            "I'd like to introduce {{customer.name}} of {{customer.company}}, who I've copied in. They need:",
            "",
            "{{lines}}",
            "",
            "You're well placed to supply this quickly, so please contact them directly with availability, lead time "
                .. "and price:",
            "{{customer.contact}}",
            "",
            "Please quote our reference {{deal.code}} in your reply and on your quote, and keep us copied so we can "
                .. "help where needed.",
            "",
            "Thank you,",
            "{{sender.name}}",
            "{{company}}",
        }, "\n"),
    },
}

return M
