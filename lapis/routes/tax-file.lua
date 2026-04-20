--[[
    Tax Filing Routes (HMRC MTD Submission)

    POST /api/v2/tax/file                          — Submit to HMRC MTD
    GET  /api/v2/tax/file/:statement_id/status      — Filing status
    GET  /api/v2/tax/file/:statement_id/check-duplicate — Duplicate detection
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local RateLimit = require("middleware.rate-limit")
local Global = require("helper.global")

local function getUserId(user)
    local user_uuid = user.uuid or user.id
    local rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    return rows and rows[1] and rows[1].id
end

return function(app)

    -- POST /api/v2/tax/file — submit to HMRC
    app:post("/api/v2/tax/file",
        RateLimit.wrap({ rate = 3, window = 60, prefix = "hmrc:file" },
            AuthMiddleware.requireAuth(function(self)
                local statement_id = self.params.statement_id
                local tax_year = self.params.tax_year
                local business_id = self.params.business_id

                if not statement_id then
                    return { status = 400, json = { error = "statement_id is required" } }
                end

                local user_id = getUserId(self.current_user)
                local user_uuid = self.current_user.uuid or self.current_user.id
                if not user_id then
                    return { status = 401, json = { error = "User not found" } }
                end

                -- Verify statement
                local statements = db.select(
                    "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                    statement_id, user_id
                )
                if #statements == 0 then
                    return { status = 404, json = { error = "Statement not found" } }
                end
                local stmt = statements[1]

                -- Check workflow — must be at least TAX_CALCULATED
                if stmt.workflow_step ~= "TAX_CALCULATED" and stmt.workflow_step ~= "RECONCILED" then
                    return { status = 409, json = {
                        error = "Statement must be at TAX_CALCULATED stage before filing",
                        current_step = stmt.workflow_step,
                    } }
                end

                if stmt.is_filed then
                    return { status = 409, json = { error = "Statement already filed" } }
                end

                tax_year = tax_year or stmt.tax_year

                -- Check for duplicates
                local ok_fq, TaxFilingQueries = pcall(require, "queries.TaxFilingQueries")
                if ok_fq and TaxFilingQueries.checkDuplicate(user_id, tax_year) then
                    return { status = 409, json = { error = "A return has already been filed for " .. tax_year } }
                end

                -- Get valid HMRC token
                local ok_hmrc, HMRC = pcall(require, "helper.hmrc")
                if not ok_hmrc then
                    return { status = 500, json = { error = "HMRC module not available" } }
                end

                local access_token, token_err = HMRC.get_valid_token(user_uuid)
                if not access_token then
                    return { status = 401, json = { error = token_err } }
                end

                -- Verify NINO
                local profile = db.select(
                    "* FROM tax_user_profiles WHERE user_id = ? LIMIT 1", user_id
                )
                if not profile or #profile == 0 or not profile[1].has_nino then
                    return { status = 400, json = { error = "NINO must be saved before filing" } }
                end

                -- Aggregate HMRC boxes
                local hmrc_agg = db.query([[
                    SELECT
                        COALESCE(hmrc_category, 'otherExpenses') as hmrc_key,
                        SUM(CASE WHEN transaction_type = 'DEBIT' THEN amount ELSE 0 END) as expense_total,
                        SUM(CASE WHEN transaction_type = 'CREDIT' THEN amount ELSE 0 END) as income_total
                    FROM tax_transactions
                    WHERE statement_id = ?
                    AND classification_status != 'PENDING'
                    GROUP BY COALESCE(hmrc_category, 'otherExpenses')
                ]], statement_id)

                local expenses = {}
                local total_income = 0
                for _, row in ipairs(hmrc_agg or {}) do
                    expenses[row.hmrc_key] = tonumber(row.expense_total) or 0
                    total_income = total_income + (tonumber(row.income_total) or 0)
                end

                -- Submit to HMRC
                local result, err, hmrc_response = HMRC.submit_self_assessment(access_token, {
                    turnover = total_income,
                    other_income = 0,
                    expenses = expenses,
                })

                if not result then
                    -- Audit the failed attempt
                    pcall(function()
                        db.insert("tax_audit_logs", {
                            uuid = Global.generateStaticUUID(),
                            entity_type = "FILING",
                            entity_id = stmt.uuid or tostring(statement_id),
                            action = "FILE_FAILED",
                            user_id = user_id,
                            new_values = cjson.encode({
                                error = err,
                                hmrc_response = hmrc_response,
                            }),
                            created_at = db.raw("NOW()"),
                        })
                    end)
                    return { status = 422, json = { error = err, hmrc_response = hmrc_response } }
                end

                -- Mark statement as filed
                db.update("tax_statements", {
                    is_filed = true,
                    filed_at = db.raw("NOW()"),
                    workflow_step = "FILED",
                    hmrc_submission_id = result.submission_id,
                    updated_at = db.raw("NOW()"),
                }, { id = statement_id })

                -- Update or create tax_returns record
                if ok_fq then
                    local existing = TaxFilingQueries.getByStatementId(statement_id)
                    if existing and #existing > 0 then
                        TaxFilingQueries.updateStatus(existing[1].id, "FILED", result.data)
                        db.update("tax_returns", {
                            hmrc_submission_id = result.submission_id,
                        }, { id = existing[1].id })
                    end
                end

                -- Audit log
                pcall(function()
                    db.insert("tax_audit_logs", {
                        uuid = Global.generateStaticUUID(),
                        entity_type = "FILING",
                        entity_id = stmt.uuid or tostring(statement_id),
                        action = "FILE_SUCCESS",
                        user_id = user_id,
                        new_values = cjson.encode({
                            submission_id = result.submission_id,
                            tax_year = tax_year,
                        }),
                        created_at = db.raw("NOW()"),
                    })
                end)

                return {
                    status = 200,
                    json = {
                        message = "Return filed successfully",
                        submission_id = result.submission_id,
                        tax_year = tax_year,
                    }
                }
            end)
        )
    )

    -- GET /api/v2/tax/file/:statement_id/status
    app:get("/api/v2/tax/file/:statement_id/status",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local statements = db.select(
                "id, uuid, is_filed, filed_at, hmrc_submission_id, workflow_step FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                self.params.statement_id, user_id
            )
            if #statements == 0 then
                return { status = 404, json = { error = "Statement not found" } }
            end

            local ok_fq, TaxFilingQueries = pcall(require, "queries.TaxFilingQueries")
            local tax_return = nil
            if ok_fq then
                local returns = TaxFilingQueries.getByStatementId(self.params.statement_id)
                if returns and #returns > 0 then tax_return = returns[1] end
            end

            return {
                status = 200,
                json = {
                    statement = statements[1],
                    tax_return = tax_return,
                }
            }
        end)
    )

    -- GET /api/v2/tax/file/:statement_id/check-duplicate
    app:get("/api/v2/tax/file/:statement_id/check-duplicate",
        AuthMiddleware.requireAuth(function(self)
            local user_id = getUserId(self.current_user)
            if not user_id then
                return { status = 401, json = { error = "User not found" } }
            end

            local statements = db.select(
                "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                self.params.statement_id, user_id
            )
            if #statements == 0 then
                return { status = 404, json = { error = "Statement not found" } }
            end

            local tax_year = statements[1].tax_year
            local ok_fq, TaxFilingQueries = pcall(require, "queries.TaxFilingQueries")
            local is_duplicate = false
            if ok_fq and tax_year then
                is_duplicate = TaxFilingQueries.checkDuplicate(user_id, tax_year)
            end

            return {
                status = 200,
                json = {
                    is_duplicate = is_duplicate,
                    tax_year = tax_year,
                    is_filed = statements[1].is_filed or false,
                }
            }
        end)
    )
end
