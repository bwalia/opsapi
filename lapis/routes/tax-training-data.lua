--[[
    Training Data / RAG Routes

    POST /api/v2/training-data/process-pending  — Batch embed pending rows (≤50)
    POST /api/v2/training-data/reembed-all      — Admin: wipe + regenerate all embeddings
    GET  /api/v2/training-data/stats             — Counts and coverage stats
    GET  /api/v2/training-data/search-similar    — Similarity search by description
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")

local function isAdmin(user)
    if not user then return false end
    local roles = user.roles or ""
    if type(roles) == "string" then
        return roles:match("admin") ~= nil or roles:match("tax_admin") ~= nil
    end
    if type(roles) == "table" then
        for _, r in ipairs(roles) do
            local name = r.role_name or r
            if name == "administrative" or name == "tax_admin" then return true end
        end
    end
    -- DB fallback
    local user_uuid = user.uuid or user.id
    local rows = db.query([[
        SELECT r.name FROM roles r
        JOIN user__roles ur ON ur.role_id = r.id
        JOIN users u ON u.id = ur.user_id
        WHERE u.uuid = ? AND r.name IN ('administrative', 'tax_admin')
        LIMIT 1
    ]], user_uuid)
    return rows and #rows > 0
end

return function(app)

    -- POST /api/v2/training-data/process-pending
    app:post("/api/v2/training-data/process-pending",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local ok_q, TrainingDataQueries = pcall(require, "queries.TrainingDataQueries")
            if not ok_q then
                return { status = 500, json = { error = "TrainingDataQueries not available" } }
            end

            local ok_llm, LLMClient = pcall(require, "lib.llm-client")
            if not ok_llm then
                return { status = 500, json = { error = "LLM client not available" } }
            end

            local provider = self.params.provider
            local batch_size = math.min(tonumber(self.params.batch_size) or 50, 50)

            -- Process training data
            local pending = TrainingDataQueries.getPending(batch_size)
            local processed = 0
            local errors = 0

            for _, row in ipairs(pending) do
                local text = row.original_description or row.description or ""
                if #text > 0 then
                    local result, err = LLMClient.generate_embedding({
                        text = text,
                        provider = provider,
                    })
                    if result and result.embedding then
                        TrainingDataQueries.updateEmbedding(row.id, result.embedding)
                        processed = processed + 1
                    else
                        errors = errors + 1
                        ngx.log(ngx.WARN, "[TrainingData] Embedding failed for id=", row.id, ": ", tostring(err))
                    end
                end
            end

            -- Also process reference data
            local ref_pending = TrainingDataQueries.getPendingReference(batch_size)
            local ref_processed = 0

            for _, row in ipairs(ref_pending) do
                local text = row.description or row.description_raw or ""
                if #text > 0 then
                    local result, err = LLMClient.generate_embedding({
                        text = text,
                        provider = provider,
                    })
                    if result and result.embedding then
                        TrainingDataQueries.updateReferenceEmbedding(row.id, result.embedding)
                        ref_processed = ref_processed + 1
                    end
                end
            end

            return {
                status = 200,
                json = {
                    message = "Processing complete",
                    training_processed = processed,
                    training_errors = errors,
                    training_pending_remaining = #pending - processed,
                    reference_processed = ref_processed,
                }
            }
        end)
    )

    -- POST /api/v2/training-data/reembed-all
    app:post("/api/v2/training-data/reembed-all",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local ok_q, TrainingDataQueries = pcall(require, "queries.TrainingDataQueries")
            if not ok_q then
                return { status = 500, json = { error = "TrainingDataQueries not available" } }
            end

            -- Wipe all embeddings
            TrainingDataQueries.deleteAllEmbeddings()
            TrainingDataQueries.deleteAllReferenceEmbeddings()

            local stats = TrainingDataQueries.getStats()

            return {
                status = 200,
                json = {
                    message = "All embeddings cleared. Run process-pending to regenerate.",
                    training_to_process = stats.training and stats.training.total or 0,
                    reference_to_process = stats.reference and stats.reference.total or 0,
                }
            }
        end)
    )

    -- GET /api/v2/training-data/stats
    app:get("/api/v2/training-data/stats",
        AuthMiddleware.requireAuth(function(self)
            if not isAdmin(self.current_user) then
                return { status = 403, json = { error = "Admin access required" } }
            end

            local ok_q, TrainingDataQueries = pcall(require, "queries.TrainingDataQueries")
            if not ok_q then
                return { status = 500, json = { error = "TrainingDataQueries not available" } }
            end

            return { status = 200, json = { data = TrainingDataQueries.getStats() } }
        end)
    )

    -- GET /api/v2/training-data/search-similar
    app:get("/api/v2/training-data/search-similar",
        AuthMiddleware.requireAuth(function(self)
            local description = self.params.description
            if not description or #description == 0 then
                return { status = 400, json = { error = "description parameter is required" } }
            end

            local limit = tonumber(self.params.limit) or 5
            local threshold = tonumber(self.params.threshold) or 0.7

            local ok_llm, LLMClient = pcall(require, "lib.llm-client")
            if not ok_llm then
                return { status = 500, json = { error = "LLM client not available" } }
            end

            local ok_q, TrainingDataQueries = pcall(require, "queries.TrainingDataQueries")
            if not ok_q then
                return { status = 500, json = { error = "TrainingDataQueries not available" } }
            end

            -- Generate embedding for the search query
            local emb_result, emb_err = LLMClient.generate_embedding({
                text = description,
                provider = self.params.provider,
            })

            if not emb_result or not emb_result.embedding then
                return { status = 422, json = { error = "Failed to generate embedding: " .. tostring(emb_err) } }
            end

            local results = TrainingDataQueries.searchSimilar(emb_result.embedding, limit, threshold)

            return {
                status = 200,
                json = {
                    data = results,
                    query = description,
                    total = #results,
                }
            }
        end)
    )
end
