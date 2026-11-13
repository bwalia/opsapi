--[[
    Bank detail detection — read the bank name, sort code and account number
    from a statement so the user doesn't have to type them.

    Port of the deterministic parts of diy-tax-return-uk's
    backend/app/services/pdf_processor.py (CSV header block, per-row account
    columns, column signatures, SORT_CODE_BANK_PREFIXES), extended for the
    text that `pdftotext -layout` produces from PDF statements.

    Order of trust (first signal wins for each field):
      bank_name       labelled "Bank name:" > known bank in the statement HEADER
                      > a header title line ending in BANK / BUILDING SOCIETY
                      > known bank in a legal footer ("... Bank plc. Registered ...")
                      > IBAN bank code > sort-code prefix > LLM fallback
      sort_code       labelled "Sort code" > IBAN > "NN-NN-NN 12345678" pair
      account_number  labelled "Account number" > IBAN > sort-code pair

    The header is everything ABOVE the first transaction row / table header.
    Transaction lines are never searched for a bank name: "LLOYDS BANK BTL
    MORTGAGE" on a Northbridge statement is a payment, not the issuer.

    Pure Lua (no ngx / db) so it is unit-testable with plain luajit; the LLM
    fallback is the only part that needs the OpenResty runtime and goes through
    lib/llm-client's public chat() — no provider code here.
]]

local BankDetect = {}

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------

-- Known UK banks, most specific first (on the same line the earlier entry
-- wins: "Lloyds TSB" -> Lloyds, "Royal Bank of Scotland" -> RBS, not BoS).
-- Patterns are matched against lowercased text with word frontiers.
BankDetect.KNOWN_BANKS = {
    { name = "First Direct", patterns = { "first direct", "firstdirect" } },
    { name = "RBS", patterns = { "royal bank of scotland" } },
    { name = "Lloyds", patterns = { "lloyds" } },
    { name = "HSBC", patterns = { "hsbc" } },
    { name = "Barclays", patterns = { "barclays" } },
    { name = "Halifax", patterns = { "halifax" } },
    { name = "Bank of Scotland", patterns = { "bank of scotland" } },
    { name = "NatWest", patterns = { "natwest", "national westminster" } },
    { name = "Santander", patterns = { "santander" } },
    { name = "Nationwide", patterns = { "nationwide" } },
    { name = "Monzo", patterns = { "monzo" } },
    { name = "Starling", patterns = { "starling bank", "starling" } },
    { name = "Revolut", patterns = { "revolut" } },
    { name = "Metro Bank", patterns = { "metro bank" } },
    { name = "Co-operative Bank", patterns = { "co%-operative bank", "co%-op bank", "cooperative bank" } },
    { name = "Virgin Money", patterns = { "virgin money" } },
    { name = "Clydesdale Bank", patterns = { "clydesdale bank" } },
    { name = "Yorkshire Bank", patterns = { "yorkshire bank" } },
    { name = "TSB", patterns = { "tsb" } },
    { name = "Coutts", patterns = { "coutts" } },
    { name = "Ulster Bank", patterns = { "ulster bank" } },
    { name = "Danske Bank", patterns = { "danske bank" } },
    { name = "Bank of Ireland", patterns = { "bank of ireland" } },
    { name = "AIB", patterns = { "allied irish" } },
    { name = "Triodos", patterns = { "triodos" } },
    { name = "Handelsbanken", patterns = { "handelsbanken" } },
    { name = "Cater Allen", patterns = { "cater allen" } },
    { name = "Tide", patterns = { "tide platform", "tide business" } },
    { name = "Wise", patterns = { "wise payments" } },
    { name = "Chase", patterns = { "chase uk", "j%.p%. morgan europe" } },
    { name = "Atom Bank", patterns = { "atom bank" } },
    { name = "Kroo", patterns = { "kroo" } },
}

-- First two digits of a sort code -> issuing bank. Kept identical to
-- diy-tax-return-uk SORT_CODE_BANK_PREFIXES (pdf_processor.py) so both
-- products agree. A *secondary* signal: only used when nothing better named
-- the bank.
BankDetect.SORT_CODE_PREFIXES = {
    ["40"] = "HSBC", ["02"] = "First Direct",
    ["20"] = "Barclays", ["23"] = "Barclays",
    ["30"] = "Lloyds", ["77"] = "Lloyds",
    ["11"] = "Halifax", ["12"] = "Bank of Scotland",
    ["60"] = "NatWest", ["16"] = "RBS", ["80"] = "RBS", ["18"] = "Coutts",
    ["09"] = "Santander", ["72"] = "Santander",
    ["07"] = "Nationwide",
    ["08"] = "Co-operative Bank",
    ["05"] = "Virgin Money", ["82"] = "Virgin Money",
    ["04"] = "Monzo",
}

-- Whole sort codes that a two-digit prefix gets wrong (Starling sits in
-- NatWest's 60 range; Revolut in Monzo's 04 range).
BankDetect.SORT_CODE_EXACT = {
    ["608371"] = "Starling",
    ["040004"] = "Monzo",
    ["040075"] = "Revolut",
}

-- IBAN bank code (characters 5-8 of a GB IBAN) -> bank.
BankDetect.IBAN_BANK_CODES = {
    NWBK = "NatWest", BARC = "Barclays", LOYD = "Lloyds", HBUK = "HSBC", MIDL = "HSBC",
    ABBY = "Santander", NAIA = "Nationwide", MONZ = "Monzo", SRLG = "Starling",
    REVO = "Revolut", HLFX = "Halifax", BOFS = "Bank of Scotland", RBOS = "RBS",
    TSBS = "TSB", CPBK = "Co-operative Bank", MYMB = "Metro Bank", CLYD = "Clydesdale Bank",
    NRNB = "Virgin Money", COUT = "Coutts", ULSB = "Ulster Bank",
}

local MONTHS = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8,
    sep = 9, sept = 9, oct = 10, nov = 11, dec = 12,
    january = 1, february = 2, march = 3, april = 4, june = 6, july = 7,
    august = 8, september = 9, october = 10, november = 11, december = 12,
}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function digits_only(s)
    return (tostring(s or ""):gsub("%D", ""))
end

-- One-byte-per-glyph text: £/€ dropped, NBSP -> space, dashes -> "-".
local function normalise_text(text)
    text = tostring(text or "")
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end -- UTF-8 BOM
    text = text:gsub("\194\163", ""):gsub("\226\130\172", "")
        :gsub("\194\160", " ")
        :gsub("\226\128\147", "-"):gsub("\226\128\148", "-"):gsub("\226\128\146", "-")
        :gsub("\r\n", "\n"):gsub("\r", "\n")
    return text
end

local function split_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    return lines
end

-- Word-frontier search for a (lowercase, Lua-pattern) needle in lowercase text.
local function has_word(lower, pat)
    return lower:find("%f[%w]" .. pat .. "%f[%W]") ~= nil
end

local function title_case(s)
    s = s:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
    -- Keep short all-caps tokens (PLC, UK, TSB) upper.
    s = s:gsub("%f[%w](Plc)%f[%W]", "plc"):gsub("%f[%w](Uk)%f[%W]", "UK")
    return s
end

local function days_in_month(y, m)
    local d = ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
    if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) then d = 29 end
    return d
end

local function iso(y, m, d)
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not (y and m and d) or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
    if y < 100 then y = y + 2000 end
    return string.format("%04d-%02d-%02d", y, m, d)
end

-- "01/09/2026", "1-9-26", "1 Sep 2026", "01 September 2026" -> YYYY-MM-DD
local function parse_date(s)
    s = trim(s)
    local d, m, y = s:match("^(%d%d?)[/%-%.](%d%d?)[/%-%.](%d%d%d?%d?)$")
    if d then return iso(y, m, d) end
    d, m, y = s:match("^(%d%d?)%a*%s+(%a+)%s+(%d%d%d%d)$")
    if d and MONTHS[m:lower()] then return iso(y, MONTHS[m:lower()], d) end
    return nil
end
BankDetect.parse_date = parse_date

local function amount(s)
    if not s then return nil end
    return tonumber((s:gsub(",", "")))
end

-- ---------------------------------------------------------------------------
-- Normalisation / masking (public — used by the route for logs and matching)
-- ---------------------------------------------------------------------------

--- "200000", "20 00 00", "20-00-00" -> "20-00-00"; anything else -> nil.
function BankDetect.normalize_sort_code(s)
    if s == nil then return nil end
    local raw = trim(s):gsub("^'", "")
    if raw:match("[^%d%s%-%.]") then return nil end
    local d = digits_only(raw)
    if #d ~= 6 then return nil end
    return d:sub(1, 2) .. "-" .. d:sub(3, 4) .. "-" .. d:sub(5, 6)
end

--- A UK account number is 8 digits (some legacy/building-society ones 6-10).
function BankDetect.normalize_account_number(s)
    if s == nil then return nil end
    local raw = trim(s):gsub("^'", "")
    if raw:match("[^%d%s%-]") then return nil end
    local d = digits_only(raw)
    if #d < 6 or #d > 10 then return nil end
    return d
end

--- Bank name for a sort code (exact override first, then the 2-digit prefix).
function BankDetect.bank_from_sort_code(sort_code)
    local d = digits_only(sort_code)
    if #d < 2 then return nil end
    if #d == 6 and BankDetect.SORT_CODE_EXACT[d] then return BankDetect.SORT_CODE_EXACT[d] end
    return BankDetect.SORT_CODE_PREFIXES[d:sub(1, 2)]
end

--- "12345678" -> "****5678"
function BankDetect.mask_account_number(an)
    if not an or an == "" then return nil end
    local d = tostring(an)
    if #d <= 4 then return string.rep("*", #d) end
    return string.rep("*", #d - 4) .. d:sub(-4)
end

--- "20-00-00" -> "20-**-**"
function BankDetect.mask_sort_code(sc)
    if not sc or sc == "" then return nil end
    local d = digits_only(sc)
    if #d ~= 6 then return "**-**-**" end
    return d:sub(1, 2) .. "-**-**"
end

--- Copy of a detection result that is safe to log (no full numbers).
function BankDetect.masked(details)
    if type(details) ~= "table" then return details end
    local out = {}
    for k, v in pairs(details) do out[k] = v end
    out.account_number = BankDetect.mask_account_number(details.account_number)
    out.sort_code = BankDetect.mask_sort_code(details.sort_code)
    return out
end

--- One-line, masked summary for ngx.log.
function BankDetect.log_line(details)
    local m = BankDetect.masked(details or {}) or {}
    return string.format("bank=%s sort_code=%s account=%s source=%s confidence=%s",
        tostring(m.bank_name), tostring(m.sort_code), tostring(m.account_number),
        tostring(m.source), tostring(m.confidence))
end

-- ---------------------------------------------------------------------------
-- Field finders (text)
-- ---------------------------------------------------------------------------

-- A transaction row starts with a date; a table header names Date + another column.
local function is_transaction_row(line)
    local l = trim(line)
    -- A date AND an amount: "01/09/2026 to 30/09/2026" (a period line) is not a row.
    if not l:find("%d%.%d%d") then return false end
    if l:match("^%d%d?[/%-%.]%d%d?[/%-%.]%d%d") then return true end
    if l:match("^%d%d?%s+%a%a%a%a*%s+%d%d%d%d%s") or l:match("^%d%d?%s+%a%a%a%s+%d%d?%s") then
        local mon = l:match("^%d%d?%s+(%a+)")
        if mon and MONTHS[mon:lower()] then return true end
    end
    return false
end

local function is_table_header(line)
    local low = line:lower()
    if not low:find("date", 1, true) then return false end
    return low:find("description", 1, true) or low:find("details", 1, true)
        or low:find("balance", 1, true) or low:find("paid out", 1, true)
        or low:find("money out", 1, true) or low:find("payments", 1, true)
        or low:find("narrative", 1, true) or low:find("transaction", 1, true)
end

--- Lines above the first transaction row / table header (max 60).
function BankDetect.header_lines(lines)
    local out = {}
    for i, line in ipairs(lines) do
        if i > 60 or is_transaction_row(line) or is_table_header(line) then break end
        out[#out + 1] = line
    end
    return out
end

local SORT_LABELS = { "sort%s*code", "sortcode", "s/c" }
local ACCOUNT_LABELS = {
    "account%s*number", "account%s*no%.?", "acc%s*no%.?", "acct%s*no%.?", "a/c%s*no%.?",
    "a/c%s*number", "a/c", "account",
}

-- Find "<label> ... NN-NN-NN" on one line.
local function labelled_sort_code(lower)
    for _, label in ipairs(SORT_LABELS) do
        local init = 1
        while true do
            local _, e = lower:find(label, init)
            if not e then break end
            local rest = lower:sub(e + 1):match("^[^\n]*") or ""
            local a, b, c = rest:match("^[^%d\n]-(%d%d)[%s%-%.]?(%d%d)[%s%-%.]?(%d%d)%f[%D]")
            if a then return a .. "-" .. b .. "-" .. c end
            init = e + 1
        end
    end
    return nil
end

-- Find "<label> ... 12345678" on one line. The value must be a 6-10 digit run
-- (a single space between digit groups allowed): "TEST-ACCOUNT-7310" is not
-- an account number, so it is rejected rather than guessed at.
local function labelled_account_number(lower)
    for _, label in ipairs(ACCOUNT_LABELS) do
        local init = 1
        while true do
            local s, e = lower:find(label, init)
            if not s then break end
            -- Don't let "account" re-read what "sort code" or "account name" labels.
            local rest = lower:sub(e + 1):match("^[^\n]*") or ""
            local skip = rest:match("^%s*name") or rest:match("^%s*holder") or rest:match("^%s*type")
                or rest:match("^%s*summary") or rest:match("^s%f[%W]")
            if not skip then
                local pre, run = rest:match("^([^%d\n]-)(%d[%d ]*%d)")
                -- Only short separators between the label and the number (": ", " No. ").
                if run and #pre <= 12 and not pre:find("sort", 1, true) then
                    local d = run:gsub(" ", "")
                    local spaces = select(2, run:gsub(" ", ""))
                    if #d >= 6 and #d <= 10 and spaces <= 1 then return d end
                end
            end
            init = e + 1
        end
    end
    return nil
end

-- GB IBAN -> sort code, account number, bank (from the BIC-style bank code).
function BankDetect.parse_iban(text)
    local up = tostring(text or ""):upper()
    for cand in up:gmatch("GB%d%d[%u%d ]+") do
        local compact = cand:gsub(" ", "")
        if #compact >= 22 then
            compact = compact:sub(1, 22)
            local code, sc, an = compact:match("^GB%d%d(%u%u%u%u)(%d%d%d%d%d%d)(%d%d%d%d%d%d%d%d)$")
            if code then
                return {
                    sort_code = BankDetect.normalize_sort_code(sc),
                    account_number = an,
                    bank_name = BankDetect.IBAN_BANK_CODES[code],
                }
            end
        end
    end
    return nil
end

-- "20-00-00 12345678", "200000-12345678" (NatWest CSV), "20-00-00  12345678"
local function sort_code_pair(text)
    local a, b, c, an = text:match("%f[%d](%d%d)%-(%d%d)%-(%d%d)%s+(%d%d%d%d%d%d%d%d)%f[%D]")
    if a then return a .. "-" .. b .. "-" .. c, an end
    local sc, an2 = text:match("%f[%d](%d%d%d%d%d%d)%-(%d%d%d%d%d%d%d%d)%f[%D]")
    if sc then return BankDetect.normalize_sort_code(sc), an2 end
    return nil
end

-- Known bank on a single (lowercase) line; earliest-listed entry wins.
local function known_bank_in(lower)
    for _, bank in ipairs(BankDetect.KNOWN_BANKS) do
        for _, pat in ipairs(bank.patterns) do
            if has_word(lower, pat) then
                -- "Bank of Scotland" inside "Royal Bank of Scotland" is RBS (handled
                -- earlier in the list), and "Lloyds TSB" is Lloyds (also earlier).
                return bank.name
            end
        end
    end
    return nil
end

-- A header title such as "NORTHBRIDGE DEMO BANK", "Leeds Building Society".
local function generic_title(line)
    local t = trim(line)
    if #t < 6 or #t > 60 or t:find("%d") or t:find(":", 1, true) then return nil end
    local low = t:lower()
    for _, bad in ipairs({ "statement", "your ", "account", "sort code", "page ", "not a ", "test document" }) do
        if low:find(bad, 1, true) then return nil end
    end
    local ok = low:match("%f[%w]bank$") or low:match("%f[%w]bank plc$") or low:match("%f[%w]bank uk$")
        or low:match("%f[%w]bank limited$") or low:match("%f[%w]bank ltd$")
        or low:match("building society$") or low:match("^bank of %a")
    if not ok then return nil end
    -- Must be at least two words (a lone "Bank" is not a name).
    if not t:find("%s") then return nil end
    return title_case(t)
end

-- Footer legalese naming the issuer: "Monzo Bank Limited is authorised by ...",
-- "Barclays Bank UK PLC. Registered in England". A transaction line such as
-- "LLOYDS BANK BTL MORTGAGE" has none of these words, so it is not picked up.
local LEGAL_WORDS = { "registered", "authorised", "authorized", "regulated", "financial conduct",
    "prudential regulation", "fscs", "company no", "registered office" }

local function legal_footer_bank(lines)
    for _, line in ipairs(lines) do
        if not is_transaction_row(line) then
            local low = line:lower()
            local legal = false
            for _, w in ipairs(LEGAL_WORDS) do
                if low:find(w, 1, true) then legal = true break end
            end
            if legal then
                local name = known_bank_in(low)
                if name then return name end
            end
        end
    end
    return nil
end

-- Statement period: "01/09/2026 to 30/09/2026", "1 September 2026 - 30 September 2026",
-- "Statement period: September 2026".
local function find_period(text)
    local lower = text:lower()
    local DATE = "(%d%d?[/%-%.]%d%d?[/%-%.]%d%d%d?%d?)"
    local s, e = lower:match(DATE .. "%s*[%-]%s*" .. DATE)
    if not s then s, e = lower:match(DATE .. "%s+to%s+" .. DATE) end
    if s then
        local ps, pe = parse_date(s), parse_date(e)
        if ps and pe and ps <= pe then return ps, pe end
    end
    local LONG = "(%d%d?%a*%s+%a+%s+%d%d%d%d)"
    s, e = lower:match(LONG .. "%s*[%-]%s*" .. LONG)
    if not s then s, e = lower:match(LONG .. "%s+to%s+" .. LONG) end
    if s then
        local ps, pe = parse_date(s), parse_date(e)
        if ps and pe and ps <= pe then return ps, pe end
    end
    -- "01 September to 30 September 2026"
    local d1, m1, d2, m2, y4 = lower:match("(%d%d?)%a*%s+(%a+)%s+to%s+(%d%d?)%a*%s+(%a+)%s+(%d%d%d%d)")
    if d1 and MONTHS[m1] and MONTHS[m2] then
        local yy = tonumber(y4)
        local sy = MONTHS[m1] > MONTHS[m2] and yy - 1 or yy
        return iso(sy, MONTHS[m1], d1), iso(yy, MONTHS[m2], d2)
    end
    -- "period: September 2026" / "statement for September 2026"
    local mon, yr = lower:match("period[^\n%d]-(%a+)%s+(%d%d%d%d)")
    if mon and MONTHS[mon] then
        local m, y = MONTHS[mon], tonumber(yr)
        return iso(y, m, 1), iso(y, m, days_in_month(y, m))
    end
    return nil, nil
end

local function find_balance(text, word)
    local lower = text:lower()
    local v = lower:match(word .. "%s+balance[^\n%d%-]-(%-?[%d,]+%.%d%d)")
    return amount(v)
end

-- ---------------------------------------------------------------------------
-- Detection from statement text (PDF via pdftotext, or any plain text)
-- ---------------------------------------------------------------------------

local function empty_result()
    return {
        detected = false,
        bank_name = nil,
        sort_code = nil,
        account_number = nil,
        account_type = nil,
        confidence = 0,
        source = nil,
        period_start = nil,
        period_end = nil,
        opening_balance = nil,
        closing_balance = nil,
    }
end

local function finish(r)
    r.sort_code = BankDetect.normalize_sort_code(r.sort_code)
    r.account_number = BankDetect.normalize_account_number(r.account_number)
    if r.bank_name then r.bank_name = trim(r.bank_name):sub(1, 100) end
    if r.bank_name == "" then r.bank_name = nil end
    r.detected = (r.bank_name ~= nil or r.sort_code ~= nil or r.account_number ~= nil)
    r.account_number_masked = BankDetect.mask_account_number(r.account_number)
    if not r.detected then r.confidence = 0 end
    return r
end

--- Detect bank details from statement text.
-- @return table { detected, bank_name, sort_code, account_number, confidence, source, ... }
function BankDetect.from_text(text)
    local r = empty_result()
    text = normalise_text(text)
    if text == "" then return finish(r) end
    local lines = split_lines(text)
    local header = BankDetect.header_lines(lines)
    local header_text = table.concat(header, "\n")
    local header_lower = header_text:lower()
    local lower = text:lower()

    -- Numbers: labelled in the header, then labelled anywhere (page 1 sometimes
    -- puts the account box beside the table), then IBAN, then a "NN-NN-NN 12345678" pair.
    r.sort_code = labelled_sort_code(header_lower) or labelled_sort_code(lower)
    r.account_number = labelled_account_number(header_lower) or labelled_account_number(lower)
    local iban = BankDetect.parse_iban(text)
    if iban then
        r.sort_code = r.sort_code or iban.sort_code
        r.account_number = r.account_number or iban.account_number
    end
    if not (r.sort_code and r.account_number) then
        local sc, an = sort_code_pair(header_text)
        if sc then
            r.sort_code = r.sort_code or sc
            r.account_number = r.account_number or an
        end
    end

    -- Bank name.
    local labelled = header_text:match("[Bb][Aa][Nn][Kk]%s*[Nn][Aa][Mm][Ee]%s*[:%-]%s*([^\n]-)%s%s")
        or header_text:match("[Bb][Aa][Nn][Kk]%s*[Nn][Aa][Mm][Ee]%s*[:%-]%s*([^\n]+)")
    if labelled and trim(labelled) ~= "" then
        r.bank_name = known_bank_in(labelled:lower()) or trim(labelled)
        r.source, r.confidence = "header_label", 0.95
    end
    if not r.bank_name then
        for _, line in ipairs(header) do
            local name = known_bank_in(line:lower())
            if name then
                r.bank_name, r.source, r.confidence = name, "header", 0.95
                break
            end
        end
    end
    if not r.bank_name then
        for _, line in ipairs(header) do
            local name = generic_title(line)
            if name then
                r.bank_name, r.source, r.confidence = name, "header_title", 0.85
                break
            end
        end
    end
    if not r.bank_name then
        local name = legal_footer_bank(lines)
        if name then r.bank_name, r.source, r.confidence = name, "legal_footer", 0.8 end
    end
    if not r.bank_name and iban and iban.bank_name then
        r.bank_name, r.source, r.confidence = iban.bank_name, "iban", 0.8
    end
    if not r.bank_name and r.sort_code then
        local name = BankDetect.bank_from_sort_code(r.sort_code)
        if name then r.bank_name, r.source, r.confidence = name, "sort_code", 0.6 end
    end
    if not r.bank_name and (r.sort_code or r.account_number) then
        r.source, r.confidence = "header", 0.7
    end

    -- Account type (only when the header says so).
    if header_lower:find("business%s+[%a%s]-account") or header_lower:find("business banking", 1, true) then
        r.account_type = "business"
    elseif header_lower:find("savings%s+account") or header_lower:find("%f[%a]saver%f[%A]") then
        r.account_type = "savings"
    elseif header_lower:find("current%s+account") then
        r.account_type = "current"
    end

    r.period_start, r.period_end = find_period(header_text)
    if not r.period_start then r.period_start, r.period_end = find_period(text) end
    r.opening_balance = find_balance(header_text, "opening") or find_balance(header_text, "previous")
        or find_balance(header_text, "start")
    r.closing_balance = find_balance(header_text, "closing") or find_balance(header_text, "new")
        or find_balance(header_text, "end")
    return finish(r)
end

-- ---------------------------------------------------------------------------
-- Detection from CSV
-- ---------------------------------------------------------------------------

local function detect_delimiter(line)
    local tabs = select(2, line:gsub("\t", ""))
    local commas = select(2, line:gsub(",", ""))
    local semis = select(2, line:gsub(";", ""))
    if tabs > commas and tabs > semis then return "\t" end
    if semis > commas then return ";" end
    return ","
end

local function split_csv(line, delim)
    local fields, cur, inq = {}, {}, false
    local i, n = 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c == '"' then
            if inq and line:sub(i + 1, i + 1) == '"' then
                cur[#cur + 1] = '"'
                i = i + 1
            else
                inq = not inq
            end
        elseif c == delim and not inq then
            fields[#fields + 1] = trim(table.concat(cur))
            cur = {}
        else
            cur[#cur + 1] = c
        end
        i = i + 1
    end
    fields[#fields + 1] = trim(table.concat(cur))
    return fields
end

-- Key-value rows at the top of a CSV ("Sort Code,20-00-00"). Same keys as
-- diy-tax-return-uk _CSV_HEADER_KEY_MAP.
local CSV_KEY_MAP = {
    ["bank name"] = "bank_name", ["bank"] = "bank_name",
    ["account number"] = "account_number", ["account no"] = "account_number",
    ["acc no"] = "account_number", ["a/c no"] = "account_number", ["a/c number"] = "account_number",
    ["account"] = "_account",
    ["sort code"] = "sort_code", ["sortcode"] = "sort_code",
    ["account type"] = "account_type",
    ["statement period"] = "_period", ["period"] = "_period", ["period covered"] = "_period",
    ["iban"] = "_iban",
}

local function csv_header_block(rows)
    local found = {}
    for i = 1, math.min(15, #rows) do
        local cells = {}
        for _, c in ipairs(rows[i]) do if c ~= "" then cells[#cells + 1] = c end end
        -- "Account Number: 12345678" in a single cell.
        if #cells == 1 and cells[1]:find(":", 1, true) then
            local k, v = cells[1]:match("^([^:]+):%s*(.+)$")
            if k then cells = { k, v } end
        end
        if next(found) and #cells >= 4 then break end -- transactions header reached
        if #cells >= 2 then
            local key = trim(cells[1]:lower():gsub(":$", ""))
            local field = CSV_KEY_MAP[key]
            local value = cells[2]
            if field == "_period" then
                local ps, pe = find_period(value)
                if ps then found.period_start, found.period_end = ps, pe end
            elseif field == "_iban" then
                local iban = BankDetect.parse_iban(value)
                if iban then
                    found.sort_code = found.sort_code or iban.sort_code
                    found.account_number = found.account_number or iban.account_number
                    found.iban_bank = iban.bank_name
                end
            elseif field == "_account" then
                local sc, an = sort_code_pair(value)
                if sc then
                    found.sort_code = found.sort_code or sc
                    found.account_number = found.account_number or an
                elseif BankDetect.normalize_account_number(value) then
                    found.account_number = found.account_number or value
                end
            elseif field then
                found[field] = value
            end
        end
    end
    return found
end

-- Per-row columns: "Sort Code" / "Account Number" / "Bank Name" / "Account"
-- (Lloyds, NatWest and Barclays exports carry the account on every row).
local function csv_account_columns(rows)
    for h = 1, math.min(15, #rows) do
        local header = rows[h]
        local idx = {}
        local filled = 0
        for _, cell in ipairs(header) do if cell ~= "" then filled = filled + 1 end end
        for i, cell in ipairs(header) do
            local k = cell:lower():gsub("^%s+", ""):gsub("%s+$", "")
            if k == "sort code" or k == "sortcode" then idx.sort_code = i
            elseif k == "account number" or k == "account no" or k == "acc no" or k == "a/c no" then
                idx.account_number = i
            elseif k == "bank name" or k == "bank" then idx.bank_name = i
            elseif k == "account" then idx.account = i end
        end
        if next(idx) and filled >= 3 then
            for r = h + 1, math.min(h + 20, #rows) do
                local row = rows[r]
                local out = {}
                if idx.sort_code and row[idx.sort_code] then
                    out.sort_code = BankDetect.normalize_sort_code(row[idx.sort_code])
                end
                if idx.account_number and row[idx.account_number] then
                    local v = (row[idx.account_number]:gsub("^'", ""))
                    local sc, an = sort_code_pair(v)
                    if sc then
                        out.sort_code = out.sort_code or sc
                        out.account_number = an
                    else
                        out.account_number = BankDetect.normalize_account_number(v)
                    end
                end
                if idx.account and row[idx.account] and row[idx.account] ~= "" then
                    local sc, an = sort_code_pair(row[idx.account])
                    if sc then
                        out.sort_code = out.sort_code or sc
                        out.account_number = out.account_number or an
                    end
                end
                if idx.bank_name and row[idx.bank_name] and row[idx.bank_name] ~= "" then
                    out.bank_name = row[idx.bank_name]
                end
                if next(out) then return out, h end
            end
        end
    end
    return {}, nil
end

-- Index of the transactions header row (a "Date" column plus 2+ more), or nil.
local function csv_table_header(rows)
    for i = 1, math.min(20, #rows) do
        local filled, has_date = 0, false
        for _, c in ipairs(rows[i]) do
            if c ~= "" then filled = filled + 1 end
            if c:lower():find("date", 1, true) then has_date = true end
        end
        if has_date and filled >= 3 then return i end
    end
    return nil
end

-- Distinctive column sets (diy-tax-return-uk bank_signatures, the specific ones).
local CSV_SIGNATURES = {
    { "Monzo", { "emoji", "category", "currency" } },
    { "Monzo", { "transaction id", "money out", "money in", "notes and #tags" } },
    { "Starling", { "counter party" } },
    { "Revolut", { "product", "completed date", "currency" } },
    { "Lloyds", { "debit amount", "credit amount", "transaction type" } },
    { "Barclays", { "subcategory", "memo" } },
    { "Tide", { "transaction id", "tide" } },
}

local function csv_signature(rows)
    local parts = {}
    for i = 1, math.min(10, #rows) do
        local cells = {}
        for _, c in ipairs(rows[i]) do cells[#cells + 1] = c:lower() end
        parts[#parts + 1] = table.concat(cells, ",")
    end
    local blob = table.concat(parts, "\n")
    for _, sig in ipairs(CSV_SIGNATURES) do
        local all = true
        for _, p in ipairs(sig[2]) do
            if not blob:find(p, 1, true) then all = false break end
        end
        if all then return sig[1] end
    end
    return nil
end

--- Detect bank details from CSV content.
function BankDetect.from_csv(content)
    local r = empty_result()
    local text = normalise_text(content)
    local lines = {}
    for _, l in ipairs(split_lines(text)) do
        if trim(l) ~= "" then lines[#lines + 1] = l end
    end
    if #lines == 0 then return finish(r) end

    -- Pick the delimiter from the busiest of the first few lines (metadata
    -- rows above the header have fewer separators than the header).
    local delim, best = ",", -1
    for i = 1, math.min(10, #lines) do
        local d = detect_delimiter(lines[i])
        local n = select(2, lines[i]:gsub(d == "\t" and "\t" or d, ""))
        if n > best then delim, best = d, n end
    end
    local rows = {}
    for i, l in ipairs(lines) do rows[i] = split_csv(l, delim) end

    -- Strategy 1: key-value header block.
    local block = csv_header_block(rows)
    if block.bank_name or block.sort_code or block.account_number then
        r.bank_name = block.bank_name and (known_bank_in(block.bank_name:lower()) or block.bank_name)
        r.sort_code, r.account_number = block.sort_code, block.account_number
        r.account_type = block.account_type and block.account_type:lower() or nil
        r.period_start, r.period_end = block.period_start, block.period_end
        r.source, r.confidence = "csv_header", 0.95
        if not r.bank_name and block.iban_bank then r.bank_name = block.iban_bank end
    end

    -- Strategy 2: per-row account columns.
    local cols, header_at = csv_account_columns(rows)
    if next(cols) then
        r.sort_code = r.sort_code or cols.sort_code
        r.account_number = r.account_number or cols.account_number
        if not r.bank_name and cols.bank_name then
            r.bank_name = known_bank_in(cols.bank_name:lower()) or cols.bank_name
        end
        if not r.source then r.source, r.confidence = "csv_columns", 0.85 end
    end

    -- Strategy 3: a bank named in the rows ABOVE the transactions header
    -- (title lines like "Barclays Bank UK PLC - Statement"). Transaction rows
    -- are not searched: a payee can be another bank.
    if not r.bank_name then
        local stop = header_at or csv_table_header(rows) or 1
        for i = 1, math.min(stop - 1, 15) do
            local name = known_bank_in(table.concat(rows[i], " "):lower())
            if name then
                r.bank_name = name
                r.source = r.source or "csv_title"
                r.confidence = math.max(r.confidence, 0.9)
                break
            end
        end
    end

    -- Strategy 4: distinctive column signature.
    if not r.bank_name then
        local sig = csv_signature(rows)
        if sig then
            r.bank_name = sig
            if not r.source then r.source = "csv_signature" end
            r.confidence = math.max(r.confidence, 0.75)
        end
    end

    -- Strategy 5: sort-code prefix.
    if not r.bank_name and r.sort_code then
        local name = BankDetect.bank_from_sort_code(r.sort_code)
        if name then
            r.bank_name = name
            if not r.source then r.source = "sort_code" end
            r.confidence = r.confidence > 0 and r.confidence or 0.6
        end
    end

    -- Period from the transactions when the header doesn't state it (rows
    -- below the table header only: a sort code like 09-01-28 is not a date).
    if not r.period_start then
        local first, last
        local from = (csv_table_header(rows) or 0) + 1
        for i = from, #rows do
            local row = rows[i]
            for _, cell in ipairs(row) do
                local d = parse_date(cell:match("^(%S+)") or "")
                if d then
                    if not first or d < first then first = d end
                    if not last or d > last then last = d end
                    break
                end
            end
        end
        r.period_start, r.period_end = first, last
    end
    return finish(r)
end

-- ---------------------------------------------------------------------------
-- LLM fallback (OpenResty runtime only)
-- ---------------------------------------------------------------------------

local LLM_SYSTEM = [[You read UK bank statements. Identify the ISSUING bank of THIS statement and its account details.
Return ONLY a JSON object: {"bank_name": string|null, "sort_code": "NN-NN-NN"|null, "account_number": string|null}
Rules:
- The issuing bank is in the statement title, letterhead, header block or legal footer.
- Transaction descriptions often name OTHER banks (mortgage lenders, transfers, card payments). Never use those.
- sort_code and account_number must be copied exactly from the text. If absent, use null. Never guess.]]

--- Parse and validate an LLM reply. Numbers are only accepted when they
-- actually occur in the source text (no hallucinated account numbers).
function BankDetect.parse_llm_reply(content, source_text)
    if type(content) ~= "string" or content == "" then return nil end
    local ok_json, cjson = pcall(require, "cjson")
    if not ok_json then return nil end
    local ok, data = pcall(cjson.decode, content)
    if not ok or type(data) ~= "table" then
        local obj = content:match("%b{}")
        if not obj then return nil end
        ok, data = pcall(cjson.decode, obj)
        if not ok or type(data) ~= "table" then return nil end
    end
    local src_digits = digits_only(source_text or "")
    local function str(v) return type(v) == "string" and trim(v) or nil end
    local out = {}
    local sc = BankDetect.normalize_sort_code(str(data.sort_code))
    if sc and src_digits:find(digits_only(sc), 1, true) then out.sort_code = sc end
    local an = BankDetect.normalize_account_number(str(data.account_number))
    if an and src_digits:find(an, 1, true) then out.account_number = an end
    local bank = str(data.bank_name)
    if bank and bank ~= "" and bank:lower() ~= "null" and bank:lower() ~= "unknown" then
        -- The name must be in the text the model saw, or be what the sort code says.
        local src_lower = tostring(source_text or ""):lower()
        local known = known_bank_in(bank:lower())
        local seen = known and known_bank_in(src_lower) == known
        if not seen then
            local word = bank:lower():match("%a%a%a+")
            seen = word ~= nil and has_word(src_lower, word)
        end
        if seen or (known and known == BankDetect.bank_from_sort_code(out.sort_code)) then
            out.bank_name = known or (bank == bank:upper() and title_case(bank) or bank):sub(1, 100)
        end
    end
    if not next(out) then return nil end
    return out
end

--- Ask the platform LLM (lib/llm-client public chat()) for what the rules missed.
-- @return table|nil fields, string|nil error
function BankDetect.llm_fallback(snippet, opts)
    opts = opts or {}
    local ok, LLMClient = pcall(require, "lib.llm-client")
    if not ok or type(LLMClient) ~= "table" or type(LLMClient.chat) ~= "function" then
        return nil, "llm unavailable"
    end
    local res, err = LLMClient.chat({
        system = LLM_SYSTEM,
        messages = { { role = "user", content = "Statement text:\n" .. snippet:sub(1, 3000) } },
        json = true,
        temperature = 0,
        max_tokens = 300,
        feature = "tax_bank_detect",
        trace_id = opts.trace_id,
        trace_name = "bank_detect",
    })
    if not res then return nil, err end
    return BankDetect.parse_llm_reply(res.content, snippet), nil
end

--- Head of the text the LLM sees: the header plus a little of what follows.
--- What the LLM sees: the statement header only (the lines above the first
-- transaction, plus legal footer lines). Transaction lines are left out so the
-- model can't "find" a payee bank. Empty when there is no header to read.
local function llm_snippet(text, is_csv)
    local lines = split_lines(normalise_text(text))
    local out = {}
    if is_csv then
        local delim = detect_delimiter(lines[1] or "")
        local rows = {}
        for i = 1, math.min(25, #lines) do rows[i] = split_csv(lines[i], delim) end
        local hdr = csv_table_header(rows) or 1
        for i = 1, hdr - 1 do
            if trim(lines[i]) ~= "" then out[#out + 1] = lines[i] end
        end
        if #out == 0 then return "" end
        out[#out + 1] = lines[hdr]
        return table.concat(out, "\n")
    end
    for _, l in ipairs(BankDetect.header_lines(lines)) do
        if trim(l) ~= "" then out[#out + 1] = l end
    end
    for _, l in ipairs(lines) do
        local low = l:lower()
        if not is_transaction_row(l) and (low:find("registered", 1, true) or low:find("authorised", 1, true)) then
            out[#out + 1] = l
        end
    end
    return table.concat(out, "\n")
end

--- Full detection.
-- @param content string statement text (pdftotext output) or CSV content
-- @param kind "text"|"pdf"|"csv"
-- @param opts { llm = bool (default true), llm_fn = function(snippet) for tests, trace_id }
function BankDetect.detect(content, kind, opts)
    opts = opts or {}
    local is_csv = kind == "csv"
    local r = is_csv and BankDetect.from_csv(content) or BankDetect.from_text(content)
    if opts.llm == false or not content or content == "" then return r end
    -- Ask the model only for what the rules could not read: the bank, or (PDF
    -- text) numbers when the header has an account label they didn't parse.
    -- A CSV without numbers (Monzo, Starling exports) simply has none to find.
    local need = not r.bank_name
    if not need and not is_csv and not (r.sort_code or r.account_number) then
        local head = table.concat(BankDetect.header_lines(split_lines(normalise_text(content))), "\n"):lower()
        need = head:find("sort", 1, true) ~= nil or head:find("account n", 1, true) ~= nil
    end
    if not need then return r end

    local snippet = llm_snippet(content, is_csv)
    if not snippet:find("%a%a%a") then return r end -- no header: nothing the model could read
    local fn = opts.llm_fn or function(s) return BankDetect.llm_fallback(s, opts) end
    local ok, got, err = pcall(fn, snippet)
    if not ok then
        r.llm_error = tostring(got)
    elseif not got then
        r.llm_error = err
    else
        -- Fill only what the rules missed; numbers re-validated against the text.
        local filled = false
        if not r.bank_name and got.bank_name then r.bank_name = got.bank_name; filled = true end
        if not r.sort_code and got.sort_code then r.sort_code = got.sort_code; filled = true end
        if not r.account_number and got.account_number then r.account_number = got.account_number; filled = true end
        if filled then
            r.source = r.source and (r.source .. "+llm") or "llm"
            r.confidence = r.confidence > 0 and math.min(r.confidence, 0.7) or 0.6
        end
    end
    return finish(r)
end

return BankDetect
