--[[
    Tax Calculation Routes

    UK self-assessment tax calculation, per TAX YEAR.

    GET  /api/v2/tax/calculate/year-statements     — List statements by tax year
    GET  /api/v2/tax/calculate/:statement_id        — Calculation for the statement's tax year
    POST /api/v2/tax/calculate/multi                — Calculation for the tax year of a set of statements
    GET  /api/v2/tax/calculate/summary/:statement_id — Formatted summary for the statement's tax year

    Tax is a yearly figure, so every calculation covers ALL the user's statements in the
    tax year (the statement only picks the year). The figures come from
    lib/agent/tax-tools (TaxTools.compute_year → lib/tax-calc compute_full) — the same
    function the chat estimate, the reports tax calculation and the filing workbook use,
    so they can never disagree.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local Global = require("helper.global")
local TaxCalc = require("lib.tax-calc")
local TaxTools = require("lib.agent.tax-tools")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

local function getTaxYearDates(tax_year_str)
    local start_year = tonumber(tax_year_str:sub(1, 4))
    if not start_year then return nil, nil end
    return string.format("%d-04-06", start_year), string.format("%d-04-05", start_year + 1)
end

local function validTaxYear(y)
    return type(y) == "string" and y:match("^%d%d%d%d%-%d%d$") ~= nil
end

--- The user's statement by numeric id, or nil.
local function findStatement(statement_id, user_id)
    if not tostring(statement_id or ""):match("^%d+$") then return nil end
    local rows = db.select("* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
        tonumber(statement_id), user_id)
    return rows and rows[1]
end

--- The tax year a statement belongs to. Uses the stamped tax_year; otherwise derives it
-- from the statement period (end, then start) or its latest transaction, and stamps it —
-- the year calculation only counts statements stamped with that year (as the tax agent's
-- background processing does).
local function statementYear(stmt)
    if validTaxYear(stmt.tax_year) then return stmt.tax_year end
    local year = TaxCalc.tax_year_for_date(stmt.period_end) or TaxCalc.tax_year_for_date(stmt.period_start)
    if not year then
        local last = db.query("SELECT MAX(transaction_date)::text AS d FROM tax_transactions WHERE statement_id = ?",
            stmt.id)
        year = TaxCalc.tax_year_for_date(last and last[1] and last[1].d)
    end
    if year then
        db.query([[UPDATE tax_statements SET tax_year = ?
            WHERE id = ? AND (tax_year IS NULL OR tax_year = '')]], year, stmt.id)
        stmt.tax_year = year
    end
    return year
end

local function computeYear(user_id, tax_year)
    return TaxTools.compute_year(user_id, tax_year, TaxTools.profile_for(user_id, tax_year))
end

return function(app)

    -- GET /api/v2/tax/calculate/year-statements
    app:get("/api/v2/tax/calculate/year-statements",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local tax_year = self.params.tax_year or TaxCalc.current_tax_year()
            local start_date, end_date = getTaxYearDates(tax_year)
            if not start_date then
                return { status = 400, json = { error = "Invalid tax year format (e.g. 2025-26)" } }
            end

            local statements = db.select([[
                * FROM tax_statements
                WHERE user_id = ? AND (
                    (period_start >= ? AND period_start <= ?) OR
                    (period_end >= ? AND period_end <= ?) OR
                    tax_year = ?
                )
                ORDER BY period_start ASC
            ]], user_id, start_date, end_date, start_date, end_date, tax_year)

            return {
                status = 200,
                json = {
                    data = statements,
                    tax_year = tax_year,
                    total = #statements,
                }
            }
        end)
    )

    -- GET /api/v2/tax/calculate/:statement_id — the calculation for the statement's year
    app:get("/api/v2/tax/calculate/:statement_id",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local stmt = findStatement(self.params.statement_id, user_id)
            if not stmt then
                return { status = 404, json = { error = "Statement not found" } }
            end
            local tax_year = statementYear(stmt)
            if not tax_year then
                return { status = 422, json = { error = "Can't tell which tax year this statement is for" } }
            end

            local calculation = computeYear(user_id, tax_year)
            calculation.statement_id = stmt.id

            return { status = 200, json = { data = calculation } }
        end)
    )

    -- POST /api/v2/tax/calculate/multi — the calculation for the statements' tax year
    app:post("/api/v2/tax/calculate/multi",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            -- Lapis only parses form bodies into self.params; read a JSON body too.
            local body = {}
            pcall(function()
                ngx.req.read_body()
                local raw = ngx.req.get_body_data()
                if raw and raw ~= "" then
                    local decoded = cjson.decode(raw)
                    if type(decoded) == "table" then body = decoded end
                end
            end)

            local statement_ids = body.statement_ids or self.params.statement_ids
            if not statement_ids or type(statement_ids) ~= "table" or #statement_ids == 0 then
                return { status = 400, json = { error = "statement_ids array is required" } }
            end

            local requested_year = body.tax_year or self.params.tax_year
            if requested_year ~= nil and requested_year ~= "" and not validTaxYear(requested_year) then
                return { status = 400, json = { error = "Invalid tax year format (e.g. 2025-26)" } }
            end
            if requested_year == "" then requested_year = nil end

            -- Every statement must be the caller's, and all must be in ONE tax year.
            local statements, tax_year = {}, requested_year
            for _, sid in ipairs(statement_ids) do
                if not tostring(sid):match("^%d+$") then
                    return { status = 400, json = { error = "statement_ids must be numeric ids" } }
                end
                local stmt = findStatement(sid, user_id)
                if not stmt then
                    return { status = 403, json = { error = "Some statements not found or not owned by user" } }
                end
                local year = validTaxYear(stmt.tax_year) and stmt.tax_year or nil
                if not year and not requested_year then year = statementYear(stmt) end
                if year then
                    tax_year = tax_year or year
                    if year ~= tax_year then
                        return { status = 400, json = {
                            error = "Statements span more than one tax year (" .. tax_year .. ", " .. year
                                .. "). Tax is calculated per year — choose statements from one year.",
                        } }
                    end
                end
                statements[#statements + 1] = stmt
            end
            if not tax_year then
                return { status = 422, json = { error = "Can't tell which tax year these statements are for" } }
            end

            -- Unstamped statements join the chosen year (only when not already set).
            for _, stmt in ipairs(statements) do
                db.query([[UPDATE tax_statements SET tax_year = ?
                    WHERE id = ? AND (tax_year IS NULL OR tax_year = '')]], tax_year, stmt.id)
            end

            local calculation = computeYear(user_id, tax_year)
            local ids = {}
            for i, stmt in ipairs(statements) do ids[i] = stmt.id end
            calculation.statement_ids = ids

            -- Advance workflow for all included statements
            for _, stmt in ipairs(statements) do
                db.update("tax_statements", {
                    workflow_step = "TAX_CALCULATED",
                    updated_at = db.raw("NOW()"),
                }, { id = stmt.id, user_id = user_id })
            end

            -- Upsert tax_returns record
            local existing = db.query(
                "SELECT id FROM tax_returns WHERE user_id = ? AND tax_year = ? LIMIT 1",
                user_id, tax_year
            )

            local return_data = {
                user_id = user_id,
                tax_year = tax_year,
                trading_income = calculation.gross_income,
                total_income = calculation.gross_income,
                total_expenses = calculation.total_expenses,
                trading_profit = calculation.trading_profit,
                personal_allowance = calculation.personal_allowance,
                taxable_income = calculation.taxable_income,
                income_tax = calculation.income_tax.total,
                national_insurance = calculation.national_insurance.total,
                total_tax_due = calculation.total_tax_due,
                status = "DRAFT",
                updated_at = db.raw("NOW()"),
            }

            if existing and #existing > 0 then
                db.update("tax_returns", return_data, { id = existing[1].id })
            else
                return_data.uuid = Global.generateStaticUUID()
                return_data.created_at = db.raw("NOW()")
                db.insert("tax_returns", return_data)
            end

            return { status = 200, json = { data = calculation } }
        end)
    )

    -- GET /api/v2/tax/calculate/summary/:statement_id — summary for the statement's year
    app:get("/api/v2/tax/calculate/summary/:statement_id",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local stmt = findStatement(self.params.statement_id, user_id)
            if not stmt then
                return { status = 404, json = { error = "Statement not found" } }
            end
            local tax_year = statementYear(stmt)
            if not tax_year then
                return { status = 422, json = { error = "Can't tell which tax year this statement is for" } }
            end

            local calc = computeYear(user_id, tax_year)

            -- Category breakdown for the same year, so it adds up to the calculation.
            local categories = db.query([[
                SELECT t.category, t.hmrc_category,
                    SUM(t.amount) as total,
                    COUNT(*) as count,
                    t.transaction_type
                FROM tax_transactions t JOIN tax_statements s ON s.id = t.statement_id
                WHERE t.user_id = ? AND s.tax_year = ? AND t.classification_status != 'PENDING'
                GROUP BY t.category, t.hmrc_category, t.transaction_type
                ORDER BY total DESC
            ]], user_id, tax_year)

            return {
                status = 200,
                json = {
                    tax_year = tax_year,
                    statement = {
                        id = stmt.id,
                        bank_name = stmt.bank_name,
                        period_start = stmt.period_start,
                        period_end = stmt.period_end,
                        workflow_step = stmt.workflow_step,
                    },
                    calculation = calc,
                    categories = categories,
                }
            }
        end)
    )
end
