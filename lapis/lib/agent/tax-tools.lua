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
            SELECT c.key, c.label, c.is_tax_deductible, h.box AS hmrc_box
            FROM tax_categories c LEFT JOIN tax_hmrc_categories h ON h.id = c.hmrc_category_id
            WHERE c.key = ? AND c.is_active = true LIMIT 1]], tostring(args.category or ""))
        if not cat or not cat[1] then
            return nil, "Unknown category '" .. tostring(args.category) .. "'."
        end
        local c = cat[1]
        -- Scoped by user_id (the owner); a user can only fix their own transactions.
        local res = db.query([[UPDATE tax_transactions
            SET category = ?, hmrc_category = ?, is_tax_deductible = ?, classification_status = 'CLASSIFIED',
                classified_by = 'user', confidence_score = 1.0, is_manually_reviewed = true, updated_at = NOW()
            WHERE uuid = ? AND user_id = ?]],
            c.key, c.hmrc_box, c.is_tax_deductible and true or false,
            tostring(args.transaction_uuid), ctx.user_id)
        if not res or (res.affected_rows or 0) == 0 then
            return nil, "Transaction not found for this user."
        end
        return { updated = true, category = c.key, label = c.label, hmrc_box = c.hmrc_box }
    end,
})

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
        local tax_year = year_of(ctx, args)
        local agg = db.query([[
            SELECT
              COALESCE(SUM(CASE WHEN t.classification_status IN ('CLASSIFIED','CONFIRMED')
                   AND t.transaction_type = 'CREDIT' AND t.is_tax_deductible IS NOT FALSE
                   THEN t.amount ELSE 0 END), 0) AS gross_income,
              COALESCE(SUM(CASE WHEN t.classification_status IN ('CLASSIFIED','CONFIRMED')
                   AND t.transaction_type = 'DEBIT' AND t.is_tax_deductible = true
                   THEN t.amount ELSE 0 END), 0) AS total_expenses,
              COUNT(*) FILTER (WHERE t.classification_status IN ('PENDING','NEEDS_REVIEW')) AS unreviewed
            FROM tax_transactions t JOIN tax_statements s ON s.id = t.statement_id
            WHERE t.user_id = ? AND s.tax_year = ?]],
            ctx.user_id, tax_year)
        local row = (agg and agg[1]) or { gross_income = 0, total_expenses = 0, unreviewed = 0 }
        local rates = TaxCalc.load_rates(tax_year)
        local calc = TaxCalc.compute(tonumber(row.gross_income) or 0, tonumber(row.total_expenses) or 0, rates)
        calc.tax_year = tax_year
        calc.unreviewed_count = tonumber(row.unreviewed) or 0
        calc.is_estimate = true
        return calc
    end,
})

-- Read-only HMRC connection status (actual filing is a later phase).
register({
    name = "hmrc_status",
    description = "Check whether the user has connected their HMRC account. Read-only; "
        .. "filing to HMRC is not available in the chat yet.",
    perms = { { "tax_file", "access" } },
    parameters = { type = "object", properties = {} },
    handler = function(ctx)
        local rows = db.query([[SELECT 1 FROM hmrc_tokens WHERE user_id = ? LIMIT 1]], ctx.user_id)
        local connected = rows and rows[1] ~= nil
        return {
            connected = connected,
            note = connected and "HMRC is connected. Submitting the return in chat is coming soon; "
                    .. "for now the user can file from the Tax → File screen."
                or "Not connected to HMRC yet. The user can connect from the Tax → File screen.",
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
