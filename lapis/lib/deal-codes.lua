-- luacheck: max line length 140
--[[
    Deal codes (pure rules, no database)
    ====================================
    One private, random code per deal (e.g. WS-DT5Z-994X) that ties the customer side (lead, quotes,
    orders) to the supplier side (price requests, purchase orders) inside the CRM only. Customers never
    see it; suppliers see it instead of anything that identifies the customer.

      ALPHABET                    no 0 O 1 I L (31 symbols)
      generate(opts)              opts: { prefix?, length?, bytes = fn(n) -> n random bytes }
                                  CSPRNG bytes + rejection sampling (no modulo bias)
      format(prefix, body)        "WS" .. "DT5Z994X" -> "WS-DT5Z-994X"
      valid(code)                 a well-formed code (any prefix/length within the limits)
      normalize(s)                what staff type or paste ("ws dt5z 994x", "WS-DT5Z994X") -> the code, or nil
      clean_prefix(v) / clean_length(v)   settings validation: (value) or (nil, message)
      markers(customer, numbers)  what identifies a customer: name, email, phone, organisation, WSQ numbers
      leaks(value, markers)       which of those markers appear anywhere in value (string or nested table)
      supplier_po(t)              the purchase order params for a supplier (deal code as the reference;
                                  our address unless drop-ship is confirmed)
      request_email(req, t)       the draft "Price request: <code>" email for a supplier request
      compare(lines, requests)    our price vs each supplier's price per line, profit, below-cost flags
]]

local M = {}

M.ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
M.DEFAULT_PREFIX = "WS"
M.DEFAULT_LENGTH = 8
M.MIN_LENGTH = 6
M.MAX_LENGTH = 16
M.GROUP = 4

local N = #M.ALPHABET                     -- 31
local LIMIT = 256 - (256 % N)             -- 248: bytes at or above it are thrown away (no modulo bias)
M.REJECT_FROM = LIMIT

local ALLOWED = {}
for i = 1, N do ALLOWED[M.ALPHABET:sub(i, i)] = true end

--- (prefix) or (nil, message). 1–6 letters or digits, upper case.
function M.clean_prefix(v)
    if v == nil then return M.DEFAULT_PREFIX end
    if type(v) ~= "string" then return nil, "The deal code prefix must be text" end
    local s = v:gsub("%s", ""):upper()
    if not s:match("^[A-Z0-9]+$") or #s < 1 or #s > 6 then
        return nil, "The deal code prefix must be 1 to 6 letters or numbers (for example WS)"
    end
    return s
end

--- (length) or (nil, message): how many random characters after the prefix.
function M.clean_length(v)
    if v == nil then return M.DEFAULT_LENGTH end
    local n = tonumber(v)
    if not n or n ~= math.floor(n) or n < M.MIN_LENGTH or n > M.MAX_LENGTH then
        return nil, "The deal code length must be a whole number from " .. M.MIN_LENGTH .. " to " .. M.MAX_LENGTH
    end
    return n
end

--- "WS", "DT5Z994X" -> "WS-DT5Z-994X" (groups of 4).
function M.format(prefix, body)
    local parts = { prefix }
    for i = 1, #body, M.GROUP do parts[#parts + 1] = body:sub(i, i + M.GROUP - 1) end
    return table.concat(parts, "-")
end

--- The character for one random byte, or nil when the byte is thrown away (rejection sampling: the 8 values
-- 248..255 would make the first 8 characters more likely than the rest).
function M.symbol(b)
    if b >= LIMIT then return nil end
    local i = (b % N) + 1
    return M.ALPHABET:sub(i, i)
end

--- A new code. opts.bytes(n) must return n cryptographically secure random bytes.
function M.generate(opts)
    opts = opts or {}
    local prefix = assert(M.clean_prefix(opts.prefix))
    local length = assert(M.clean_length(opts.length))
    local bytes = assert(opts.bytes, "a secure random source is required")
    local out = {}
    while #out < length do
        local chunk = bytes(length * 2)
        assert(type(chunk) == "string" and #chunk > 0, "the random source returned nothing")
        for i = 1, #chunk do
            local ch = M.symbol(chunk:byte(i))
            if ch then
                out[#out + 1] = ch
                if #out == length then break end
            end
        end
    end
    return M.format(prefix, table.concat(out))
end

--- Is this a well-formed code? prefix: 1–6 of A–Z0–9; then groups of up to 4 allowed characters,
-- every group but the last exactly 4, MIN_LENGTH..MAX_LENGTH characters in all.
function M.valid(code)
    if type(code) ~= "string" then return false end
    local prefix, rest = code:match("^([A-Z0-9]+)%-(.+)$")
    if not prefix or #prefix > 6 then return false end
    local groups, total = {}, 0
    for g in (rest .. "-"):gmatch("([^%-]*)%-") do groups[#groups + 1] = g end
    for i, g in ipairs(groups) do
        if #g == 0 or #g > M.GROUP or (i < #groups and #g ~= M.GROUP) then return false end
        for j = 1, #g do
            if not ALLOWED[g:sub(j, j)] then return false end
        end
        total = total + #g
    end
    return total >= M.MIN_LENGTH and total <= M.MAX_LENGTH
end

--- What staff type or paste -> the code, or nil. Case, spaces and missing hyphens don't matter:
-- "ws dt5z 994x", "WS-DT5Z994X" and "wsdt5z994x" (with prefix) all give "WS-DT5Z-994X".
function M.normalize(s, prefix)
    if type(s) ~= "string" then return nil end
    local t = s:upper():gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" or #t > 40 then return nil end
    if M.valid(t) then return t end
    local p, body = t:match("^([A-Z0-9]+)[%s%-_]+(.+)$")
    if not p and prefix then
        local pre = tostring(prefix):upper()
        if t:sub(1, #pre) == pre then p, body = pre, t:sub(#pre + 1) end
    end
    if not p then return nil end
    body = body:gsub("[%s%-_]", "")
    if #body < M.MIN_LENGTH or #body > M.MAX_LENGTH then return nil end
    local code = M.format(p, body)
    return M.valid(code) and code or nil
end

-- ---------------------------------------------------------------------------
-- privacy: what a supplier must never see
-- ---------------------------------------------------------------------------

local function str(v)
    if v == nil then return nil end
    if type(v) ~= "string" and type(v) ~= "number" then return nil end
    local s = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

local function digits(s) return (tostring(s):gsub("%D", "")) end

--- What identifies the customer of a deal. customer: { name, email, phone, company }; numbers: our customer
-- quote numbers (WSQ-…) and anything else that must stay on our side. Returns a list of { field, value }.
function M.markers(customer, numbers)
    customer = type(customer) == "table" and customer or {}
    local out = {}
    local function add(field, v, min)
        v = str(v)
        if v and #v >= (min or 3) then out[#out + 1] = { field = field, value = v } end
    end
    add("name", customer.name)
    add("email", customer.email)
    add("organisation", customer.company or customer.organisation or customer.company_name)
    local phone = str(customer.phone)
    if phone then
        -- Compare the national number: 07700 900123, +44 7700 900123 and 0044 7700900123 are one phone.
        local d = digits(phone):gsub("^00", ""):gsub("^44(%d%d%d%d%d%d%d%d%d)", "%1"):gsub("^0+", "")
        if #d >= 6 then out[#out + 1] = { field = "phone", value = phone, digits = d } end
    end
    for _, n in ipairs(type(numbers) == "table" and numbers or {}) do add("quote_number", n) end
    return out
end

local function walk(v, fn, seen)
    if type(v) == "table" then
        seen = seen or {}
        if seen[v] then return end
        seen[v] = true
        for k, x in pairs(v) do
            walk(k, fn, seen)
            walk(x, fn, seen)
        end
    elseif type(v) == "string" or type(v) == "number" then
        fn(tostring(v))
    end
end

--- Which customer markers appear in value (a string or any nested table). Returns a list of field names
-- (empty = nothing leaks). Case-insensitive; phone numbers are compared digit by digit.
function M.leaks(value, markers)
    local found, seen = {}, {}
    walk(value, function(s)
        local low = s:lower()
        local d = digits(s)
        for _, m in ipairs(markers or {}) do
            if not seen[m.field] then
                local hit
                if m.digits then
                    hit = d:find(m.digits, 1, true) ~= nil
                else
                    hit = low:find(m.value:lower(), 1, true) ~= nil
                end
                if hit then
                    seen[m.field] = true
                    found[#found + 1] = m.field
                end
            end
        end
    end)
    table.sort(found)
    return found
end

-- ---------------------------------------------------------------------------
-- supplier purchase orders
-- ---------------------------------------------------------------------------

local function nz(v)
    if v == nil or v == "" or (type(v) == "userdata") then return nil end
    return v
end

--- The purchase order params (PurchaseOrderQueries.create) for a supplier. Only the deal code links it to
-- the customer: the reference is the deal code, delivery goes to our own address, and the customer's
-- address (and their own PO number) are only on it when staff confirmed a drop-ship.
-- t: { deal_code, order_uuid, order_number, supplier = {uuid,name,email,phone,address,account_number,notes},
--      items, our_address = {..}, our_address_text, ship_to = {..}, ship_to_text, drop_ship (confirmed),
--      customer_po_number, delivery_method, notes (staff, for the supplier), expected_date, currency, bill_to }
function M.supplier_po(t)
    local sup = t.supplier or {}
    local drop = t.drop_ship == true
    local notes = {}
    local function add(s) if type(s) == "string" and s:match("%S") then notes[#notes + 1] = s end end
    add("Deal code: " .. tostring(t.deal_code) .. " (please quote it on your delivery note and invoice)")
    if drop and nz(t.customer_po_number) then add("End customer PO: " .. t.customer_po_number) end
    if nz(sup.account_number) then add("Our account number: " .. sup.account_number) end
    if nz(t.delivery_method) then add("Delivery method: " .. t.delivery_method) end
    add(sup.notes)
    add(t.notes)
    local metadata = {
        deal_code = t.deal_code,
        shop_order_uuid = t.order_uuid, shop_order_number = t.order_number,
        shop_supplier_uuid = nz(sup.uuid), supplier_account_number = nz(sup.account_number),
        bill_to = t.bill_to, delivery_method = nz(t.delivery_method),
        drop_ship = drop,
    }
    if drop then
        metadata.ship_to = t.ship_to
        metadata.end_customer_po = nz(t.customer_po_number)
        metadata.drop_ship_confirmed = true
    else
        metadata.deliver_to = t.our_address
    end
    return {
        supplier_name = tostring(sup.name or ""):sub(1, 255),
        supplier_email = nz(sup.email), supplier_phone = nz(sup.phone), supplier_address = nz(sup.address),
        reference = t.deal_code,
        expected_date = nz(t.expected_date),
        delivery_address = drop and nz(t.ship_to_text) or nz(t.our_address_text),
        currency = t.currency or "GBP",
        notes = table.concat(notes, "\n\n"),
        items = t.items or {},
        metadata = metadata,
    }
end

--- The fields of supplier_po's result the supplier sees (the PO email and PDF print these).
function M.supplier_visible(po)
    local m = po.metadata or {}
    return {
        supplier_name = po.supplier_name, supplier_email = po.supplier_email, supplier_phone = po.supplier_phone,
        supplier_address = po.supplier_address, reference = po.reference, delivery_address = po.delivery_address,
        notes = po.notes, items = po.items, expected_date = po.expected_date,
        bill_to = m.bill_to, delivery_method = m.delivery_method, end_customer_po = m.end_customer_po,
        supplier_account_number = m.supplier_account_number, deal_code = m.deal_code,
    }
end

-- ---------------------------------------------------------------------------
-- supplier price requests
-- ---------------------------------------------------------------------------

local function money(minor)
    local n = tonumber(minor)
    if not n then return nil end
    return string.format("£%.2f", n / 100)
end
M.money = money

--- The draft email to a supplier for a price request: subject "Price request: <code>", the spec and the
-- lines (a configured line lists its parts). Nothing about the customer, and never our prices.
-- req: { deal_code, contact_name, lines = {{description, qty, parts? = { "1 x 9950X", ... }}}, spec, notes? }
-- t: { company (our name), sender (staff name) }
function M.request_email(req, t)
    t = t or {}
    local lines = {}
    lines[#lines + 1] = "Hello" .. (nz(req.contact_name) and (" " .. req.contact_name) or "") .. ","
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Please could you quote for the following. Our reference is " .. tostring(req.deal_code)
        .. ": please put it on your quote."
    lines[#lines + 1] = ""
    for i, l in ipairs(type(req.lines) == "table" and req.lines or {}) do
        local qty = tonumber(l.qty) or 1
        local desc = tostring(l.description or ""):gsub("\n+", "; ")
        lines[#lines + 1] = i .. ". " .. qty .. " x " .. desc
        for _, part in ipairs(type(l.parts) == "table" and l.parts or {}) do
            lines[#lines + 1] = "   - " .. tostring(part):gsub("\n+", "; ")
        end
    end
    if nz(req.spec) then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Spec:"
        lines[#lines + 1] = tostring(req.spec)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "For each line, please let us know: whether it is available (in stock, or the lead time), your price ex VAT, "
        .. "when you could deliver, and how long the price is valid."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Thank you,"
    if nz(t.sender) then lines[#lines + 1] = t.sender end
    if nz(t.company) then lines[#lines + 1] = t.company end
    return {
        subject = "Price request: " .. tostring(req.deal_code),
        body = table.concat(lines, "\n"),
    }
end

--- A phone number as international digits for WhatsApp and text links: "07700 900123" → "447700900123",
-- "+1 (415) 555-0100" → "14155550100". nil when it can't be a phone number.
-- ponytail: a national number (leading 0) is taken as UK (+44); other countries need the + or 00 form.
function M.intl_phone(phone)
    if type(phone) ~= "string" then return nil end
    local d = phone:gsub("%D", "")
    if phone:match("^%s*00") then
        d = d:sub(3)
    elseif not phone:match("^%s*%+") and d:sub(1, 1) == "0" then
        d = "44" .. d:sub(2)
    end
    if #d < 8 or #d > 15 then return nil end
    return d
end

local function uri(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

--- Links that open WhatsApp or the phone's text messages with `text` ready to send → { whatsapp, sms } | nil
function M.message_links(phone, text)
    local d = M.intl_phone(phone)
    if not d then return nil end
    return { whatsapp = "https://wa.me/" .. d .. "?text=" .. uri(text), sms = "sms:+" .. d .. "?&body=" .. uri(text) }
end

--- Our customer price vs each supplier's price, per line of our quote.
-- lines: our lines { uuid, description, qty, unit_price_minor (ex VAT) }
-- requests: { uuid, supplier_name, lines = {{ line_uuid, unit_price_minor (ex VAT) }} }
-- Returns { rows = {{ line_uuid, description, qty, our_unit_minor, suppliers = {{ request_uuid, supplier_name,
--   cost_unit_minor, profit_unit_minor, profit_line_minor, below_cost }} }}, below_cost_count }
function M.compare(lines, requests)
    local rows, below = {}, 0
    for _, l in ipairs(lines or {}) do
        local our = tonumber(l.unit_price_minor)
        local qty = tonumber(l.qty) or 1
        local row = { line_uuid = l.uuid, description = l.description, qty = qty, our_unit_minor = our, suppliers = {} }
        for _, r in ipairs(requests or {}) do
            local cost
            for _, rl in ipairs(type(r.lines) == "table" and r.lines or {}) do
                if rl.line_uuid ~= nil and rl.line_uuid == l.uuid then cost = tonumber(rl.unit_price_minor) end
            end
            local cell = { request_uuid = r.uuid, supplier_name = r.supplier_name, cost_unit_minor = cost }
            if cost and our then
                cell.profit_unit_minor = our - cost
                cell.profit_line_minor = (our - cost) * qty
                cell.below_cost = our < cost
                if cell.below_cost then below = below + 1 end
            else
                cell.below_cost = false
            end
            row.suppliers[#row.suppliers + 1] = cell
        end
        rows[#rows + 1] = row
    end
    return { rows = rows, below_cost_count = below }
end

return M
