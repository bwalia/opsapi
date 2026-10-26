--[[
    Conversational Tax Agent — tools
    ================================

    A SEPARATE, curated tool registry for the "file my tax" agent — deliberately
    NOT part of lib/agent/tools (the general assistant), so filing tools can never
    leak into the all-round chat assistant.

    Every tool:
      * declares `perms` = list of {module, action}; the executor checks the
        caller's RBAC before running (owners/admins bypass via hasPermission).
      * is scoped to the caller: tax data by user_id (the owner key), the agent's
        own session by namespace_id + user_id. The route adds requireAuth +
        requireNamespace on top.
      * NEVER computes tax itself — compute_estimate calls lib/tax-calc (the one
        source of truth). The model only chooses tools and writes one sentence.

    Confirm-gating: a tool with a `confirm(ctx,args)` returns a question the first
    time; the route stores `pending`, and only the user's explicit confirm re-runs
    it with ctx.confirmed = true.

    ctx = { namespace_id, user_id, user_uuid, tax_year, session_id,
            has_permission(module, action), confirmed? }
]]

local db = require("lapis.db")
local cjson = require("cjson")
local http = require("resty.http")
local TaxCalc = require("lib.tax-calc")

local TaxTools = {}
local registry = {}
local order = {}

local function register(spec)
    registry[spec.name] = spec
    order[#order + 1] = spec.name
end

local function allowed(ctx, perms)
    if not perms or #perms == 0 then return true end
    for _, p in ipairs(perms) do
        if ctx.has_permission(p[1], p[2]) then return true end
    end
    return false
end

-- Keep tool results small so they don't blow the model's context.
local function take(list, n)
    local out = {}
    for i = 1, math.min(#(list or {}), n) do out[i] = list[i] end
    return out
end

local VALID_INCOME_TYPES = {
    self_employment = true, uk_property = true, employment = true,
    dividends = true, savings_interest = true, other = true,
}

local function money(n) return string.format("£%.2f", tonumber(n) or 0) end

local function year_of(ctx, args)
    return (args and args.tax_year) or ctx.tax_year or TaxCalc.current_tax_year()
end

-- Authenticated internal call to an existing HMRC route, AS the user (forwards
-- their JWT + namespace headers). Reuses the tested filing endpoints rather than
-- re-implementing the binding HMRC sequence. 120s: HMRC trigger+poll can be slow.
local function hmrc_api(ctx, method, path, body)
    local httpc = http.new()
    httpc:set_timeout(120000)
    local headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" }
    for k, v in pairs(ctx.forward_headers or {}) do headers[k] = v end
    local res, err = httpc:request_uri("http://127.0.0.1:" .. (ctx.port or 80) .. path, {
        method = method,
        headers = headers,
        body = body and cjson.encode(body) or nil,
    })
    if not res then return nil, "Couldn't reach HMRC: " .. tostring(err) end
    local ok, decoded = pcall(cjson.decode, res.body or "")
    decoded = ok and decoded or {}
    return { status = res.status, data = decoded.data or decoded, raw = decoded }
end

-- Turn an HMRC error envelope into one readable sentence for the model to relay.
local function hmrc_error(r)
    local e = r.raw or {}
    local msg = e.error or e.message or ("HMRC returned HTTP " .. tostring(r.status))
    if type(e.detail) == "string" and e.detail ~= "" then msg = msg .. " (" .. e.detail .. ")" end
    if type(e.hmrc) == "table" and e.hmrc.code then msg = msg .. " [" .. tostring(e.hmrc.code) .. "]" end
    return msg
end

-- ============================ tools ============================

-- Clarifying question. Intercepted by the agent loop (lib/agent/agent) which
-- ends the turn and shows it — declared so the model has a sanctioned way to ask.
register({
    name = "ask_user",
    description = "Ask the user ONE short, specific question when you need a detail "
        .. "(their income type, tax year, a figure). Provide quick_replies when the "
        .. "answer is a small fixed set of choices.",
    parameters = {
        type = "object",
        properties = {
            question = { type = "string", description = "The single question to ask." },
            quick_replies = {
                type = "array",
                description = "Optional fixed choices the user can tap.",
                items = { type = "string" },
            },
        },
        required = { "question" },
    },
})

-- Establish / update the taxpayer profile. Applies immediately (benign, reversible)
-- and returns a summary the UI shows as a confirm card.
register({
    name = "set_tax_profile",
    description = "Record the user's tax profile once you know it: their income "
        .. "type(s) and tax year. income_types: self_employment, uk_property, "
        .. "employment, dividends, savings_interest, other. Call this before "
        .. "collecting figures.",
    parameters = {
        type = "object",
        properties = {
            income_types = {
                type = "array",
                description = "One or more of: self_employment, uk_property, employment, "
                    .. "dividends, savings_interest, other.",
                items = { type = "string" },
            },
            tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." },
            is_scottish_taxpayer = { type = "boolean", description = "True if a Scottish taxpayer." },
        },
        required = { "income_types" },
    },
    handler = function(ctx, args)
        local types_in = type(args.income_types) == "table" and args.income_types or {}
        local clean, bad = {}, {}
        for _, t in ipairs(types_in) do
            t = tostring(t):lower()
            if VALID_INCOME_TYPES[t] then clean[#clean + 1] = t else bad[#bad + 1] = t end
        end
        if #clean == 0 then
            return nil, "No valid income type given. Use one or more of: "
                .. "self_employment, uk_property, employment, dividends, savings_interest, other."
        end
        local tax_year = year_of(ctx, args)
        local profile = {
            income_types = clean,
            is_scottish_taxpayer = args.is_scottish_taxpayer == true,
            tax_year = tax_year,
        }
        -- Session is scoped by namespace_id + user_id; never trust a client-supplied id.
        db.query([[UPDATE tax_agent_sessions
            SET income_types = ?::jsonb, profile = ?::jsonb, tax_year = ?, updated_at = NOW()
            WHERE id = ? AND namespace_id = ? AND user_id = ?]],
            cjson.encode(clean), cjson.encode(profile), tax_year,
            ctx.session_id, ctx.namespace_id, ctx.user_id)
        return {
            saved = true,
            income_types = clean,
            tax_year = tax_year,
            is_scottish_taxpayer = profile.is_scottish_taxpayer,
            ignored = #bad > 0 and bad or nil,
            note = "Profile saved. Next, ask the user to upload a bank statement so we can "
                .. "extract and classify their income and expenses.",
        }
    end,
})

-- Prompt the user to upload a bank statement. The actual upload + extract +
-- classify runs through the existing tax endpoints (frontend); this just returns
-- the button the chat attaches to its message.
register({
    name = "request_bank_statement",
    description = "Ask the user to upload a bank statement for the current entity. "
        .. "Call this when you need their financial data. The UI shows an upload button.",
    perms = { { "tax_statements", "create" } },
    parameters = {
        type = "object",
        properties = {
            reason = { type = "string", description = "Short reason shown to the user, optional." },
        },
    },
    handler = function(_, args)
        return {
            upload_prompt = {
                kind = "bank_statement",
                button_label = "Upload bank statement",
                caption = args and args.reason or "Upload a PDF or CSV bank statement.",
            },
            note = "Upload button shown. After the user uploads and the transactions are "
                .. "classified, call get_review_queue then compute_estimate.",
        }
    end,
})

-- List the user's uploaded statements for the tax year (so the agent knows what exists).
register({
    name = "list_statements",
    description = "List the user's uploaded bank statements for the tax year and their "
        .. "processing status.",
    perms = { { "tax_statements", "read" } },
    parameters = {
        type = "object",
        properties = { tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." } },
    },
    handler = function(ctx, args)
        local rows = db.query([[
            SELECT uuid, bank_name, period_start, period_end, workflow_step, processing_status, tax_year
            -- Scoped to the exact tax_year (stamped at processing time). Not NULL-tolerant:
            -- that leaked other-year data between chats and made "New chat" purge too broad.
            FROM tax_statements WHERE user_id = ? AND tax_year = ?
            ORDER BY period_start ASC NULLS LAST, id ASC]],
            ctx.user_id, year_of(ctx, args))
        return { statements = take(rows or {}, 50), count = #(rows or {}) }
    end,
})

-- Transactions needing human review (NEEDS_REVIEW or low confidence) — for confirm cards.
register({
    name = "get_review_queue",
    description = "Get transactions that need the user's review for the tax year "
        .. "(flagged NEEDS_REVIEW or low confidence). Use the results to ask the user "
        .. "to confirm or correct each category.",
    perms = { { "tax_transactions", "read" } },
    parameters = {
        type = "object",
        properties = { tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." } },
    },
    handler = function(ctx, args)
        local rows = db.query([[
            SELECT t.uuid, t.description, t.amount, t.transaction_type, t.category,
                   t.hmrc_category, t.confidence_score, t.classification_status, t.transaction_date
            FROM tax_transactions t JOIN tax_statements s ON s.id = t.statement_id
            WHERE t.user_id = ? AND s.tax_year = ?
              AND (t.classification_status = 'NEEDS_REVIEW'
                   OR (t.confidence_score IS NOT NULL AND t.confidence_score < 0.7))
            ORDER BY t.confidence_score ASC NULLS FIRST
            LIMIT 25]],
            ctx.user_id, year_of(ctx, args))
        return { needs_review = take(rows or {}, 25), count = #(rows or {}) }
    end,
})

-- Correct a transaction's category. Catalogue-bounded + confirm-gated.
register({
    name = "apply_classification_fix",
    description = "Set the category for ONE transaction (by its uuid) to a valid "
        .. "category key. Use after the user tells you the correct category for a "
        .. "reviewed transaction. The user confirms before it is saved.",
    perms = { { "tax_transactions", "update" } },
    parameters = {
        type = "object",
        properties = {
            transaction_uuid = { type = "string", description = "The transaction's uuid." },
            category = { type = "string", description = "A valid tax category key (e.g. office_costs)." },
        },
        required = { "transaction_uuid", "category" },
    },
    -- Validates + builds the human-readable confirmation; returns (question, fixed_args).
    confirm = function(ctx, args)
        local cat = db.query([[
            SELECT c.key, c.label, c.is_tax_deductible, h.box AS hmrc_box
            FROM tax_categories c LEFT JOIN tax_hmrc_categories h ON h.id = c.hmrc_category_id
            WHERE c.key = ? AND c.is_active = true LIMIT 1]], tostring(args.category or ""))
        if not cat or not cat[1] then
            error("Unknown category '" .. tostring(args.category) .. "'. Call get_review_queue or ask the "
                .. "user to pick a listed category.")
        end
        local txn = db.query([[SELECT description, amount FROM tax_transactions
            WHERE uuid = ? AND user_id = ? LIMIT 1]], tostring(args.transaction_uuid or ""), ctx.user_id)
        if not txn or not txn[1] then
            error("Transaction not found for this user.")
        end
        local c = cat[1]
        return ("Set **" .. tostring(txn[1].description) .. "** (" .. money(txn[1].amount)
            .. ") to **" .. tostring(c.label) .. "**"
            .. (c.hmrc_box and (" (HMRC box " .. tostring(c.hmrc_box) .. ")") or "") .. "?")
    end,
    handler = function(ctx, args)
        local cat = db.query([[
            SELECT c.key, c.label, c.is_tax_deductible, h.box AS hmrc_box, h.key AS hmrc_key
            FROM tax_categories c LEFT JOIN tax_hmrc_categories h ON h.id = c.hmrc_category_id
            WHERE c.key = ? AND c.is_active = true LIMIT 1]], tostring(args.category or ""))
        if not cat or not cat[1] then
            return nil, "Unknown category '" .. tostring(args.category) .. "'."
        end
        local c = cat[1]
        -- Scoped by user_id (the owner); a user can only fix their own transactions.
        -- hmrc_category stores the catalogue KEY (e.g. car_van_travel), not the box
        -- number: the HMRC aggregator and the report join on tax_hmrc_categories.key.
        -- Non-business categories have no HMRC box, so it is cleared.
        local res = db.query([[UPDATE tax_transactions
            SET category = ?, hmrc_category = ?, is_tax_deductible = ?, classification_status = 'CLASSIFIED',
                classified_by = 'user', confidence_score = 1.0, is_manually_reviewed = true, updated_at = NOW()
            WHERE uuid = ? AND user_id = ?]],
            c.key, c.hmrc_key or db.NULL, c.is_tax_deductible and true or false,
            tostring(args.transaction_uuid), ctx.user_id)
        if not res or (res.affected_rows or 0) == 0 then
            return nil, "Transaction not found for this user."
        end
        return { updated = true, category = c.key, label = c.label, hmrc_box = c.hmrc_box }
    end,
})

-- ======================= shared year estimate =======================
-- The chat estimate, the Calculate screens (routes/tax-calculate), the reports
-- tax calculation (routes/tax-reports) and the filing workbook (lib/tax-report)
-- all use these, so they cannot disagree.

--- Money in / allowable money out for a user's tax year, from classified transactions.
-- Income = credits, EXCEPT those classified into a non-business category (one with no
-- HMRC box: transfer, loan, drawings, personal) — a transfer from your own savings or a
-- loan is not taxable income. (is_tax_deductible applies to EXPENSES; every income
-- category is stored is_tax_deductible=false.) Expenses = debits the classifier marked
-- deductible. A statement belongs to the year stamped on it (tax_statements.tax_year).
-- @return { income, expenses, unreviewed }
function TaxTools.year_totals(user_id, tax_year)
    local agg = db.query([[
        SELECT
          COALESCE(SUM(CASE WHEN t.transaction_type = 'CREDIT' AND NOT EXISTS (
               SELECT 1 FROM tax_categories c WHERE c.key = t.category AND c.hmrc_category_id IS NULL)
               THEN t.amount ELSE 0 END), 0) AS gross_income,
          COALESCE(SUM(CASE WHEN t.transaction_type = 'DEBIT' AND t.is_tax_deductible = true
               THEN t.amount ELSE 0 END), 0) AS total_expenses,
          COUNT(*) FILTER (WHERE t.classification_status IN ('PENDING','NEEDS_REVIEW')) AS unreviewed
        FROM tax_transactions t JOIN tax_statements s ON s.id = t.statement_id
        WHERE t.user_id = ? AND s.tax_year = ?]],
        user_id, tax_year)
    local row = (agg and agg[1]) or {}
    return {
        income = tonumber(row.gross_income) or 0,
        expenses = tonumber(row.total_expenses) or 0,
        unreviewed = tonumber(row.unreviewed) or 0,
    }
end

--- The income types / extra figures the customer gave the tax agent for this year
-- (latest chat), defaulting to self-employment. namespace_id is optional: routes that
-- aren't namespace-scoped look across the user's chats.
function TaxTools.profile_for(user_id, tax_year, namespace_id)
    local rows
    if namespace_id then
        rows = db.query([[SELECT profile FROM tax_agent_sessions
            WHERE namespace_id = ? AND user_id = ? AND tax_year = ?
            ORDER BY archived ASC, updated_at DESC LIMIT 1]], namespace_id, user_id, tax_year)
    else
        rows = db.query([[SELECT profile FROM tax_agent_sessions
            WHERE user_id = ? AND tax_year = ?
            ORDER BY archived ASC, updated_at DESC LIMIT 1]], user_id, tax_year)
    end
    local raw = rows and rows[1] and rows[1].profile
    local profile = type(raw) == "table" and raw or {}
    if type(raw) == "string" and raw ~= "" then
        local ok, t = pcall(cjson.decode, raw)
        if ok and type(t) == "table" then profile = t end
    end
    if type(profile.income_types) ~= "table" or #profile.income_types == 0 then
        profile.income_types = { "self_employment" }
    end
    return profile
end

--- Full UK estimate for a year from money in / allowable money out (lib/tax-calc
-- compute_full), plus the legacy-compatible fields the screens read.
-- Routes the bank-statement totals to the right schedule from the profile, then adds
-- any other income the agent gathered (employment, savings, dividends, Gift Aid). The
-- engine applies the bands, allowances and NIC (Class 4 on trading profit only).
-- opts: { unreviewed = n }
function TaxTools.estimate(income, expenses, tax_year, profile, opts)
    opts = opts or {}
    profile = profile or {}
    local types = type(profile.income_types) == "table" and profile.income_types or {}
    local has_se, only_property = false, #types > 0
    for _, t in ipairs(types) do
        if t == "self_employment" then has_se = true end
        if t ~= "uk_property" then only_property = false end
    end
    local inp = {
        employment_income = tonumber(profile.employment_income) or 0,
        paye_deducted = tonumber(profile.paye_deducted) or 0,
        savings_interest = tonumber(profile.savings_interest) or 0,
        dividends = tonumber(profile.dividends) or 0,
        gift_aid_net = tonumber(profile.gift_aid_net) or 0,
    }
    if only_property and not has_se then
        inp.property_rents = income
        inp.property_expenses = expenses
        inp.property_finance_costs = tonumber(profile.property_finance_costs) or 0
    else
        inp.se_turnover = income
        inp.se_expenses = expenses
    end

    local rates = TaxCalc.load_rates(tax_year)
    local full = TaxCalc.compute_full(inp, rates)
    full.tax_year = tax_year
    full.gross_income = income
    full.total_expenses = expenses
    full.unreviewed_count = tonumber(opts.unreviewed) or 0
    full.profit = (full.schedules.trading_profit or 0) + (full.schedules.property_profit or 0)
    full.trading_profit = full.profit
    full.taxable_income = full.total_taxable
    -- "NIC applies to this profile?" — true for self-employment (even at a loss,
    -- where the amount is just £0), false only for property-only income (no Class
    -- 2/4). The frontend shows "N/A — property income" only when this is false.
    full.nic_applied = not (only_property and not has_se)
    local by_name = {}
    for _, b in ipairs(full.income_tax_bands or {}) do by_name[b.name] = b end
    local function band(name, rate)
        local b = by_name[name]
        return { amount = b and b.tax or 0, rate = rate }
    end
    full.income_tax = {
        basic = band("Basic Rate", rates.basic_rate),
        higher = band("Higher Rate", rates.higher_rate),
        additional = band("Additional Rate", rates.additional_rate),
        total = full.income_tax_due,
    }
    full.national_insurance = { class4 = full.class4_nic, class2 = full.class2_nic,
        total = (full.class4_nic or 0) + (full.class2_nic or 0) }
    full.total_tax_due = full.total_liability
    full.effective_rate = (full.total_income or 0) > 0
        and (math.floor(full.total_liability / full.total_income * 10000) / 100) or 0
    full.is_estimate = true
    return full
end

--- The estimate for a user's tax year from their classified transactions.
function TaxTools.compute_year(user_id, tax_year, profile)
    local totals = TaxTools.year_totals(user_id, tax_year)
    return TaxTools.estimate(totals.income, totals.expenses, tax_year, profile,
        { unreviewed = totals.unreviewed })
end

-- The deterministic running estimate. The ONLY tax figure the user sees — computed
-- by lib/tax-calc, never by the model.
register({
    name = "compute_estimate",
    description = "Compute the user's estimated tax for the tax year from their "
        .. "classified transactions. Returns income, expenses, profit, income tax, "
        .. "National Insurance and the total due. Call this after classification to "
        .. "show a running estimate. Always present it as an estimate.",
    perms = { { "tax_transactions", "read" } },
    parameters = {
        type = "object",
        properties = { tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." } },
    },
    handler = function(ctx, args)
        return TaxTools.compute_year(ctx.user_id, year_of(ctx, args), ctx._profile)
    end,
})

-- HMRC connection status. The OAuth connect itself is NOT in chat — it happens
-- on the Tax → File screen — so this tells the agent whether a preview can run.
register({
    name = "hmrc_status",
    description = "Check whether the user has connected their HMRC account. Call before "
        .. "offering a preview. The HMRC connection itself is done on the Tax → File screen.",
    perms = { { "tax_file", "access" } },
    parameters = { type = "object", properties = {} },
    handler = function(ctx)
        -- hmrc_tokens is keyed by the user's uuid (it has no user_id column).
        local rows = db.query([[SELECT 1 FROM hmrc_tokens WHERE user_uuid = ? LIMIT 1]], tostring(ctx.user_uuid))
        local connected = rows and rows[1] ~= nil
        return {
            connected = connected,
            note = connected and "HMRC is connected — you can run a non-binding preview calculation. Filing the "
                    .. "final return is done on the Tax → File screen."
                or "Not connected to HMRC yet. Ask the user to connect on the Tax → File screen, then come back.",
        }
    end,
})

-- HMRC obligations (what updates/declarations are due for the year). Read-only.
register({
    name = "get_obligations",
    description = "Fetch the user's HMRC Self Assessment obligations for the tax year "
        .. "(what's due). Requires an HMRC connection.",
    perms = { { "tax_file", "access" } },
    parameters = {
        type = "object",
        properties = { tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." } },
    },
    handler = function(ctx, args)
        local tax_year = year_of(ctx, args)
        local r, err = hmrc_api(ctx, "POST", "/api/v2/hmrc/obligations/fetch", { tax_year = tax_year })
        if not r then return nil, err end
        if r.status >= 400 then return nil, hmrc_error(r) end
        return { tax_year = tax_year, obligations = r.data }
    end,
})

-- Non-binding: submit the period figures to HMRC and return HMRC's OWN calculated
-- figures (the authoritative numbers, as a preview — does NOT file the return).
register({
    name = "preview_calculation",
    description = "Send the user's figures to HMRC for a NON-BINDING calculation and return "
        .. "HMRC's own calculated tax for the year. Does NOT file the return. Requires an HMRC "
        .. "connection; tell the user you're sending their figures to HMRC for a preview first.",
    perms = { { "tax_file", "access" } },
    parameters = {
        type = "object",
        properties = { tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." } },
    },
    handler = function(ctx, args)
        local tax_year = year_of(ctx, args)
        local r, err = hmrc_api(ctx, "POST", "/api/v2/tax/hmrc/calculate-preview", { tax_year = tax_year })
        if not r then return nil, err end
        if r.status >= 400 then return nil, hmrc_error(r) end
        return {
            tax_year = tax_year,
            calculation_id = r.data.calculation_id,
            figures = r.data.figures,
            sandbox_placeholder = r.data.sandbox_placeholder,
            note = "These are HMRC's non-binding calculated figures — not filed. To file the return, "
                .. "the user uses the Tax → File screen.",
        }
    end,
})

-- ===================== definitions + executor =====================

--- Ollama tool definitions (function schemas) for the whole curated tax tool set.
function TaxTools.definitions()
    local defs = {}
    for _, name in ipairs(order) do
        local spec = registry[name]
        defs[#defs + 1] = {
            type = "function",
            ["function"] = {
                name = spec.name,
                description = spec.description,
                parameters = spec.parameters,
            },
        }
    end
    return defs
end

--- Execute a tool with RBAC + confirm-gating. Returns (result_table|nil, err_string|nil).
-- ask_user is handled by the agent loop and never reaches here.
function TaxTools.execute(ctx, name, args)
    local spec = registry[name]
    if not spec then return nil, "Unknown tool: " .. tostring(name) end
    if not spec.handler then
        return nil, "Tool " .. name .. " cannot be executed directly."
    end
    if not allowed(ctx, spec.perms) then
        return nil, "You don't have permission to do that (" .. name .. ") in this workspace."
    end
    if spec.confirm and not ctx.confirmed then
        local okc, question = pcall(spec.confirm, ctx, args or {})
        if not okc then
            return nil, tostring(question) -- the confirm fn raised a validation message
        end
        if question then
            return {
                needs_confirmation = true,
                question = question,
                pending = { tool = name, args = args or {}, summary = (question:gsub("%*", "")) },
            }
        end
    end
    local ok, res, err = pcall(spec.handler, ctx, args or {})
    if not ok then return nil, "Tool error: " .. tostring(res) end
    if err then return nil, err end
    return res
end

return TaxTools
