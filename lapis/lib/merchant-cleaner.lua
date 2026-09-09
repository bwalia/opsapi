--[[
    Merchant name cleaner — Lua port of diy-tax-return-uk
    backend/app/services/merchant_cleaner.py (clean_merchant_name).

    Must stay byte-for-byte aligned with the Python implementation for the
    shared fixture at lapis/spec/fixtures/merchant_cleaner_cases.json
    (mirrored in diy-tax backend/app/fixtures/merchant_cleaner_cases.json).

    Process on an uppercased copy so prefix/date matching is case-insensitive
    like Python's re.IGNORECASE.
]]

local MerchantCleaner = {}

local PREFIXES = {
    "FPI", "FPO", "BGC", "TFR", "STO", "DEB", "VIS", "DD", "SO", "CR", "DR", "BP",
}

local function trim(s)
    return (s:match("^%s*(.-)%s*$")) or ""
end

--- Clean a raw bank transaction description into a merchant name.
-- @param description string|nil
-- @return string uppercase cleaned merchant (or original uppercased if empty)
function MerchantCleaner.clean_merchant_name(description)
    if not description then
        return ""
    end
    local stripped = trim(description)
    if stripped == "" then
        return ""
    end

    local original_upper = stripped:upper()
    -- Work in uppercase so patterns match case-insensitively (Python IGNORECASE).
    local text = original_upper

    -- 1. Strip "TRANSFER VIA FASTER PAYMENT TO"
    text = text:gsub("^TRANSFER%s+VIA%s+FASTER%s+PAYMENT%s+TO%s+", "")

    -- 2. Strip one payment-method prefix (longest first — list is ordered)
    for _, pfx in ipairs(PREFIXES) do
        local pattern = "^" .. pfx .. "%s+"
        if text:match(pattern) then
            text = text:gsub(pattern, "", 1)
            break
        end
    end

    -- 3. Asterisk reference codes (*RT5TY3) then remaining asterisks → space
    text = text:gsub("%*[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]+", "")
    text = text:gsub("%*", " ")

    -- 4. Card fragments (CD 4063)
    text = text:gsub("%s+CD%s+%d%d%d%d", "")

    -- 5. Date patterns: 12/03, 12/03/26, 02MAR24, 2026-01-31
    text = text:gsub("%d%d/%d%d/%d%d%d%d", "")
    text = text:gsub("%d%d/%d%d/%d%d", "")
    text = text:gsub("%d%d/%d%d", "")
    text = text:gsub("%d%d[A-Z][A-Z][A-Z]%d%d%d%d", "")
    text = text:gsub("%d%d[A-Z][A-Z][A-Z]%d%d", "")
    text = text:gsub("%d%d%d%d%-%d%d%-%d%d", "")

    -- 6. "L REF..." trailing
    text = text:gsub("%s+L%s+REF%f[%W].*$", "")
    text = text:gsub("%s+L%s+REF$", "")

    -- 7. REF / MANDATE NO and everything after (word-boundary REF like Python \b)
    text = text:gsub("%s*%f[%w]REF%s*[:;]?%s*.*$", "")
    text = text:gsub("%s*%f[%w]MANDATE%s+NO%s*[:;]?%s*%w+.*$", "")

    -- 8. Trailing digit sequences (7+ digits)
    text = text:gsub("%s+%d%d%d%d%d%d%d+%s*$", "")

    -- 9. Corporate suffixes
    text = text:gsub("%s+LTD%s*%.?%s*$", "")
    text = text:gsub("%s+PLC%s*%.?%s*$", "")
    text = text:gsub("%s+LIMITED%s*%.?%s*$", "")
    text = text:gsub("%s+LLP%s*%.?%s*$", "")
    text = text:gsub("%s+INC%s*%.?%s*$", "")
    text = text:gsub("%s+CORP%s*%.?%s*$", "")
    text = text:gsub("%s+CO%s*%.?%s*$", "")

    -- 10. Trailing / leading commas
    text = text:gsub("%s*,%s*$", "")
    text = text:gsub("^%s*,%s*", "")

    -- 11. Normalise whitespace (already uppercase)
    text = trim(text:gsub("%s+", " "))

    if text == "" then
        return original_upper
    end
    return text
end

return MerchantCleaner
