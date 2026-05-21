-- Tax Statement Extraction Service
-- Extracts transactions from PDF, CSV, and image bank statements.
-- Supports HSBC, Barclays, Lloyds, Santander, and generic fallback layouts.

local cjson = require("cjson")

local Extraction = {}

-- ---------------------------------------------------------------------------
-- Date Parsing
-- ---------------------------------------------------------------------------

local MONTH_MAP = {
    jan = "01", feb = "02", mar = "03", apr = "04", may = "05", jun = "06",
    jul = "07", aug = "08", sep = "09", oct = "10", nov = "11", dec = "12",
    january = "01", february = "02", march = "03", april = "04",
    june = "06", july = "07", august = "08", september = "09",
    october = "10", november = "11", december = "12",
}

--- Parse a UK-format date string into YYYY-MM-DD
local function parse_date_uk(str)
    if not str then return nil end
    str = str:gsub("%s+", " "):match("^%s*(.-)%s*$")

    -- DD/MM/YYYY or DD-MM-YYYY
    local d, m, y = str:match("^(%d%d?)[/%-](%d%d?)[/%-](%d%d%d%d)$")
    if d then return string.format("%s-%02d-%02d", y, tonumber(m), tonumber(d)) end

    -- DD/MM/YY
    d, m, y = str:match("^(%d%d?)[/%-](%d%d?)[/%-](%d%d)$")
    if d then
        local year = tonumber(y) + 2000
        return string.format("%d-%02d-%02d", year, tonumber(m), tonumber(d))
    end

    -- DD Mon YYYY or DD Month YYYY
    d, m, y = str:match("^(%d%d?)%s+(%a+)%s+(%d%d%d%d)$")
    if d and MONTH_MAP[m:lower()] then
        return string.format("%s-%s-%02d", y, MONTH_MAP[m:lower()], tonumber(d))
    end

    -- YYYY-MM-DD (ISO)
    y, m, d = str:match("^(%d%d%d%d)[/%-](%d%d?)[/%-](%d%d?)$")
    if y then return string.format("%s-%02d-%02d", y, tonumber(m), tonumber(d)) end

    return nil
end

-- ---------------------------------------------------------------------------
-- Amount Parsing
-- ---------------------------------------------------------------------------

local function clean_amount(str)
    if not str then return nil end
    str = str:gsub("[£$€,]", ""):gsub("%s", "")
    -- Handle (negative) format
    local neg = str:match("^%((.+)%)$")
    if neg then return -tonumber(neg) end
    -- Handle DR/CR suffix
    local val = str:match("^([%d%.%-]+)")
    return tonumber(val)
end

-- Strip control characters and any bytes that are not valid UTF-8, returning a
-- string that is always safe to store in a UTF-8 Postgres column. This matters
-- because a multi-byte currency symbol (£ = 0xC2 0xA3) can leave an orphaned
-- lead byte behind once amounts are stripped from a line — and Postgres rejects
-- the whole INSERT with "invalid byte sequence for encoding UTF8". Valid
-- multi-byte sequences (e.g. accented merchant names) are preserved.
local function sanitize_text(s)
    if not s then return "" end
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        if c < 32 or c == 127 then
            out[#out + 1] = " "      -- control char -> separator
            i = i + 1
        elseif c < 0x80 then
            out[#out + 1] = string.char(c)
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF then
            local c2 = s:byte(i + 1)
            if c2 and c2 >= 0x80 and c2 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 1); i = i + 2
            else i = i + 1 end       -- drop invalid lead byte
        elseif c >= 0xE0 and c <= 0xEF then
            local c2, c3 = s:byte(i + 1), s:byte(i + 2)
            if c2 and c3 and c2 >= 0x80 and c2 <= 0xBF and c3 >= 0x80 and c3 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 2); i = i + 3
            else i = i + 1 end
        elseif c >= 0xF0 and c <= 0xF4 then
            local c2, c3, c4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if c2 and c3 and c4 and c2 >= 0x80 and c2 <= 0xBF
               and c3 >= 0x80 and c3 <= 0xBF and c4 >= 0x80 and c4 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 3); i = i + 4
            else i = i + 1 end
        else
            i = i + 1                -- stray continuation / illegal byte -> drop
        end
    end
    return (table.concat(out):gsub("%s+", " "):match("^%s*(.-)%s*$")) or ""
end

-- ---------------------------------------------------------------------------
-- CSV Extraction
-- ---------------------------------------------------------------------------

local function detect_delimiter(line)
    local tab_count = select(2, line:gsub("\t", ""))
    local comma_count = select(2, line:gsub(",", ""))
    local semi_count = select(2, line:gsub(";", ""))
    if tab_count > comma_count and tab_count > semi_count then return "\t" end
    if semi_count > comma_count then return ";" end
    return ","
end

local function split_csv_line(line, delimiter)
    local fields = {}
    local in_quote = false
    local current = ""
    delimiter = delimiter or ","

    for i = 1, #line do
        local c = line:sub(i, i)
        if c == '"' then
            in_quote = not in_quote
        elseif c == delimiter and not in_quote then
            table.insert(fields, current:match("^%s*(.-)%s*$") or "")
            current = ""
        else
            current = current .. c
        end
    end
    table.insert(fields, current:match("^%s*(.-)%s*$") or "")
    return fields
end

--- Detect which column index maps to date, description, amount, etc.
local function detect_columns(header_fields)
    local mapping = {}
    for i, field in ipairs(header_fields) do
        local f = field:lower():gsub("[^%w]", "")
        if f:match("date") or f:match("transactiondate") or f:match("postingdate") or f:match("valuedate") then
            mapping.date = mapping.date or i
        elseif f:match("description") or f:match("details") or f:match("narrative") or f:match("particulars") or f:match("memo") or f:match("reference") then
            mapping.description = mapping.description or i
        elseif f:match("debit") or f:match("moneyout") or f:match("paidout") or f:match("withdrawal") then
            mapping.debit = mapping.debit or i
        elseif f:match("credit") or f:match("moneyin") or f:match("paidin") or f:match("deposit") then
            mapping.credit = mapping.credit or i
        elseif f:match("amount") or f:match("value") then
            mapping.amount = mapping.amount or i
        elseif f:match("balance") then
            mapping.balance = mapping.balance or i
        elseif f:match("type") or f:match("transactiontype") then
            mapping.type = mapping.type or i
        end
    end
    return mapping
end

-- Bank-specific CSV layouts
local BANK_LAYOUTS = {
    hsbc = { date = 1, description = 3, debit = nil, credit = nil, amount = 4, balance = nil },
    barclays = { date = 1, description = 5, debit = nil, credit = nil, amount = 3, balance = nil },
    lloyds = { date = 1, description = 5, debit = 6, credit = 7, balance = 8 },
    santander = { date = 1, description = 2, debit = nil, credit = nil, amount = 3, balance = 4 },
}

local function detect_bank_from_csv(lines)
    local first_lines = table.concat(lines, "\n", 1, math.min(5, #lines)):lower()
    if first_lines:match("hsbc") then return "hsbc" end
    if first_lines:match("barclays") then return "barclays" end
    if first_lines:match("lloyds") or first_lines:match("halifax") then return "lloyds" end
    if first_lines:match("santander") then return "santander" end
    if first_lines:match("monzo") then return "monzo" end
    if first_lines:match("starling") then return "starling" end
    if first_lines:match("natwest") then return "natwest" end
    return nil
end

--- Extract transactions from CSV content
function Extraction.extract_from_csv(content, bank_hint)
    if not content or #content == 0 then return nil, "Empty CSV content" end

    local lines = {}
    for line in content:gmatch("[^\r\n]+") do
        if #line:match("^%s*(.-)%s*$") > 0 then
            table.insert(lines, line)
        end
    end

    if #lines < 2 then return nil, "CSV has fewer than 2 lines" end

    local delimiter = detect_delimiter(lines[1])
    local bank = bank_hint or detect_bank_from_csv(lines)

    -- Find header row (skip bank metadata rows)
    local header_row = 1
    for i = 1, math.min(10, #lines) do
        local fields = split_csv_line(lines[i], delimiter)
        local mapping = detect_columns(fields)
        if mapping.date and mapping.description then
            header_row = i
            break
        end
    end

    local header_fields = split_csv_line(lines[header_row], delimiter)
    local mapping = detect_columns(header_fields)

    -- Fall back to bank-specific layout
    if not mapping.date and bank and BANK_LAYOUTS[bank] then
        mapping = BANK_LAYOUTS[bank]
    end

    if not mapping.date then
        return nil, "Could not detect date column in CSV"
    end

    local transactions = {}
    for i = header_row + 1, #lines do
        local fields = split_csv_line(lines[i], delimiter)
        if #fields >= 2 then
            local date_str = fields[mapping.date]
            local description = fields[mapping.description] or ""
            local amount, txn_type, balance

            if mapping.debit and mapping.credit then
                local debit = clean_amount(fields[mapping.debit])
                local credit = clean_amount(fields[mapping.credit])
                if debit and debit ~= 0 then
                    amount = math.abs(debit)
                    txn_type = "DEBIT"
                elseif credit and credit ~= 0 then
                    amount = math.abs(credit)
                    txn_type = "CREDIT"
                end
            elseif mapping.amount then
                amount = clean_amount(fields[mapping.amount])
                if amount then
                    txn_type = amount < 0 and "DEBIT" or "CREDIT"
                    amount = math.abs(amount)
                end
            end

            if mapping.balance then
                balance = clean_amount(fields[mapping.balance])
            end

            local parsed_date = parse_date_uk(date_str)

            if parsed_date and amount then
                table.insert(transactions, {
                    date = parsed_date,
                    description = description:match("^%s*(.-)%s*$") or "",
                    amount = amount,
                    transaction_type = txn_type or "DEBIT",
                    balance = balance,
                    source_bank = bank,
                })
            end
        end
    end

    return {
        transactions = transactions,
        count = #transactions,
        bank = bank,
        format = "csv",
    }, nil
end

-- ---------------------------------------------------------------------------
-- PDF Extraction
-- ---------------------------------------------------------------------------

--- Extract transactions from a native PDF using pdftotext
function Extraction.extract_from_pdf(file_path)
    if not file_path then return nil, "file_path required" end

    -- Shell out to pdftotext
    local cmd = string.format("pdftotext -layout %q - 2>/dev/null", file_path)
    local handle = io.popen(cmd)
    if not handle then return nil, "Failed to run pdftotext" end

    local text = handle:read("*a")
    handle:close()

    if not text or #text < 50 then
        -- Likely a scanned PDF — fall back to image extraction
        return nil, "scanned_pdf"
    end

    return Extraction.extract_from_text(text)
end

--- Extract transactions from raw text (pdftotext output)
function Extraction.extract_from_text(text)
    if not text then return nil, "empty text" end

    local transactions = {}
    local bank = nil

    -- Detect bank from text
    local text_lower = text:lower()
    if text_lower:match("hsbc") then bank = "hsbc"
    elseif text_lower:match("barclays") then bank = "barclays"
    elseif text_lower:match("lloyds") or text_lower:match("halifax") then bank = "lloyds"
    elseif text_lower:match("santander") then bank = "santander"
    elseif text_lower:match("natwest") then bank = "natwest"
    elseif text_lower:match("monzo") then bank = "monzo"
    end

    -- pdftotext -layout keeps columns aligned, but £ is 2 bytes (0xC2 0xA3) in
    -- UTF-8 while header text is ASCII. Normalising £ to a single byte keeps
    -- byte offsets equal to visual columns, so we can classify each amount by
    -- the column it sits under (Debit / Credit / Balance).
    local function normalise(line) return (line:gsub("£", "#")) end

    -- First pass: locate a Debit/Credit/Balance column header, if present.
    local col_debit, col_credit, col_balance
    for line in text:gmatch("[^\r\n]+") do
        local low = normalise(line):lower()
        if low:find("balance") and (low:find("debit") or low:find("credit"))
           and (low:find("date") or low:find("description") or low:find("details")) then
            col_debit = low:find("debit")
            col_credit = low:find("credit")
            col_balance = low:find("balance")
            break
        end
    end
    local has_columns = col_balance ~= nil and (col_debit ~= nil or col_credit ~= nil)

    -- Second pass: parse date-prefixed transaction rows.
    local prev_balance = nil
    for line in text:gmatch("[^\r\n]+") do
        local norm = normalise(line)

        -- Match a leading date (DD/MM/YYYY or DD Mon YYYY) and capture where it
        -- ends so amount positions can be measured against the header columns.
        local date_end, date_str = select(2, norm:find("^%s*(%d%d?[/%-]%d%d?[/%-]%d%d%d?%d?)%s")),
                                    norm:match("^%s*(%d%d?[/%-]%d%d?[/%-]%d%d%d?%d?)%s")
        if not date_str then
            date_end, date_str = select(2, norm:find("^%s*(%d%d?%s+%a+%s+%d%d%d%d)%s")),
                                 norm:match("^%s*(%d%d?%s+%a+%s+%d%d%d%d)%s")
        end

        local parsed_date = date_str and parse_date_uk(date_str)
        if parsed_date and date_end then
            -- Collect amounts with their start column (relative to the normalised
            -- line, which is column-aligned with the header).
            local amts, idx = {}, date_end + 1
            while true do
                local s, e = norm:find("#?[%d,]+%.%d%d", idx)
                if not s then break end
                -- Drop the synthetic '#' (normalised £) before parsing the number.
                amts[#amts + 1] = { pos = s, val = clean_amount((norm:sub(s, e):gsub("#", ""))) }
                idx = e + 1
            end

            if #amts > 0 then
                -- Description is the text between the date and the first amount.
                local description = sanitize_text(norm:sub(date_end + 1, amts[1].pos - 1))

                -- The rightmost amount is the running balance; the first amount
                -- (when there are 2+) is the transaction value.
                local txn = amts[1]
                local balance = (#amts > 1) and amts[#amts].val or nil

                -- Classify type. Prefer column position; otherwise fall back to
                -- description keywords, then to balance direction.
                local txn_type
                if has_columns and col_debit and col_credit then
                    txn_type = (math.abs(txn.pos - col_debit) <= math.abs(txn.pos - col_credit))
                        and "DEBIT" or "CREDIT"
                else
                    txn_type = "DEBIT"
                    local dl = description:lower()
                    if dl:match("credit") or dl:match("received") or dl:match("salary")
                       or dl:match("transfer in") or dl:match("paid in")
                       or dl:match("bacs credit") or dl:match("faster payment received")
                       or dl:match("deposit") or dl:match("refund") then
                        txn_type = "CREDIT"
                    end
                    if balance and prev_balance then
                        if balance > prev_balance then txn_type = "CREDIT"
                        elseif balance < prev_balance then txn_type = "DEBIT" end
                    end
                end
                if balance then prev_balance = balance end

                table.insert(transactions, {
                    date = parsed_date,
                    description = description,
                    amount = math.abs(txn.val or 0),
                    transaction_type = txn_type,
                    balance = balance,
                    source_bank = bank,
                })
            end
        end
    end

    return {
        transactions = transactions,
        count = #transactions,
        bank = bank,
        format = "pdf",
    }, nil
end

-- ---------------------------------------------------------------------------
-- Image Extraction (Claude Vision)
-- ---------------------------------------------------------------------------

--- Extract transactions from an image file using Claude Vision
function Extraction.extract_from_image(file_path, opts)
    opts = opts or {}

    -- Read file and base64 encode
    local f = io.open(file_path, "rb")
    if not f then return nil, "Cannot open file: " .. file_path end
    local content = f:read("*a")
    f:close()

    local base64_ok, base64 = pcall(require, "base64")
    if not base64_ok then
        -- Fallback: use ngx.encode_base64
        base64 = { encode = ngx.encode_base64 }
    end
    local image_b64 = base64.encode(content)

    -- Detect MIME type
    local mime = "image/png"
    if file_path:match("%.jpg$") or file_path:match("%.jpeg$") then mime = "image/jpeg"
    elseif file_path:match("%.pdf$") then mime = "application/pdf"
    end

    local LLMClient = require("lib.llm-client")
    local result, err = LLMClient.extract_from_image({
        image_base64 = image_b64,
        mime_type = mime,
        trace_id = opts.trace_id,
    })

    if not result then return nil, err end

    -- Parse the structured response
    local data, parse_err = pcall(cjson.decode, result.content)
    if not data then
        -- Try to find JSON in the response
        local json_str = result.content:match("%[.-%]")
        if json_str then
            local ok2
            ok2, data = pcall(cjson.decode, json_str)
            if not ok2 then data = nil end
        end
    end

    if type(data) == "table" then
        -- Normalise the extracted data
        local transactions = {}
        local items = data.transactions or data
        if type(items) == "table" then
            for _, txn in ipairs(items) do
                table.insert(transactions, {
                    date = parse_date_uk(txn.date) or txn.date,
                    description = txn.description or "",
                    amount = tonumber(txn.amount) or 0,
                    transaction_type = txn.type or txn.transaction_type or "DEBIT",
                    balance = tonumber(txn.balance),
                    source_bank = data.bank_name,
                })
            end
        end

        return {
            transactions = transactions,
            count = #transactions,
            bank = data.bank_name,
            bank_details = {
                account_number = data.account_number,
                sort_code = data.sort_code,
                statement_period = data.statement_period,
                opening_balance = tonumber(data.opening_balance),
                closing_balance = tonumber(data.closing_balance),
            },
            format = "image",
        }, nil
    end

    return nil, "Failed to parse Vision response"
end

--- Convert scanned PDF pages to images, then extract via Vision
function Extraction.extract_scanned_pdf(file_path, opts)
    opts = opts or {}
    local tmp_dir = "/tmp/opsapi-pdf-" .. (ngx.time() or os.time())
    os.execute("mkdir -p " .. tmp_dir)

    -- Convert PDF to PNG pages
    local cmd = string.format("pdftoppm -png %q %s/page 2>/dev/null", file_path, tmp_dir)
    os.execute(cmd)

    -- Find generated page images
    local handle = io.popen("ls " .. tmp_dir .. "/page-*.png 2>/dev/null | sort")
    if not handle then
        os.execute("rm -rf " .. tmp_dir)
        return nil, "Failed to list PDF pages"
    end

    local all_transactions = {}
    local bank_details = nil

    for page_path in handle:lines() do
        local result, err = Extraction.extract_from_image(page_path, opts)
        if result then
            for _, txn in ipairs(result.transactions or {}) do
                table.insert(all_transactions, txn)
            end
            if not bank_details and result.bank_details then
                bank_details = result.bank_details
            end
        end
    end
    handle:close()

    -- Cleanup
    os.execute("rm -rf " .. tmp_dir)

    return {
        transactions = all_transactions,
        count = #all_transactions,
        bank = bank_details and bank_details.bank_name,
        bank_details = bank_details,
        format = "scanned_pdf",
    }, nil
end

-- ---------------------------------------------------------------------------
-- Bank Detail Detection
-- ---------------------------------------------------------------------------

--- Detect bank name, account number, sort code, and period from file content
function Extraction.detect_bank_details(content, file_type)
    if not content then return {} end

    local details = {}
    local text = content

    -- If PDF path, extract text first
    if file_type == "pdf" then
        local cmd = string.format("pdftotext -layout %q - 2>/dev/null | head -30", content)
        local handle = io.popen(cmd)
        if handle then
            text = handle:read("*a") or ""
            handle:close()
        end
    end

    local text_lower = text:lower()

    -- Bank name
    if text_lower:match("hsbc") then details.bank_name = "HSBC"
    elseif text_lower:match("barclays") then details.bank_name = "Barclays"
    elseif text_lower:match("lloyds") then details.bank_name = "Lloyds"
    elseif text_lower:match("santander") then details.bank_name = "Santander"
    elseif text_lower:match("natwest") then details.bank_name = "NatWest"
    elseif text_lower:match("nationwide") then details.bank_name = "Nationwide"
    elseif text_lower:match("monzo") then details.bank_name = "Monzo"
    elseif text_lower:match("starling") then details.bank_name = "Starling"
    elseif text_lower:match("revolut") then details.bank_name = "Revolut"
    end

    -- Sort code (XX-XX-XX)
    details.sort_code = text:match("(%d%d%-%d%d%-%d%d)")

    -- Account number (8 digits)
    details.account_number = text:match("account%s*n[ou]mber[:%s]*(%d%d%d%d%d%d%d%d)")
        or text:match("a/c[:%s]*(%d%d%d%d%d%d%d%d)")
        or text:match("(%d%d%d%d%d%d%d%d)")

    -- Statement period
    local period_start, period_end = text:match("(%d%d[/%-]%d%d[/%-]%d%d%d?%d?)%s*[%-–to]+%s*(%d%d[/%-]%d%d[/%-]%d%d%d?%d?)")
    if period_start then
        details.period_start = parse_date_uk(period_start)
        details.period_end = parse_date_uk(period_end)
    end

    -- Opening/closing balance
    local ob = text:match("[Oo]pening%s+[Bb]alance[:%s]*[£]?([%d,]+%.%d%d)")
    if ob then details.opening_balance = clean_amount(ob) end

    local cb = text:match("[Cc]losing%s+[Bb]alance[:%s]*[£]?([%d,]+%.%d%d)")
    if cb then details.closing_balance = clean_amount(cb) end

    return details
end

-- ---------------------------------------------------------------------------
-- Main Entry Point
-- ---------------------------------------------------------------------------

--- Extract transactions from a file based on its type
-- @param file_path string Path to the file
-- @param file_type string "csv", "pdf", "image"
-- @param opts table { bank_hint, content (for CSV), trace_id }
-- @return table { transactions, count, bank, format } | nil, error
function Extraction.extract(file_path, file_type, opts)
    opts = opts or {}

    if file_type == "csv" then
        local content = opts.content
        if not content then
            local f = io.open(file_path, "r")
            if not f then return nil, "Cannot open CSV file" end
            content = f:read("*a")
            f:close()
        end
        return Extraction.extract_from_csv(content, opts.bank_hint)

    elseif file_type == "pdf" then
        local result, err = Extraction.extract_from_pdf(file_path)
        if err == "scanned_pdf" then
            return Extraction.extract_scanned_pdf(file_path, opts)
        end
        return result, err

    elseif file_type == "image" or file_type == "png" or file_type == "jpg" or file_type == "jpeg" then
        return Extraction.extract_from_image(file_path, opts)

    else
        return nil, "Unsupported file type: " .. tostring(file_type)
    end
end

return Extraction
