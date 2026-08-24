--[[
    Classification CSV helpers for Admin AI Training uploads.

    Fingerprint + synonym column guessing + parse-with-mapping.
    Category label → tax category mapping stays in tax-admin-profiles.lua.
]]

local cjson = require("cjson")

local M = {}

-- ============================================================================
-- CSV parsing
-- ============================================================================

function M.parseCSVLine(line)
    local fields = {}
    local pos = 1
    while pos <= #line do
        if line:sub(pos, pos) == '"' then
            local closing = line:find('"', pos + 1)
            while closing and line:sub(closing + 1, closing + 1) == '"' do
                closing = line:find('"', closing + 2)
            end
            if closing then
                table.insert(fields, (line:sub(pos + 1, closing - 1):gsub('""', '"')))
                pos = closing + 2 -- skip closing quote + comma
            else
                table.insert(fields, line:sub(pos + 1))
                break
            end
        else
            local next_comma = line:find(",", pos)
            if next_comma then
                table.insert(fields, line:sub(pos, next_comma - 1))
                pos = next_comma + 1
            else
                table.insert(fields, line:sub(pos))
                break
            end
        end
    end
    return fields
end

function M.splitLines(csv_content)
    local lines = {}
    for line in csv_content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    return lines
end

--- Lowercase + trim a header cell.
-- The wrapping parens are load-bearing: `gsub` returns (string, count), and a
-- bare `return` propagates both. Callers doing `table.insert(t, normalizeHeader(h))`
-- would then hit the 3-arg `table.insert(list, pos, value)` overload and throw
-- "bad argument #2 to 'insert' (number expected, got string)".
function M.normalizeHeader(h)
    if not h then return "" end
    return (tostring(h):lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Ordered lowercase headers joined by `|`.
function M.fingerprint(headers)
    local parts = {}
    for _, h in ipairs(headers or {}) do
        table.insert(parts, M.normalizeHeader(h))
    end
    return table.concat(parts, "|")
end

-- ============================================================================
-- Synonym guessing
-- ============================================================================

local DATE_SYNONYMS = {
    "date", "transaction date", "value date", "posting date", "trans. date", "txn date",
}
local DESC_SYNONYMS = {
    "description", "bank description", "narrative", "memo", "details",
    "transaction description", "particulars", "payee", "counter party", "name",
}
local AMOUNT_SYNONYMS = { "amount", "value", "transaction amount" }
local DEBIT_SYNONYMS = {
    "spent", "debit", "debit amount", "money out", "withdrawn", "paid out",
}
local CREDIT_SYNONYMS = {
    "received", "credit", "credit amount", "money in", "paid in",
}
-- Accountant classification / label columns (training-specific)
local LABEL_SYNONYMS = {
    "added or matched", "rule", "transaction posted", "from/to",
    "category", "classification", "accountant", "label", "mapped category",
}

local function findBySynonyms(normalized_headers, synonyms, used)
    for _, syn in ipairs(synonyms) do
        for i, h in ipairs(normalized_headers) do
            if not used[i] and (h == syn or h:find(syn, 1, true)) then
                return i
            end
        end
    end
    return nil
end

--- Guess 1-based column indexes from header names.
-- @return table mapping, string amount_mode
function M.guessMapping(headers)
    local normalized = {}
    for _, h in ipairs(headers or {}) do
        table.insert(normalized, M.normalizeHeader(h))
    end

    local used = {}
    local mapping = {}

    local date_idx = findBySynonyms(normalized, DATE_SYNONYMS, used)
    if date_idx then used[date_idx] = true; mapping.date = date_idx end

    -- Prefer description-like over payee for description
    local desc_idx = findBySynonyms(normalized, {
        "description", "bank description", "narrative", "memo", "details",
        "transaction description", "particulars",
    }, used)
    if not desc_idx then
        desc_idx = findBySynonyms(normalized, DESC_SYNONYMS, used)
    end
    if desc_idx then used[desc_idx] = true; mapping.description = desc_idx end

    local debit_idx = findBySynonyms(normalized, DEBIT_SYNONYMS, used)
    local credit_idx = findBySynonyms(normalized, CREDIT_SYNONYMS, used)
    local amount_idx = findBySynonyms(normalized, AMOUNT_SYNONYMS, used)

    local amount_mode
    if debit_idx and credit_idx then
        used[debit_idx] = true
        used[credit_idx] = true
        mapping.debit = debit_idx
        mapping.credit = credit_idx
        amount_mode = "debit_credit"
    elseif amount_idx then
        used[amount_idx] = true
        mapping.amount = amount_idx
        amount_mode = "signed_amount"
    else
        amount_mode = "signed_amount" -- default; UI must still set amount or debit/credit
    end

    -- Label: prefer explicit accountant columns; allow a second as fallback
    local label_idx = findBySynonyms(normalized, {
        "added or matched", "transaction posted", "classification",
        "mapped category", "accountant", "category", "label",
    }, used)
    if not label_idx then
        label_idx = findBySynonyms(normalized, LABEL_SYNONYMS, used)
    end
    if label_idx then
        used[label_idx] = true
        mapping.label = label_idx
    end

    local fallback_idx = findBySynonyms(normalized, { "rule", "from/to" }, used)
    if fallback_idx then
        mapping.label_fallback = fallback_idx
    end

    return mapping, amount_mode
end

--- Validate required fields. Returns error string or nil.
function M.validateMapping(mapping, amount_mode, header_count)
    if type(mapping) ~= "table" then
        return "column_mapping is required"
    end
    local function check_idx(name, required)
        local v = mapping[name]
        if v == nil or v == cjson.null then
            if required then return name .. " column is required" end
            return nil
        end
        local n = tonumber(v)
        if not n or n < 1 or (header_count and n > header_count) then
            return name .. " column index is out of range"
        end
        return nil
    end

    local err = check_idx("date", true)
        or check_idx("description", true)
        or check_idx("label", true)
    if err then return err end

    amount_mode = amount_mode or "signed_amount"
    if amount_mode == "debit_credit" then
        err = check_idx("debit", true) or check_idx("credit", true)
    else
        err = check_idx("amount", true)
    end
    if err then return err end

    err = check_idx("label_fallback", false)
    return err
end

--- Normalize mapping values to integers (JSON may send floats/strings).
function M.normalizeMapping(mapping)
    local out = {}
    for _, key in ipairs({ "date", "description", "amount", "debit", "credit", "label", "label_fallback" }) do
        local v = mapping[key]
        if v ~= nil and v ~= cjson.null then
            out[key] = tonumber(v)
        end
    end
    return out
end

function M.sampleRows(lines, max_rows)
    max_rows = max_rows or 5
    local samples = {}
    for i = 2, math.min(#lines, 1 + max_rows) do
        table.insert(samples, M.parseCSVLine(lines[i]))
    end
    return samples
end

local function parseAmount(raw)
    if not raw or raw == "" then return nil end
    local cleaned = tostring(raw):gsub("[£,$]", ""):gsub("%s+", "")
    -- Parentheses for negatives: (12.34)
    local paren = cleaned:match("^%((.+)%)$")
    if paren then
        local n = tonumber(paren)
        return n and -n or nil
    end
    return tonumber(cleaned)
end

--- Extract date, description, signed amount, classification text from one row.
-- Amount is positive for credit, negative for debit (matches legacy Lloyds/NatWest).
-- @return date_raw, desc_raw, amount, classification_text  (or nils if skip)
function M.extractRow(fields, mapping, amount_mode)
    mapping = M.normalizeMapping(mapping)
    local date_raw = fields[mapping.date]
    local desc_raw = fields[mapping.description]

    local amount
    if amount_mode == "debit_credit" then
        local spent = parseAmount(fields[mapping.debit])
        local received = parseAmount(fields[mapping.credit])
        if (not spent or spent == 0) and (not received or received == 0) then
            return nil
        end
        amount = (received and received > 0) and received or -(spent or 0)
    else
        amount = parseAmount(fields[mapping.amount])
    end

    local classification_text = fields[mapping.label]
    if (not classification_text or classification_text == "") and mapping.label_fallback then
        classification_text = fields[mapping.label_fallback]
    end

    if not desc_raw or desc_raw == "" or not amount then
        return nil
    end

    return date_raw or "", desc_raw, amount, classification_text
end

--- Decode JSONB that may arrive as string or table from pg.
function M.decodeJsonField(val)
    if not val then return nil end
    if type(val) == "table" then return val end
    if type(val) == "string" then
        local ok, decoded = pcall(cjson.decode, val)
        if ok and type(decoded) == "table" then return decoded end
    end
    return nil
end

return M
