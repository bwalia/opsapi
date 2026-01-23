--[[
    Bank Transactions Routes

    All endpoints require authentication.
    Users can only access their own transactions.
]]

local BankTransactionQueries = require "queries.BankTransactionQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- List all transactions for the current user (with pagination)
    app:get("/api/v2/bank-transactions", AuthMiddleware.requireAuth(function(self)
        local user_id = self.current_user.uuid
        local transactions = BankTransactionQueries.all(self.params, user_id)
        return {
            json = transactions,
            status = 200
        }
    end))

    -- Create a new transaction
    app:post("/api/v2/bank-transactions", AuthMiddleware.requireAuth(function(self)
        local user_id = self.current_user.uuid

        if not self.params.transaction_date then
            return {
                json = { error = "transaction_date is required" },
                status = 400
            }
        end

        if not self.params.description then
            return {
                json = { error = "description is required" },
                status = 400
            }
        end

        if not self.params.balance then
            return {
                json = { error = "balance is required" },
                status = 400
            }
        end

        local transaction = BankTransactionQueries.create(self.params, user_id)
        return {
            json = transaction,
            status = 201
        }
    end))

    -- Get a single transaction by UUID
    app:get("/api/v2/bank-transactions/:id", AuthMiddleware.requireAuth(function(self)
        local user_id = self.current_user.uuid
        local transaction = BankTransactionQueries.show(tostring(self.params.id), user_id)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = transaction,
            status = 200
        }
    end))

    -- Update a transaction
    app:put("/api/v2/bank-transactions/:id", AuthMiddleware.requireAuth(function(self)
        local user_id = self.current_user.uuid

        if not self.params.id then
            return {
                json = { error = "Transaction ID is required" },
                status = 400
            }
        end

        local transaction = BankTransactionQueries.update(tostring(self.params.id), self.params, user_id)

        if not transaction then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = transaction,
            status = 200
        }
    end))

    -- Delete a transaction
    app:delete("/api/v2/bank-transactions/:id", AuthMiddleware.requireAuth(function(self)
        local user_id = self.current_user.uuid
        local deleted = BankTransactionQueries.destroy(tostring(self.params.id), user_id)

        if not deleted then
            return {
                json = { error = "Transaction not found" },
                status = 404
            }
        end

        return {
            json = { message = "Transaction deleted successfully" },
            status = 200
        }
    end))
end
