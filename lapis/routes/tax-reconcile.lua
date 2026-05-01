--[[
    Tax Reconciliation Routes

    Balance validation and HMRC SA103F box aggregation.

    POST /api/v2/tax/reconcile               — Run reconciliation for a statement
    GET  /api/v2/tax/reconcile/:statement_id  — Get reconciliation summary
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local Global = require("helper.global")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

--- Perform reconciliation for a statement
local function reconcile(statement_id, user_id)
    -- Fetch statement
    local statements = db.select(
        "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
        statement_id, user_id
    )
    if #statements == 0 then return nil, "Statement not found" end
    local stmt = statements[1]

    -- Balance check
    local balance_agg = db.query([[
        SELECT
            COALESCE(SUM(CASE WHEN transaction_type = 'CREDIT' THEN amount ELSE 0 END), 0) as total_credits,
            COALESCE(SUM(CASE WHEN transaction_type = 'DEBIT' THEN amount ELSE 0 END), 0) as total_debits,
            COUNT(*) as total_transactions,
            COUNT(*) FILTER (WHERE classification_status = 'PENDING' OR classification_status IS NULL) as unclassified,
            COUNT(*) FILTER (WHERE confidence_score IS NOT NULL AND confidence_score < 0.7) as low_confidence
        FROM tax_transactions WHERE statement_id = ?
    ]], statement_id)

    local agg = balance_agg[1] or {}
    local total_credits = tonumber(agg.total_credits) or 0
    local total_debits = tonumber(agg.total_debits) or 0
    local total_transactions = tonumber(agg.total_transactions) or 0
    local unclassified = tonumber(agg.unclassified) or 0
    local low_confidence = tonumber(agg.low_confidence) or 0

    local opening = tonumber(stmt.opening_balance) or 0
    local closing = tonumber(stmt.closing_balance) or 0
    local computed_closing = opening + total_credits - total_debits
    local discrepancy = math.abs(computed_closing - closing)

    local balance_ok = discrepancy < 0.02 -- 1p tolerance (rounding)

    -- Data quality gate
    local unclassified_pct = total_transactions > 0 and (unclassified / total_transactions * 100) or 0
    local quality_ok = unclassified_pct <= 10

    -- HMRC SA103F box aggregation
    local hmrc_boxes_raw = db.query([[
        SELECT
            COALESCE(t.hmrc_category, hc.key, 'otherExpenses') as hmrc_key,
            hc.label as hmrc_label,
            hc.box_number,
            SUM(t.amount) as total_amount,
            COUNT(*) as transaction_count,
            t.transaction_type
        FROM tax_transactions t
        LEFT JOIN tax_hmrc_categories hc ON hc.key = t.hmrc_category
        WHERE t.statement_id = ?
        AND t.classification_status != 'PENDING'
        GROUP BY COALESCE(t.hmrc_category, hc.key, 'otherExpenses'), hc.label, hc.box_number, t.transaction_type
        ORDER BY hc.box_number, hmrc_key
    ]], statement_id)

    -- Organize by HMRC box
    local hmrc_boxes = {}
    local total_income = 0
    local total_expenses = 0

    for _, row in ipairs(hmrc_boxes_raw or {}) do
        local key = row.hmrc_key or "otherExpenses"
        if not hmrc_boxes[key] then
            hmrc_boxes[key] = {
                key = key,
                label = row.hmrc_label or key,
                box_number = row.box_number,
                debit_total = 0,
                credit_total = 0,
                transaction_count = 0,
            }
        end
        local amount = tonumber(row.total_amount) or 0
        local count = tonumber(row.transaction_count) or 0
        hmrc_boxes[key].transaction_count = hmrc_boxes[key].transaction_count + count

        if row.transaction_type == "DEBIT" then
            hmrc_boxes[key].debit_total = hmrc_boxes[key].debit_total + amount
            total_expenses = total_expenses + amount
        else
            hmrc_boxes[key].credit_total = hmrc_boxes[key].credit_total + amount
            total_income = total_income + amount
        end
    end

    -- Convert to array sorted by box number
    local boxes_array = {}
    for _, box in pairs(hmrc_boxes) do
        table.insert(boxes_array, box)
    end
    table.sort(boxes_array, function(a, b)
        return (a.box_number or 99) < (b.box_number or 99)
    end)

    return {
        statement_id = statement_id,
        balance_check = {
            opening_balance = opening,
            closing_balance = closing,
            computed_closing = computed_closing,
            total_credits = total_credits,
            total_debits = total_debits,
            discrepancy = discrepancy,
            balanced = balance_ok,
        },
        data_quality = {
            total_transactions = total_transactions,
            unclassified = unclassified,
            unclassified_pct = math.floor(unclassified_pct * 100) / 100,
            low_confidence = low_confidence,
            quality_ok = quality_ok,
        },
        hmrc_boxes = boxes_array,
        totals = {
            income = total_income,
            expenses = total_expenses,
            net_profit = total_income - total_expenses,
        },
        can_proceed = balance_ok and quality_ok,
    }, nil
end

return function(app)

    -- POST /api/v2/tax/reconcile
    app:post("/api/v2/tax/reconcile",
        AuthMiddleware.requireAuth(function(self)
            local statement_id = self.params.statement_id
            if not statement_id then
                return { status = 400, json = { error = "statement_id is required" } }
            end

            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local result, err = reconcile(statement_id, user_id)
            if not result then
                return { status = 404, json = { error = err } }
            end

            -- Advance workflow if reconciliation passes
            if result.can_proceed then
                db.update("tax_statements", {
                    workflow_step = "RECONCILED",
                    total_income = result.totals.income,
                    total_expenses = result.totals.expenses,
                    updated_at = db.raw("NOW()"),
                }, { id = statement_id })

                -- Audit log
                pcall(function()
                    db.insert("tax_audit_logs", {
                        uuid = Global.generateStaticUUID(),
                        entity_type = "STATEMENT",
                        entity_id = tostring(statement_id),
                        action = "RECONCILE",
                        user_id = user_id,
                        new_values = cjson.encode({
                            balanced = result.balance_check.balanced,
                            income = result.totals.income,
                            expenses = result.totals.expenses,
                        }),
                        created_at = db.raw("NOW()"),
                    })
                end)
            end

            return { status = 200, json = { data = result } }
        end)
    )

    -- GET /api/v2/tax/reconcile/:statement_id
    app:get("/api/v2/tax/reconcile/:statement_id",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local result, err = reconcile(self.params.statement_id, user_id)
            if not result then
                return { status = 404, json = { error = err } }
            end

            return { status = 200, json = { data = result } }
        end)
    )
end
