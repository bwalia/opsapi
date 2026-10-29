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

    -- Run pdftotext to a temp FILE and read it back, rather than reading an io.popen
    -- pipe. In an nginx worker the popen child-reaping races with nginx's own SIGCHLD
    -- handler and INTERMITTENTLY returns empty output, which wrongly trips the
    -- "scanned_pdf" vision fallback — and the vision model then misreads the running
    -- Balance column as the transaction amount. os.execute + file read doesn't depend
    -- on the child's exit status, so the text is read reliably.
    -- Run pdftotext via ngx.pipe — OpenResty's native, non-blocking way to spawn a
    -- subprocess from a worker. io.popen / os.execute race with nginx's SIGCHLD handling
    -- and intermittently return EMPTY output, which wrongly trips the "scanned_pdf"
    -- vision fallback — and the vision model then misreads the running Balance column
    -- as the transaction amount (every amount becomes a ~£14k balance, all DEBIT). This
    -- was the real cause of the garbage estimates. Falls back to os.execute + file read
    -- outside the OpenResty runtime (e.g. `lapis exec` / CLI).
    local text
    local ok_pipe, pipe = pcall(require, "ngx.pipe")
    if ok_pipe and pipe then
        local proc = pipe.spawn({ "pdftotext", "-layout", file_path, "-" })
        if proc then
            proc:set_timeouts(nil, 15000, 15000, 15000)
            text = proc:stdout_read_all()
            proc:wait()
        end
    end
    if not text or #text < 50 then
        local out_path = file_path .. ".txt"
        os.execute(string.format("pdftotext -layout %q %q 2>/dev/null", file_path, out_path))
        local fh = io.open(out_path, "r")
        if fh then text = fh:read("*a"); fh:close() end
        os.remove(out_path)
    end

    if not text or #text < 50 then
        -- Genuinely no extractable text (scanned/image PDF) — fall back to vision.
        return nil, "scanned_pdf"
    end

    return Extraction.extract_from_text(text)
end

-- Detect the character offsets of the Debit / Credit / Balance amount columns
-- from a statement's header row. pdftotext -layout keeps columns aligned, so an
-- amount's position on the line tells us whether it's money out, money in, or the
-- running balance — far more reliable than guessing from the description.
local function detect_amount_columns(lines)
    for _, line in ipairs(lines) do
        local low = line:lower()
        local debit = low:find("money out", 1, true) or low:find("paid out", 1, true)
            or low:find("withdrawal", 1, true) or low:find("debit", 1, true)
        local credit = low:find("money in", 1, true) or low:find("paid in", 1, true)
            or low:find("deposit", 1, true) or low:find("credit", 1, true)
        if debit and credit then
            return { debit = debit, credit = credit, balance = low:find("balance", 1, true) }
        end
    end
    return nil
end

-- Assign an amount to a column by where its RIGHT edge falls. Each column owns
-- the span from its header's start up to the next header's start. Matching the
-- amount's start to the nearest header start broke on right-aligned layouts: a
-- right-aligned Money-out value sits nearer the Money-in header, and a Money-in
-- value nearer Balance, so every row came out with its direction flipped.
-- Numbers ending before the first column (in the description) are ignored, as
-- are numbers far past the last column.
local function column_for_amount(first, last, cols)
    local order = {}
    for name, anchor in pairs(cols) do order[#order + 1] = { name = name, at = anchor } end
    table.sort(order, function(a, b) return a.at < b.at end)
    for i, col in ipairs(order) do
        local nxt = order[i + 1]
        local limit = nxt and (nxt.at - 1)
            or (col.at + (i > 1 and (col.at - order[i - 1].at) or 20))
        if last >= col.at and last <= limit then return col.name end
    end
    return nil
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

    -- Collect lines (preserve column spacing produced by pdftotext -layout). Normalise
    -- multi-byte currency symbols to ONE byte first (£ is 2 bytes, € is 3) so that a
    -- byte offset equals a visual column. Without this, every £ before an amount shifts
    -- its byte position right of its visual column; the drift accumulates along the row
    -- and across pages, so the Debit/Credit/Balance anchors (taken from the £-free
    -- header) stop lining up and the running Balance gets misread as the transaction
    -- amount on later rows (the "£14,340.67 Gym" garbage).
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        -- Same for the em/en dash many statements print in the empty Debit/Credit cell.
        line = line:gsub("\194\163", " "):gsub("\226\130\172", " ")
            :gsub("\226\128\148", "-"):gsub("\226\128\147", "-")
        lines[#lines + 1] = line
    end

    -- Column anchors, re-detected per page. A multi-page statement repeats the header,
    -- and later pages often sit at DIFFERENT column offsets than page 1. Using a single
    -- global anchor set makes the running Balance on later pages fall nearest the Debit
    -- anchor and get misread as a ~£14k expense. Seed with the first header; each
    -- repeated header below updates the anchors for the rows that follow it.
    local cols = detect_amount_columns(lines)

    -- Parse line by line, looking for date-prefixed transaction rows
    for _, line in ipairs(lines) do
        local hdr_cols = detect_amount_columns({ line })
        if hdr_cols then cols = hdr_cols end
        -- Match a leading date (DD/MM/YYYY or DD Mon YYYY) and note where it ends.
        local date_str, date_end
        local _, e, cap = line:find("^%s*(%d%d?[/%-]%d%d?[/%-]%d%d%d?%d?)%s")
        if cap then date_str, date_end = cap, e end
        if not date_str then
            _, e, cap = line:find("^%s*(%d%d?%s+%a+%s+%d%d%d%d)%s")
            if cap then date_str, date_end = cap, e end
        end

        local parsed_date = date_str and parse_date_uk(date_str) or nil
        if parsed_date then
            -- Find every amount on the line together with its byte offset, so we
            -- can map it back to a column. The optional currency byte is skipped;
            -- a few bytes of drift from multi-byte £/€ is absorbed by the tolerance.
            local amts = {}
            local init = 1
            while true do
                local as, ae, acap = line:find("([%d,]+%.%d%d)", init)
                if not as then break end
                local val = clean_amount(acap)
                if val then amts[#amts + 1] = { val = val, pos = as, stop = ae } end
                init = ae + 1
            end

            if #amts > 0 then
                -- Description = the text between the date and the first amount.
                -- Strip multi-byte currency symbols so it stays valid UTF-8.
                local description = line:sub((date_end or 0) + 1, amts[1].pos - 1)
                description = description:gsub("\194\163", ""):gsub("\226\130\172", "")
                description = description:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
                -- Drop the empty-cell placeholder ("—", normalised to "-") that sits
                -- between the description and an amount in the next column.
                description = description:gsub("[%s%-]+$", "")

                -- Classify amounts into debit / credit / balance by column position.
                local debit_v, credit_v, balance_v
                if cols then
                    for _, a in ipairs(amts) do
                        local which = column_for_amount(a.pos, a.stop, cols)
                        if which == "debit" then debit_v = a.val
                        elseif which == "credit" then credit_v = a.val
                        elseif which == "balance" then balance_v = a.val end
                    end
                end

                local amount, txn_type
                if credit_v and credit_v ~= 0 then
                    amount, txn_type = math.abs(credit_v), "CREDIT"
                elseif debit_v and debit_v ~= 0 then
                    amount, txn_type = math.abs(debit_v), "DEBIT"
                end

                -- Fallback for layouts without separate Debit/Credit columns:
                -- first amount is the value, last is the running balance; infer
                -- direction from description keywords.
                if not amount then
                    amount = math.abs(amts[1].val or 0)
                    if #amts > 1 then balance_v = balance_v or amts[#amts].val end
                    local dl = description:lower()
                    if dl:match("credit") or dl:match("received") or dl:match("refund")
                        or dl:match("transfer in") or dl:match("paid in")
                        or dl:match("bacs credit") or dl:match("faster payment received")
                        or dl:match("salary") or dl:match("wages") or dl:match("interest")
                        or dl:match("dividend") then
                        txn_type = "CREDIT"
                    else
                        txn_type = "DEBIT"
                    end
                end

                if amount and amount > 0 then
                    table.insert(transactions, {
                        date = parsed_date,
                        description = description,
                        amount = amount,
                        transaction_type = txn_type,
                        balance = balance_v,
                        source_bank = bank,
                    })
                end
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
