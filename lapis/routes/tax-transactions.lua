--[[
    Tax Transaction Routes

    CRUD endpoints for tax transactions.
    All endpoints require authentication.
    Users can only access their own transactions.
]]

local TaxTransactionQueries = require "queries.TaxTransactionQueries"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local AuthMiddleware = require("middleware.auth")
local cjson = require("cjson")

-- Parse request body (supports both JSON and form-urlencoded)
local function parse_request_body()
    ngx.req.read_body()

    -- Check content type to determine parsing method
    local content_type = ngx.var.content_type or ""

    -- If JSON content type, parse as JSON
    if content_type:find("application/json", 1, true) then
        local ok, result = pcall(function()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cjson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
        end
        return {}
    end

    -- Otherwise, try form params (application/x-www-form-urlencoded)
    local post_args = ngx.req.get_post_args()
    if post_args and next(post_args) then
        return post_args
    end

    return {}
end

-- Merge body params into self.params
local function merge_params(self)
    local body_params = parse_request_body()
    for k, v in pairs(body_params) do
        if self.params[k] == nil then
            self.params[k] = v
        end
    end
end

return function(app)
    -- List transactions for a statement
    app:get("/api/v2/tax/statements/:statement_id/transactions", AuthMiddleware.requireAuth(function(self)
        local transactions = TaxTransactionQueries.byStatement(
            tostring(self.params.statement_id),
            self.params,
            self.current_user
        )
        return {
            json = transactions,
            status = 200
        }
    end))

    -- Bulk create transactions (from AI extraction)
    app:post("/api/v2/tax/statements/:statement_id/transactions/bulk", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.transactions then
            return {
                json = { error = "transactions array is required" },
                status = 400
            }
        end

        local transactions = self.params.transactions
        if type(transactions) == "string" then
            local ok, parsed = pcall(cjson.decode, transactions)
            if not ok then
                return {
                    json = { error = "Invalid transactions JSON" },
                    status = 400
                }
            end
            transactions = parsed
        end

        local result, err = TaxTransactionQueries.bulkCreate(
            tostring(self.params.statement_id),
            transactions,
            self.current_user
        )

        if not result then
            return {
                json = { error = err or "Failed to create transactions" },
                status = 400
            }
        end

        return {
            json = result,
            status = 201
        }
    end))

    -- Bulk update classifications (from AI classification)
    app:post("/api/v2/tax/statements/:statement_id/transactions/classify", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.classifications then
            return {
                json = { error = "classifications array is required" },
                status = 400
            }
        end

        local classifications = self.params.classifications
        if type(classifications) == "string" then
            local ok, parsed = pcall(cjson.decode, classifications)
            if not ok then
                return {
                    json = { error = "Invalid classifications JSON" },
                    status = 400
                }
            end
            classifications = parsed
        end

        local result, err = TaxTransactionQueries.bulkUpdateClassification(
            tostring(self.params.statement_id),
            classifications,
            self.current_user
        )

        if not result then
            return {
                json = { error = err or "Failed to update classifications" },
                status = 400
            }
        end

        return {
            json = result,
            status = 200
        }
    end))

    -- Bulk confirm transactions
    app:post("/api/v2/tax/statements/:statement_id/transactions/bulk-confirm", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.transaction_ids then
            return {
                json = { error = "transaction_ids array is required" },
                status = 400
            }
        end

        local transaction_ids = self.params.transaction_ids
        if type(transaction_ids) == "string" then
            local ok, parsed = pcall(cjson.decode, transaction_ids)
            if ok then
                transaction_ids = parsed
            end
        end

        local result, err = TaxTransactionQueries.bulkConfirm(
            tostring(self.params.statement_id),
            transaction_ids,
            self.params,
            self.current_user
        )

        if not result then
            return {
                json = { error = err or "Failed to confirm transactions" },
                status = 400
            }
        end

        return {
            json = result,
            status = 200
        }
    end))

    -- Bulk confirm classifications
    app:post("/api/v2/tax/statements/:statement_id/transactions/bulk-confirm-classification", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.transaction_ids then
            return {
                json = { error = "transaction_ids array is required" },
                status = 400
            }
        end

        local transaction_ids = self.params.transaction_ids
        if type(transaction_ids) == "string" then
            local ok, parsed = pcall(cjson.decode, transaction_ids)
            if ok then
                transaction_ids = parsed
            end
        end

        local result, err = TaxTransactionQueries.bulkConfirmClassification(
            tostring(self.params.statement_id),
            transaction_ids,
            self.params,
            self.current_user
        )

        if not result then
            return {
                json = { error = err or "Failed to confirm classifications" },
                status = 400
            }
        end

        return {
            json = result,
            status = 200
        }
    end))

    -- Get a single transaction
    app:get("/api/v2/tax/transactions/:id", AuthMiddleware.requireAuth(function(self)
        local transaction = TaxTransactionQueries.show(tostring(self.params.id), self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = { data = transaction },
            status = 200
        }
    end))

    -- Update a transaction
    app:put("/api/v2/tax/transactions/:id", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        local transaction = TaxTransactionQueries.update(tostring(self.params.id), self.params, self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = { data = transaction },
            status = 200
        }
    end))

    -- PATCH update a transaction (same as PUT)
    app:match("/api/v2/tax/transactions/:id", { "PATCH" }, AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        local transaction = TaxTransactionQueries.update(tostring(self.params.id), self.params, self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = { data = transaction },
            status = 200
        }
    end))

    -- Confirm a single transaction
    app:post("/api/v2/tax/transactions/:id/confirm", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        local transaction = TaxTransactionQueries.confirm(tostring(self.params.id), self.params, self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = { data = transaction },
            status = 200
        }
    end))

    -- Confirm a single transaction classification
    app:post("/api/v2/tax/transactions/:id/confirm-classification", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        local transaction = TaxTransactionQueries.confirmClassification(tostring(self.params.id), self.params, self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = { data = transaction },
            status = 200
        }
    end))

    -- Get transaction history (audit trail)
    app:get("/api/v2/tax/transactions/:id/history", AuthMiddleware.requireAuth(function(self)
        local transaction = TaxTransactionQueries.show(tostring(self.params.id), self.current_user)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        local audit_logs = TaxAuditLogQueries.getByEntity("TRANSACTION", tostring(self.params.id), self.params)
        return {
            json = audit_logs,
            status = 200
        }
    end))
end
