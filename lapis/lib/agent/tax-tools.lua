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

local IncomeTypes = require("lib.income-types")

-- Income types are rows in income_types (system defaults + the workspace's own /
-- overrides — Tax → Income types), not a hard-coded list. The agent's original keys
-- (employment, uk_property, savings_interest) keep working via IncomeTypes.AGENT_ALIASES.
-- If the catalogue can't be read (e.g. no DB in a unit test) this fallback — the old
-- hard-coded set, in catalogue keys — is used.
local FALLBACK_INCOME_TYPES = {
    self_employment = true, salary = true, rental = true,
    dividends = true, interest = true, other = true,
}

--- The catalogue: { keys = { key = true }, list = { { key, name }, ... } } for a namespace.
local function income_catalogue(namespace_id)
    local ok, Q = pcall(require, "queries.TaxIncomeQueries")
    if ok and namespace_id then
        local ok2, types = pcall(Q.types_for, namespace_id)
        if ok2 and type(types) == "table" and #types > 0 then
            local keys, list = {}, {}
            for _, t in ipairs(types) do
                keys[t.income_type_key] = true
                list[#list + 1] = { key = t.income_type_key, name = t.display_name }
            end
            return { keys = keys, list = list }
        end
    end
    local list = {}
    for k in pairs(FALLBACK_INCOME_TYPES) do list[#list + 1] = { key = k, name = k } end
    table.sort(list, function(a, b) return a.key < b.key end)
    return { keys = FALLBACK_INCOME_TYPES, list = list }
end
TaxTools.income_catalogue = income_catalogue

-- Profile keys that hold figures for ONE tax year (cleared when the year changes).
local YEAR_FIGURES = { "property_finance_costs", "commercial_finance_costs", "property_rents",
    "property_expenses" }

local save_profile_patch -- defined below (needs TaxTools.merge_profile)

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

--- Shallow-merge a profile patch over an existing profile (pure; for tests too).
-- Keys in `patch` win; every other existing key is kept. Never mutates its inputs.
function TaxTools.merge_profile(existing, patch)
    local out = {}
    for k, v in pairs(type(existing) == "table" and existing or {}) do out[k] = v end
    for k, v in pairs(type(patch) == "table" and patch or {}) do out[k] = v end
    return out
end

-- Persist a profile patch for the caller's session, merged server-side with
-- jsonb `||` (top-level keys in the patch replace, all others are kept), and
-- mirror it into ctx._profile so a compute_estimate later in the SAME turn sees it.
-- cols: optional { income_types = {...}, tax_year = "..." } column updates.
-- Scoped by namespace_id + user_id; never trusts a client-supplied session id.
save_profile_patch = function(ctx, patch, cols)
    cols = cols or {}
    db.query([[UPDATE tax_agent_sessions
        SET profile = COALESCE(profile, '{}'::jsonb) || ?::jsonb,
            income_types = COALESCE(?::jsonb, income_types),
            tax_year = COALESCE(?, tax_year),
            updated_at = NOW()
        WHERE id = ? AND namespace_id = ? AND user_id = ?]],
        cjson.encode(patch),
        cols.income_types and cjson.encode(cols.income_types) or db.NULL,
        cols.tax_year or db.NULL,
        ctx.session_id, ctx.namespace_id, ctx.user_id)
    ctx._profile = TaxTools.merge_profile(ctx._profile, patch)
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
        .. "type(s) and tax year. income_types are keys from the workspace's income type "
        .. "list (e.g. self_employment, salary, rental, dividends, interest, pension, other; "
        .. "employment / uk_property / savings_interest also work). Call this before "
        .. "collecting figures.",
    parameters = {
        type = "object",
        properties = {
            income_types = {
                type = "array",
                description = "One or more income type keys, e.g. self_employment, salary, "
                    .. "rental, dividends, interest, pension, other.",
                items = { type = "string" },
            },
            tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." },
            is_scottish_taxpayer = { type = "boolean", description = "True if a Scottish taxpayer." },
        },
        required = { "income_types" },
    },
    handler = function(ctx, args)
        local catalogue = income_catalogue(ctx.namespace_id)
        local clean, bad = IncomeTypes.normalise_agent_types(args.income_types, catalogue.keys)
        if #clean == 0 then
            local names = {}
            for _, t in ipairs(catalogue.list) do names[#names + 1] = t.key end
            return nil, "No valid income type given. Use one or more of: " .. table.concat(names, ", ") .. "."
        end
        local tax_year = year_of(ctx, args)
        local patch = {
            income_types = clean,
            is_scottish_taxpayer = args.is_scottish_taxpayer == true,
            tax_year = tax_year,
        }
        -- Year-specific figures belong to the year they were given for: switching
        -- year clears them (JSON null) instead of carrying them over.
        if ctx.tax_year and tax_year ~= ctx.tax_year then
            for _, k in ipairs(YEAR_FIGURES) do patch[k] = cjson.null end
        end
        -- MERGE into the stored profile (jsonb ||) so figures another tool saved
        -- (e.g. property_finance_costs) survive a later profile update.
        save_profile_patch(ctx, patch, { income_types = clean, tax_year = tax_year })
        ctx.tax_year = tax_year
        local profile = patch
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

-- Landlord figures the bank statement can't tell us. Section 24 (ITTOIA 2005
-- s272A / ITA 2007 s399A): finance costs on RESIDENTIAL lets are not deducted from
-- rental profit; instead they give a basic-rate (20%) tax reduction — 20% of the
-- lowest of (finance costs, property profit, adjusted total income above the
-- personal allowance). Commercial (non-residential) mortgage interest is NOT
-- restricted: it stays an ordinary deductible expense, so it must NOT be given here
-- (leave it classified as Loan Interest in their transactions).
register({
    name = "set_property_finance_costs",
    description = "Record a LANDLORD's residential property finance costs for the tax year: the "
        .. "mortgage/loan INTEREST (plus arrangement fees) on residential let property — NOT capital "
        .. "repayments, and NOT interest on commercial property (that stays a normal expense). Bank "
        .. "statements can't separate interest from capital, so whenever the user has uk_property "
        .. "income ASK them for this year's residential mortgage interest before giving an estimate; "
        .. "if they have none, record 0. It earns a 20% tax credit (Section 24) in the estimate. "
        .. "If they ALSO have self-employment, also ask for their total rental income and rental "
        .. "expenses (property_income, property_expenses) so the bank totals can be split; without "
        .. "them no finance-cost credit can be applied.",
    perms = { { "tax_transactions", "read" } },
    parameters = {
        type = "object",
        properties = {
            residential_finance_costs = {
                type = "number",
                description = "Residential mortgage/loan INTEREST + finance fees for the tax year in £ "
                    .. "(not capital repayments). 0 if none.",
            },
            commercial_finance_costs = {
                type = "number",
                description = "Mortgage/loan INTEREST on COMMERCIAL (non-residential) property for the tax "
                    .. "year in £ (not capital repayments). It is an ordinary expense. 0 if none.",
            },
            property_income = {
                type = "number",
                description = "Optional, only for users who are ALSO self-employed: total rents "
                    .. "received for the year in £.",
            },
            property_expenses = {
                type = "number",
                description = "Optional, with property_income: allowable rental expenses for the year "
                    .. "in £ (excluding residential finance costs).",
            },
            tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." },
        },
        required = { "residential_finance_costs" },
    },
    handler = function(ctx, args)
        local fc = tonumber(args.residential_finance_costs)
        if not fc or fc ~= fc or fc < 0 or fc == math.huge then
            return nil, "residential_finance_costs must be a number of pounds, 0 or more."
        end
        local patch = { property_finance_costs = math.floor(fc * 100 + 0.5) / 100 }
        if args.commercial_finance_costs ~= nil then
            local cfc = tonumber(args.commercial_finance_costs)
            if not cfc or cfc ~= cfc or cfc < 0 or cfc == math.huge then
                return nil, "commercial_finance_costs must be a number of pounds, 0 or more."
            end
            patch.commercial_finance_costs = math.floor(cfc * 100 + 0.5) / 100
        end
        local rents, pexp = tonumber(args.property_income), tonumber(args.property_expenses)
        if args.property_income ~= nil then
            if not rents or rents < 0 then return nil, "property_income must be 0 or more." end
            patch.property_rents = math.floor(rents * 100 + 0.5) / 100
        end
        if args.property_expenses ~= nil then
            if not pexp or pexp < 0 then return nil, "property_expenses must be 0 or more." end
            patch.property_expenses = math.floor(pexp * 100 + 0.5) / 100
        end
        save_profile_patch(ctx, patch)
        return {
            saved = true,
            property_finance_costs = patch.property_finance_costs,
            commercial_finance_costs = patch.commercial_finance_costs,
            property_rents = patch.property_rents,
            property_expenses = patch.property_expenses,
            tax_credit_rate = 0.20,
            note = "Saved. Residential finance costs are not deducted from rental profit; they give a "
                .. "20% tax reduction instead. Commercial interest is deducted as an expense. Call "
                .. "compute_estimate to show the updated estimate.",
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

-- Commercial property interest the landlord stated, as an expense. Interest already
-- classified from the statements beyond the residential figure (the old way, kept for
-- years classified before mortgage payments stopped being claimed) already counts as
-- an expense, so only the part of the stated figure not already in `expenses` is added.
local function commercial_interest(profile, opts, fin)
    local stated = math.max(0, tonumber(profile.commercial_finance_costs) or 0)
    local already = math.max(0, (tonumber(opts.finance_interest) or 0) - fin)
    return math.max(0, stated - already)
end
TaxTools._commercial_interest = commercial_interest

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
-- @return { income, expenses, finance_interest, unreviewed }
function TaxTools.year_totals(user_id, tax_year)
    local agg = db.query([[
        SELECT
          COALESCE(SUM(CASE WHEN t.transaction_type = 'CREDIT' AND NOT EXISTS (
               SELECT 1 FROM tax_categories c WHERE c.key = t.category AND c.hmrc_category_id IS NULL)
               THEN t.amount ELSE 0 END), 0) AS gross_income,
          COALESCE(SUM(CASE WHEN t.transaction_type = 'DEBIT' AND t.is_tax_deductible = true
               THEN t.amount ELSE 0 END), 0) AS total_expenses,
          COALESCE(SUM(CASE WHEN t.transaction_type = 'DEBIT' AND t.is_tax_deductible = true
               AND t.hmrc_category = 'interest_finance' THEN t.amount ELSE 0 END), 0) AS finance_interest,
          COUNT(*) FILTER (WHERE t.classification_status IN ('PENDING','NEEDS_REVIEW')) AS unreviewed
        FROM tax_transactions t JOIN tax_statements s ON s.id = t.statement_id
        WHERE t.user_id = ? AND s.tax_year = ?]],
        user_id, tax_year)
    local row = (agg and agg[1]) or {}
    return {
        income = tonumber(row.gross_income) or 0,
        expenses = tonumber(row.total_expenses) or 0,
        -- the part of `expenses` classified as loan/finance interest (HMRC interest_finance)
        finance_interest = tonumber(row.finance_interest) or 0,
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
        -- Not stated by the user: the estimate may take the income types from My Income.
        profile._defaulted = true
    end
    return profile
end

--- The user's My Income figures for a year as compute_full inputs (lib/income-types
-- estimator_inputs shape). Never fails the estimate: on any error, no My Income.
function TaxTools.my_income_for(user_id, tax_year, namespace_id)
    local ok, Q = pcall(require, "queries.TaxIncomeQueries")
    if ok then
        local ok2, res = pcall(Q.estimator_inputs, user_id, tax_year, namespace_id)
        if ok2 and type(res) == "table" then return res end
    end
    return IncomeTypes.estimator_inputs({}, {})
end

--- Full UK estimate for a year from money in / allowable money out (lib/tax-calc
-- compute_full), plus the legacy-compatible fields the screens read.
-- Routes the bank-statement totals to the right schedule from the profile, then adds
-- any other income the agent gathered (employment, savings, dividends, Gift Aid). The
-- engine applies the bands, allowances and NIC (Class 4 on trading profit only).
-- opts: { unreviewed = n, finance_interest = n (interest already inside `expenses`),
--         my_income = TaxTools.my_income_for(...) }
--
-- My Income (figures the user typed per income type) takes priority over the bank
-- totals and the chat profile, schedule by schedule:
--   * types: if the user never stated income types to the agent, they come from My
--     Income; otherwise My Income's types are added to the stated ones;
--   * property: My Income's rents/expenses are used as the split of the bank totals
--     (the same rule as figures stated in the chat), and replace them;
--   * self-employment: My Income's figures replace the bank-statement totals;
--   * every other input (employment, pensions, savings, dividends, ...) overrides the
--     chat profile's figure.
function TaxTools.estimate(income, expenses, tax_year, profile, opts)
    opts = opts or {}
    profile = profile or {}
    local mi = type(opts.my_income) == "table" and opts.my_income or nil
    if mi and not mi.has_data then mi = nil end
    local types = type(profile.income_types) == "table" and profile.income_types or {}
    if mi then
        local merged, seen = {}, {}
        local base = profile._defaulted and {} or types
        for _, list in ipairs({ base, mi.agent_types or {} }) do
            for _, t in ipairs(list) do
                if not seen[t] then seen[t] = true; merged[#merged + 1] = t end
            end
        end
        -- bank totals with no schedule from My Income still need somewhere to go
        if #merged == 0 then merged = { "self_employment" } end
        types = merged
        if mi.groups.property then
            local split = {}
            for k, v in pairs(profile) do split[k] = v end
            split.property_rents = mi.inputs.property_rents or 0
            split.property_expenses = mi.inputs.property_expenses or 0
            split.property_finance_costs = mi.inputs.property_finance_costs or 0
            profile = split
        end
    end
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
    -- Section 24: residential finance costs are NOT a deductible expense; they earn a
    -- 20% tax reduction (lib/tax-calc compute_full step 8). If the bank-statement
    -- expenses already deducted interest (classified Loan Interest / interest_finance),
    -- take the user's stated residential interest back out — up to the amount actually
    -- classified — so it isn't deducted AND credited. Any classified interest beyond
    -- the stated residential figure stays deductible (treated as commercial/other).
    local has_property = false
    for _, t in ipairs(types) do if t == "uk_property" then has_property = true end end
    local fin = math.max(0, tonumber(profile.property_finance_costs) or 0)
    local notes = {}
    local moved, added = 0, 0
    if only_property and not has_se then
        moved = math.min(fin, math.max(0, tonumber(opts.finance_interest) or 0))
        inp.property_rents = income
        added = commercial_interest(profile, opts, fin)
        inp.property_expenses = expenses - moved + added
        inp.property_finance_costs = fin
    elseif has_se and has_property and tonumber(profile.property_rents) then
        -- Mixed self-employment + property: split the bank totals ONLY with the rental
        -- figures the user stated; the rest is trading. Never guess a split.
        local rents = math.min(income, math.max(0, tonumber(profile.property_rents)))
        local pexp = math.min(expenses, math.max(0, tonumber(profile.property_expenses) or 0))
        inp.property_rents = rents
        inp.property_expenses = pexp
        inp.property_finance_costs = fin
        inp.se_turnover = income - rents
        inp.se_expenses = expenses - pexp
    else
        inp.se_turnover = income
        inp.se_expenses = expenses
        if has_property and fin > 0 then
            notes[#notes + 1] = "Residential finance costs (£" .. string.format("%.2f", fin) .. ") were not "
                .. "applied: your bank totals mix trading and rental income. Give your total rental income "
                .. "and rental expenses so the 20% finance-cost credit can be worked out."
        end
    end

    if mi then
        local group_of = {}
        for g, list in pairs(IncomeTypes.GROUPS) do for _, k in ipairs(list) do group_of[k] = g end end
        if mi.groups.self_employment then
            for _, k in ipairs(IncomeTypes.GROUPS.self_employment) do inp[k] = mi.inputs[k] or 0 end
            notes[#notes + 1] = "Self-employment figures come from My Income (they replace the bank-statement "
                .. "totals for your business)."
        end
        if mi.groups.property then
            for _, k in ipairs(IncomeTypes.GROUPS.property) do inp[k] = mi.inputs[k] or 0 end
        end
        for k, v in pairs(mi.inputs) do
            if not group_of[k] then inp[k] = v end
        end
    end

    local rates = TaxCalc.load_rates(tax_year)
    local full = TaxCalc.compute_full(inp, rates)
    full.tax_year = tax_year
    full.gross_income = income
    -- Allowable expenses: residential interest moved out under Section 24 is not one.
    full.total_expenses = expenses - moved + added
    full.unreviewed_count = tonumber(opts.unreviewed) or 0
    full.profit = (full.schedules.trading_profit or 0) + (full.schedules.property_profit or 0)
    full.trading_profit = full.profit
    full.taxable_income = full.total_taxable
    -- "NIC applies to this profile?" — true for self-employment (even at a loss,
    -- where the amount is just £0), false only for property-only income (no Class
    -- 2/4). The frontend shows "N/A — property income" only when this is false.
    full.nic_applied = not (only_property and not has_se) or (mi ~= nil and mi.groups.self_employment == true)
    full.my_income_inputs = mi and mi.inputs or nil
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
    full.property_finance_costs = inp.property_finance_costs or 0
    full.finance_costs_moved_from_expenses = moved
    full.notes = #notes > 0 and notes or nil
    full.is_estimate = true
    return full
end

--- The estimate for a user's tax year from their classified transactions plus the
-- figures they typed under My Income. namespace_id is optional (see
-- TaxIncomeQueries.estimator_inputs for the rule without one).
function TaxTools.compute_year(user_id, tax_year, profile, namespace_id)
    local totals = TaxTools.year_totals(user_id, tax_year)
    return TaxTools.estimate(totals.income, totals.expenses, tax_year, profile,
        { unreviewed = totals.unreviewed, finance_interest = totals.finance_interest,
          my_income = TaxTools.my_income_for(user_id, tax_year, namespace_id) })
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
        return TaxTools.compute_year(ctx.user_id, year_of(ctx, args), ctx._profile, ctx.namespace_id)
    end,
})

-- What the user typed under Tax -> My Income (jobs, properties, pensions, dividends...).
-- Read-only; these figures already feed compute_estimate.
register({
    name = "get_my_income",
    description = "Read the income the user has entered under Tax > My Income for the tax year "
        .. "(jobs, businesses, properties, pensions, savings, dividends): which income types they "
        .. "have, how far through each they are, and the totals. These figures already feed "
        .. "compute_estimate. Use it to avoid asking for figures they've already given, and point "
        .. "them to My Income to add or correct them.",
    perms = { { "tax_transactions", "read" } },
    parameters = {
        type = "object",
        properties = { tax_year = { type = "string", description = "UK tax year, e.g. 2025-26." } },
    },
    handler = function(ctx, args)
        local tax_year = year_of(ctx, args)
        local Q = require("queries.TaxIncomeQueries")
        local types = Q.types_for(ctx.namespace_id, { include_inactive = true })
        local records = Q.records(ctx.namespace_id, ctx.user_id, tax_year)
        local by_key = Q.by_key(types)
        local per = {}
        for _, r in ipairs(records) do
            local t = by_key[r.income_type_key]
            if t then
                local e = per[r.income_type_key]
                if not e then
                    e = { key = r.income_type_key, name = t.display_name, records = 0, done = 0,
                        not_applicable = false, totals = { income = 0, expense = 0, tax_paid = 0, relief = 0 } }
                    per[r.income_type_key] = e
                end
                if r.status == "not_applicable" then
                    e.not_applicable = true
                else
                    e.records = e.records + 1
                    if r.status == "done" then e.done = e.done + 1 end
                    for k, v in pairs(IncomeTypes.record_totals(t.field_schema, r.values, t.estimator_mapping)) do
                        e.totals[k] = e.totals[k] + v
                    end
                end
            end
        end
        local list = {}
        for _, t in ipairs(types) do
            if per[t.income_type_key] then list[#list + 1] = per[t.income_type_key] end
        end
        local est = IncomeTypes.estimator_inputs(by_key, records)
        return {
            tax_year = tax_year,
            income_types = list,
            estimate_inputs = est.inputs,
            note = #list == 0 and "Nothing entered under My Income for this year yet."
                or "These figures are already included in compute_estimate.",
        }
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
