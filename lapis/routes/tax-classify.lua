--[[
    Tax Classification Routes

    Endpoints for AI-powered transaction classification.

    GET  /api/v2/tax/classify/providers — List available LLM providers
    POST /api/v2/tax/classify           — Classify all transactions in a statement
    POST /api/v2/tax/classify/test      — Debug: classify a single transaction
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

    -- GET /api/v2/tax/classify/providers — list available LLM providers
    app:get("/api/v2/tax/classify/providers",
        AuthMiddleware.requireAuth(function(self)
            local ok, LLMClient = pcall(require, "lib.llm-client")
            if not ok then
                return { status = 500, json = { error = "LLM client not available" } }
            end
            return { status = 200, json = { data = LLMClient.get_providers() } }
        end)
    )

    -- POST /api/v2/tax/classify — classify all transactions for a statement
    app:post("/api/v2/tax/classify",
        RateLimit.wrap({ rate = 5, window = 60, prefix = "classify" },
            AuthMiddleware.requireAuth(function(self)
                local statement_id = self.params.statement_id
                local profile_type = self.params.profile_type or "sole_trader"
                local llm_provider = self.params.llm_provider

                if not statement_id then
                    return { status = 400, json = { error = "statement_id is required" } }
                end

                local user_id = getUserId(self.current_user)
                if not user_id then
                    return { status = 401, json = { error = "User not found" } }
                end

                -- Verify statement ownership and workflow state
                local statements = db.select(
                    "* FROM tax_statements WHERE id = ? AND user_id = ? LIMIT 1",
                    statement_id, user_id
                )
                if #statements == 0 then
                    return { status = 404, json = { error = "Statement not found" } }
                end

                local stmt = statements[1]
                if stmt.workflow_step == "FILED" then
                    return { status = 409, json = { error = "Cannot reclassify a filed statement" } }
                end

                -- Get unclassified transactions
                local transactions = db.select(
                    "* FROM tax_transactions WHERE statement_id = ? AND (classification_status = 'PENDING' OR classification_status IS NULL) ORDER BY id",
                    statement_id
                )

                if #transactions == 0 then
                    return {
                        status = 200,
                        json = { message = "No transactions to classify", classified = 0, total = 0 }
                    }
                end

                -- Update statement to classifying status
                db.update("tax_statements", {
                    processing_status = "CLASSIFYING",
                    updated_at = db.raw("NOW()"),
                }, { id = statement_id })

                -- Start Langfuse trace
                local langfuse = pcall(require, "lib.langfuse") and require("lib.langfuse") or nil
                local trace_id = langfuse and langfuse.trace_start("classify_statement", {
                    statement_id = statement_id,
                    profile_type = profile_type,
                    llm_provider = llm_provider,
                    transaction_count = #transactions,
                })

                -- Run classification pipeline
                local ok_cls, Classifier = pcall(require, "lib.tax-classifier")
                if not ok_cls then
                    db.update("tax_statements", { processing_status = "ERROR", updated_at = db.raw("NOW()") }, { id = statement_id })
                    return { status = 500, json = { error = "Classifier not available" } }
                end

                local results = Classifier.classify_batch(transactions, {
                    profile_type = profile_type,
                    llm_provider = llm_provider,
                    trace_id = trace_id,
                })

                -- Update transactions with classification results
                local classified_count = 0
                local low_confidence_count = 0

                for i, txn in ipairs(transactions) do
                    local cls = results[i]
                    if cls then
                        local updates = {
                            category = cls.category,
                            hmrc_category = cls.hmrc_category,
                            confidence_score = cls.confidence,
                            is_tax_deductible = cls.is_tax_deductible,
                            classification_status = "CLASSIFIED",
                            classified_by = cls.classified_by or "ai",
                            ai_reasoning = cls.reasoning,
                            updated_at = db.raw("NOW()"),
                        }

                        if cls.confidence and cls.confidence < 0.7 then
                            updates.classification_status = "NEEDS_REVIEW"
                            low_confidence_count = low_confidence_count + 1
                        end

                        db.update("tax_transactions", updates, { id = txn.id })
                        classified_count = classified_count + 1
                    end
                end

                -- Advance workflow
                db.update("tax_statements", {
                    workflow_step = "CLASSIFIED",
                    processing_status = "COMPLETED",
                    updated_at = db.raw("NOW()"),
                }, { id = statement_id })

                -- Audit log
                pcall(function()
                    db.insert("tax_audit_logs", {
                        uuid = Global.generateStaticUUID(),
                        entity_type = "STATEMENT",
                        entity_id = stmt.uuid or tostring(statement_id),
                        action = "CLASSIFY",
                        user_id = user_id,
                        new_values = cjson.encode({
                            classified = classified_count,
                            low_confidence = low_confidence_count,
                            profile_type = profile_type,
                            llm_provider = llm_provider or "default",
                        }),
                        created_at = db.raw("NOW()"),
                    })
                end)

                return {
                    status = 200,
                    json = {
                        message = "Classification complete",
                        classified = classified_count,
                        low_confidence = low_confidence_count,
                        total = #transactions,
                        profile_type = profile_type,
                    }
                }
            end)
        )
    )

    -- POST /api/v2/tax/classify/test — classify a single transaction (debug)
    app:post("/api/v2/tax/classify/test",
        RateLimit.wrap({ rate = 10, window = 60, prefix = "classify:test" },
            AuthMiddleware.requireAuth(function(self)
                local description = self.params.description
                local amount = tonumber(self.params.amount) or 0
                local transaction_type = self.params.transaction_type or "DEBIT"
                local profile_type = self.params.profile_type or "sole_trader"
                local llm_provider = self.params.llm_provider

                if not description then
                    return { status = 400, json = { error = "description is required" } }
                end

                local ok_cls, Classifier = pcall(require, "lib.tax-classifier")
                if not ok_cls then
                    return { status = 500, json = { error = "Classifier not available" } }
                end

                local langfuse = pcall(require, "lib.langfuse") and require("lib.langfuse") or nil
                local trace_id = langfuse and langfuse.trace_start("classify_test", {
                    description = description,
                    profile_type = profile_type,
                })

                local result = Classifier.classify_transaction(
                    { description = description, amount = amount, transaction_type = transaction_type },
                    { profile_type = profile_type, llm_provider = llm_provider, trace_id = trace_id }
                )

                return { status = 200, json = { data = result } }
            end)
        )
    )
end
