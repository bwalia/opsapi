-- AI Service: Ollama Integration for Bookkeeping Assistance
-- Provides AI-powered expense categorisation, VAT treatment suggestions,
-- natural language queries, anomaly detection, and bank statement parsing.
-- Gracefully degrades when Ollama is unavailable.

local cjson = require("cjson")

local AIService = {}

-- ============================================================================
-- Configuration
-- ============================================================================

local OLLAMA_URL = os.getenv("OLLAMA_URL") or "http://ollama:11434"
local OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or "mistral"
local REQUEST_TIMEOUT = 30000 -- 30 seconds

-- ============================================================================
-- Internal Helpers
-- ============================================================================

--- Create an HTTP client with timeout configured.
-- @return httpc, nil | nil, error string
local function create_http_client()
    local ok, http = pcall(require, "resty.http")
    if not ok then
        return nil, "resty.http not available"
    end
    local httpc = http.new()
    httpc:set_timeout(REQUEST_TIMEOUT)
    return httpc, nil
end

--- Safely decode a JSON string.
-- @param str string
-- @return table|nil, string|nil
local function safe_json_decode(str)
    if not str or str == "" then
        return nil, "empty response"
    end
    local ok, result = pcall(cjson.decode, str)
    if not ok then
        return nil, "JSON decode error: " .. tostring(result)
    end
    return result, nil
end

--- Build the list of expense categories from a chart of accounts table.
-- @param chart_of_accounts table Array of account rows
-- @return string Formatted list
local function format_expense_categories(chart_of_accounts)
    if not chart_of_accounts or #chart_of_accounts == 0 then
        return "No categories available"
    end
    local lines = {}
    for _, acct in ipairs(chart_of_accounts) do
        if acct.account_type == "expense" then
            table.insert(lines, string.format("- %s (%s)", acct.name, acct.code))
        end
    end
    if #lines == 0 then
        return "No expense categories available"
    end
    return table.concat(lines, "\n")
end

-- ============================================================================
-- Core Query Function
-- ============================================================================

--- Send a prompt to the Ollama /api/generate endpoint and return the response.
-- @param prompt string The user prompt
-- @param options table|nil Optional settings: { json = bool, temperature = number }
-- @return string|nil response text, string|nil error
function AIService.query(prompt, options)
    options = options or {}

    local httpc, http_err = create_http_client()
    if not httpc then
        return nil, "AI service unavailable: " .. tostring(http_err)
    end

    local body = {
        model = OLLAMA_MODEL,
        prompt = prompt,
        stream = false,
    }
    if options.json then
        body.format = "json"
    end
    if options.temperature then
        body.options = { temperature = options.temperature }
    end

    local ok, res_or_err = pcall(function()
        return httpc:request_uri(OLLAMA_URL .. "/api/generate", {
            method = "POST",
            body = cjson.encode(body),
            headers = {
                ["Content-Type"] = "application/json",
            },
        })
    end)

    if not ok then
        return nil, "AI service unavailable: " .. tostring(res_or_err)
    end

    local res = res_or_err
    if not res then
        return nil, "AI service unavailable: no response"
    end

    if res.status ~= 200 then
        return nil, string.format("Ollama returned HTTP %d: %s", res.status, tostring(res.body))
    end

    local decoded, decode_err = safe_json_decode(res.body)
    if not decoded then
        return nil, "Failed to parse Ollama response: " .. tostring(decode_err)
    end

    return decoded.response, nil
end

-- ============================================================================
-- Expense Categorisation
-- ============================================================================

--- Auto-categorise an expense using AI.
-- @param description string Transaction description
-- @param amount number Transaction amount
-- @param chart_of_accounts table Array of account rows from accounting_accounts
-- @return table|nil { category, account_code, confidence, reasoning }, string|nil error
function AIService.categorizeExpense(description, amount, chart_of_accounts)
    if not description or description == "" then
        return nil, "description is required"
    end

    local categories_text = format_expense_categories(chart_of_accounts)

    local prompt = string.format([[You are a UK bookkeeping assistant. Categorize this transaction.

Transaction: "%s" Amount: £%.2f

Available categories:
%s

Respond with JSON only:
{"category": "category_name", "account_code": "6XXX", "confidence": 0.95, "reasoning": "brief explanation"}]], description, amount or 0, categories_text)

    local response, err = AIService.query(prompt, { json = true, temperature = 0.1 })
    if not response then
        return nil, err
    end

    local parsed, parse_err = safe_json_decode(response)
    if not parsed then
        return nil, "Failed to parse categorisation response: " .. tostring(parse_err)
    end

    return {
        category = parsed.category or "Miscellaneous",
        account_code = parsed.account_code or "6400",
        confidence = tonumber(parsed.confidence) or 0,
        reasoning = parsed.reasoning or "",
    }, nil
end

-- ============================================================================
-- VAT Treatment Suggestion
-- ============================================================================

--- Suggest VAT treatment for a transaction.
-- @param description string Transaction description
-- @param amount number Transaction amount
-- @param category string Expense category
-- @return table|nil { vat_rate, vat_amount, is_reclaimable, reasoning }, string|nil error
function AIService.suggestVatTreatment(description, amount, category)
    if not description or description == "" then
        return nil, "description is required"
    end

    amount = amount or 0
    category = category or "unknown"

    local prompt = string.format([[You are a UK VAT specialist. Determine VAT treatment for this expense.

Transaction: "%s" Amount: £%.2f Category: %s

UK VAT rules:
- Standard rate: 20%% (most goods/services)
- Reduced rate: 5%% (energy, children's car seats)
- Zero rate: 0%% (food, books, children's clothing)
- Exempt: Insurance, education, health
- Not reclaimable: Entertainment, personal use

Respond with JSON only:
{"vat_rate": 20, "vat_amount": 0.00, "is_reclaimable": true, "reasoning": "brief explanation"}]], description, amount, category)

    local response, err = AIService.query(prompt, { json = true, temperature = 0.1 })
    if not response then
        return nil, err
    end

    local parsed, parse_err = safe_json_decode(response)
    if not parsed then
        return nil, "Failed to parse VAT response: " .. tostring(parse_err)
    end

    local vat_rate = tonumber(parsed.vat_rate) or 20
    local vat_amount = tonumber(parsed.vat_amount)
    if not vat_amount then
        -- Calculate from amount and rate
        vat_amount = math.floor((amount * vat_rate / (100 + vat_rate)) * 100 + 0.5) / 100
    end

    return {
        vat_rate = vat_rate,
        vat_amount = vat_amount,
        is_reclaimable = parsed.is_reclaimable ~= false,
        reasoning = parsed.reasoning or "",
    }, nil
end

-- ============================================================================
-- Natural Language Query
-- ============================================================================

--- Convert a natural language question to a structured query interpretation.
-- Does NOT execute arbitrary SQL - only returns a structured interpretation.
-- @param question string User's question in plain English
-- @param namespace_id number The namespace to scope to
-- @return table|nil { query_type, interpretation, sql_hint }, string|nil error
function AIService.naturalLanguageQuery(question, namespace_id)
    if not question or question == "" then
        return nil, "question is required"
    end

    local prompt = string.format([[You are a UK bookkeeping assistant. Interpret this question about accounting data.

Question: "%s"
Namespace ID: %s

Available tables and key columns:
- accounting_accounts: id, namespace_id, code, name, account_type, current_balance
- accounting_journal_entries: id, namespace_id, entry_number, entry_date, description, status, total_amount
- accounting_journal_lines: id, journal_entry_id, account_id, debit_amount, credit_amount
- accounting_bank_transactions: id, namespace_id, transaction_date, description, amount, category, is_reconciled
- accounting_expenses: id, namespace_id, expense_date, description, amount, category, vat_rate, vat_amount, status

Respond with JSON only:
{"query_type": "trial_balance|profit_loss|balance_sheet|expense_summary|transaction_search|vat_return|custom", "interpretation": "human-readable interpretation of what the user wants", "sql_hint": "a safe read-only SQL query hint (SELECT only, with namespace_id filter)", "parameters": {"start_date": "YYYY-MM-DD", "end_date": "YYYY-MM-DD"}}]], question, tostring(namespace_id or "unknown"))

    local response, err = AIService.query(prompt, { json = true, temperature = 0.2 })
    if not response then
        return nil, err
    end

    local parsed, parse_err = safe_json_decode(response)
    if not parsed then
        return nil, "Failed to parse NL query response: " .. tostring(parse_err)
    end

    return {
        query_type = parsed.query_type or "custom",
        interpretation = parsed.interpretation or question,
        sql_hint = parsed.sql_hint or "",
        parameters = parsed.parameters or {},
    }, nil
end

-- ============================================================================
-- Anomaly Detection
-- ============================================================================

--- Detect unusual transactions from a list of recent transactions.
-- @param transactions table Array of transaction rows
-- @return table|nil { anomalies: [{ transaction_id, reason, severity }] }, string|nil error
function AIService.detectAnomalies(transactions)
    if not transactions or #transactions == 0 then
        return { anomalies = {} }, nil
    end

    -- Build a summary of transactions for the prompt
    local txn_lines = {}
    for i, txn in ipairs(transactions) do
        if i > 50 then break end -- Limit to keep prompt manageable
        table.insert(txn_lines, string.format(
            "ID:%s Date:%s Desc:\"%s\" Amount:£%.2f Category:%s",
            tostring(txn.id or txn.uuid or i),
            tostring(txn.transaction_date or txn.expense_date or "unknown"),
            tostring(txn.description or ""),
            tonumber(txn.amount) or 0,
            tostring(txn.category or "uncategorised")
        ))
    end

    local prompt = string.format([[You are a UK bookkeeping fraud and anomaly detection specialist. Review these recent transactions and identify any that look unusual, suspicious, or potentially erroneous.

Transactions:
%s

Look for:
- Unusually large amounts compared to others
- Duplicate transactions (same amount, date, description)
- Transactions at unusual times or dates
- Categories that don't match the description
- Round-number amounts that may indicate estimates

Respond with JSON only:
{"anomalies": [{"transaction_id": "ID", "reason": "why it is unusual", "severity": "low|medium|high"}]}]], table.concat(txn_lines, "\n"))

    local response, err = AIService.query(prompt, { json = true, temperature = 0.2 })
    if not response then
        return nil, err
    end

    local parsed, parse_err = safe_json_decode(response)
    if not parsed then
        return nil, "Failed to parse anomaly response: " .. tostring(parse_err)
    end

    return {
        anomalies = parsed.anomalies or {},
    }, nil
end

-- ============================================================================
-- Bank Statement Parsing
-- ============================================================================

--- Parse a CSV bank statement into structured transactions.
-- Attempts common UK bank formats: Barclays, HSBC, Lloyds, NatWest, Monzo, Starling.
-- @param csv_content string Raw CSV content
-- @return table|nil Array of parsed transactions, string|nil error
function AIService.parseBankStatement(csv_content)
    if not csv_content or csv_content == "" then
        return nil, "csv_content is required"
    end

    -- First, try rule-based parsing for known formats
    local parsed = AIService._tryKnownFormats(csv_content)
    if parsed and #parsed > 0 then
        return parsed, nil
    end

    -- Fall back to AI-assisted parsing for unknown formats
    -- Only send the header + first few rows to keep the prompt small
    local preview_lines = {}
    local count = 0
    for line in csv_content:gmatch("[^\r\n]+") do
        count = count + 1
        if count <= 10 then
            table.insert(preview_lines, line)
        else
            break
        end
    end

    local prompt = string.format([[You are a UK bank statement CSV parser. Analyse this CSV preview and identify the column mapping.

CSV Preview (first %d lines):
%s

Common UK bank CSV formats:
- Barclays: Date, Description, Amount (negative=debit), Balance
- HSBC: Date, Description, Amount
- Lloyds: Transaction Date, Transaction Type, Sort Code, Account Number, Transaction Description, Debit Amount, Credit Amount, Balance
- NatWest: Date, Type, Description, Value, Balance, Account Name, Account Number
- Monzo: Transaction ID, Date, Time, Type, Name, Emoji, Category, Amount, Currency, Local amount, Local currency, Notes and #tags, Address, Receipt, Description, Category split, Money Out, Money In
- Starling: Date, Counter Party, Reference, Type, Amount (GBP), Balance (GBP)

Respond with JSON only:
{"bank_format": "barclays|hsbc|lloyds|natwest|monzo|starling|unknown", "columns": {"date": 0, "description": 1, "amount": 2, "debit": null, "credit": null, "balance": 3}, "date_format": "DD/MM/YYYY", "has_header": true}]], #preview_lines, table.concat(preview_lines, "\n"))

    local response, err = AIService.query(prompt, { json = true, temperature = 0.1 })
    if not response then
        return nil, err
    end

    local mapping, map_err = safe_json_decode(response)
    if not mapping then
        return nil, "Failed to parse column mapping: " .. tostring(map_err)
    end

    -- Apply the AI-detected mapping
    return AIService._parseWithMapping(csv_content, mapping), nil
end

--- Try parsing with known UK bank formats (rule-based, no AI needed).
-- @param csv_content string
-- @return table|nil Array of transactions, or nil if format not recognised
function AIService._tryKnownFormats(csv_content)
    local lines = {}
    for line in csv_content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    if #lines < 2 then
        return nil
    end

    local header = lines[1]:lower()

    -- Simple CSV field splitter (handles quoted fields)
    local function split_csv(line)
        local fields = {}
        local field = ""
        local in_quotes = false
        for i = 1, #line do
            local c = line:sub(i, i)
            if c == '"' then
                in_quotes = not in_quotes
            elseif c == ',' and not in_quotes then
                table.insert(fields, field)
                field = ""
            else
                field = field .. c
            end
        end
        table.insert(fields, field)
        -- Trim whitespace
        for k, v in ipairs(fields) do
            fields[k] = v:match("^%s*(.-)%s*$")
        end
        return fields
    end

    -- Parse a UK date string (DD/MM/YYYY or YYYY-MM-DD) to YYYY-MM-DD
    local function parse_date(s)
        if not s then return nil end
        s = s:match("^%s*(.-)%s*$")
        -- DD/MM/YYYY
        local d, m, y = s:match("^(%d%d?)/(%d%d?)/(%d%d%d%d)$")
        if d then
            return string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
        end
        -- YYYY-MM-DD
        if s:match("^%d%d%d%d%-%d%d%-%d%d$") then
            return s
        end
        return s -- Return as-is if unrecognised
    end

    local transactions = {}

    -- Detect Monzo: has "money out" and "money in" columns
    if header:find("money out") and header:find("money in") then
        for i = 2, #lines do
            local fields = split_csv(lines[i])
            if #fields >= 17 then
                local money_out = tonumber(fields[17]) or 0
                local money_in = tonumber(fields[18]) or 0
                local amount = money_in - money_out
                table.insert(transactions, {
                    date = parse_date(fields[2]),
                    description = fields[5] ~= "" and fields[5] or fields[16],
                    amount = amount,
                    balance = nil,
                    category = fields[7],
                    source = "monzo",
                })
            end
        end
        if #transactions > 0 then return transactions end
    end

    -- Detect Starling: "counter party" in header
    if header:find("counter party") then
        for i = 2, #lines do
            local fields = split_csv(lines[i])
            if #fields >= 5 then
                table.insert(transactions, {
                    date = parse_date(fields[1]),
                    description = fields[2],
                    amount = tonumber(fields[5]) or 0,
                    balance = tonumber(fields[6]),
                    category = fields[4],
                    source = "starling",
                })
            end
        end
        if #transactions > 0 then return transactions end
    end

    -- Detect Lloyds: "transaction type" and "debit amount" in header
    if header:find("transaction type") and header:find("debit amount") then
        for i = 2, #lines do
            local fields = split_csv(lines[i])
            if #fields >= 8 then
                local debit = tonumber(fields[6]) or 0
                local credit = tonumber(fields[7]) or 0
                table.insert(transactions, {
                    date = parse_date(fields[1]),
                    description = fields[5],
                    amount = credit - debit,
                    balance = tonumber(fields[8]),
                    category = nil,
                    source = "lloyds",
                })
            end
        end
        if #transactions > 0 then return transactions end
    end

    -- Detect NatWest: header starts with "date" and contains "value" and "balance"
    if header:find("^date") and header:find("value") and header:find("balance") then
        for i = 2, #lines do
            local fields = split_csv(lines[i])
            if #fields >= 5 then
                table.insert(transactions, {
                    date = parse_date(fields[1]),
                    description = fields[3],
                    amount = tonumber(fields[4]) or 0,
                    balance = tonumber(fields[5]),
                    category = nil,
                    source = "natwest",
                })
            end
        end
        if #transactions > 0 then return transactions end
    end

    -- Generic fallback: Date, Description, Amount[, Balance]
    -- Covers Barclays, HSBC, and other simple formats
    if header:find("date") and header:find("amount") then
        local header_fields = split_csv(header)
        local date_idx, desc_idx, amount_idx, balance_idx
        for k, v in ipairs(header_fields) do
            local lv = v:lower()
            if lv:find("date") and not date_idx then date_idx = k end
            if (lv:find("desc") or lv:find("narrative") or lv:find("memo")) and not desc_idx then desc_idx = k end
            if lv == "amount" and not amount_idx then amount_idx = k end
            if lv:find("balance") and not balance_idx then balance_idx = k end
        end

        if date_idx and amount_idx then
            desc_idx = desc_idx or (date_idx + 1)
            for i = 2, #lines do
                local fields = split_csv(lines[i])
                if #fields >= amount_idx then
                    table.insert(transactions, {
                        date = parse_date(fields[date_idx]),
                        description = fields[desc_idx] or "",
                        amount = tonumber(fields[amount_idx]) or 0,
                        balance = balance_idx and tonumber(fields[balance_idx]),
                        category = nil,
                        source = "auto-detected",
                    })
                end
            end
            if #transactions > 0 then return transactions end
        end
    end

    return nil
end

--- Parse CSV content using an AI-detected column mapping.
-- @param csv_content string
-- @param mapping table { columns: { date, description, amount, debit, credit, balance }, has_header, date_format }
-- @return table Array of parsed transactions
function AIService._parseWithMapping(csv_content, mapping)
    local transactions = {}
    local cols = mapping.columns or {}

    -- Zero-indexed columns from AI -> 1-indexed Lua
    local date_col = (cols.date or 0) + 1
    local desc_col = (cols.description or 1) + 1
    local amount_col = cols.amount and (cols.amount + 1)
    local debit_col = cols.debit and (cols.debit + 1)
    local credit_col = cols.credit and (cols.credit + 1)
    local balance_col = cols.balance and (cols.balance + 1)

    local line_num = 0
    for line in csv_content:gmatch("[^\r\n]+") do
        line_num = line_num + 1
        if line_num == 1 and mapping.has_header then
            -- Skip header
        else
            local fields = {}
            local field = ""
            local in_quotes = false
            for i = 1, #line do
                local c = line:sub(i, i)
                if c == '"' then
                    in_quotes = not in_quotes
                elseif c == ',' and not in_quotes then
                    table.insert(fields, field:match("^%s*(.-)%s*$"))
                    field = ""
                else
                    field = field .. c
                end
            end
            table.insert(fields, field:match("^%s*(.-)%s*$"))

            if #fields >= 2 then
                local amount = 0
                if amount_col and fields[amount_col] then
                    amount = tonumber(fields[amount_col]) or 0
                elseif debit_col and credit_col then
                    local debit = tonumber(fields[debit_col]) or 0
                    local credit = tonumber(fields[credit_col]) or 0
                    amount = credit - debit
                end

                table.insert(transactions, {
                    date = fields[date_col] or "",
                    description = fields[desc_col] or "",
                    amount = amount,
                    balance = balance_col and tonumber(fields[balance_col]),
                    category = nil,
                    source = mapping.bank_format or "ai-detected",
                })
            end
        end
    end

    return transactions
end

-- ============================================================================
-- Availability Check
-- ============================================================================

--- Check whether the Ollama service is reachable.
-- @return boolean
function AIService.isAvailable()
    local httpc, http_err = create_http_client()
    if not httpc then
        return false
    end

    local ok, res_or_err = pcall(function()
        return httpc:request_uri(OLLAMA_URL .. "/api/tags", {
            method = "GET",
            headers = {
                ["Content-Type"] = "application/json",
            },
        })
    end)

    if not ok then
        return false
    end

    local res = res_or_err
    return res and res.status == 200
end

return AIService
