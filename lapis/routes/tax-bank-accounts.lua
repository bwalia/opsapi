--[[
    Tax Bank Account Routes

    CRUD endpoints for tax bank accounts.
    All endpoints require authentication.
    Users can only access their own bank accounts.
]]

local cjson = require("cjson")
local TaxBankAccountQueries = require "queries.TaxBankAccountQueries"
local AuthMiddleware = require("middleware.auth")

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
    -- List all bank accounts for the current user
    app:get("/api/v2/tax/bank-accounts", AuthMiddleware.requireAuth(function(self)
        local accounts = TaxBankAccountQueries.all(self.params, self.current_user)
        return {
            json = accounts,
            status = 200
        }
    end))

    -- Create a new bank account
    app:post("/api/v2/tax/bank-accounts", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.bank_name then
            return {
                json = { error = "bank_name is required" },
                status = 400
            }
        end

        local result, err = TaxBankAccountQueries.create(self.params, self.current_user)

        if not result then
            return {
                json = { error = err or "Failed to create bank account" },
                status = 400
            }
        end

        return {
            json = result,
            status = 201
        }
    end))

    -- Get a single bank account
    app:get("/api/v2/tax/bank-accounts/:id", AuthMiddleware.requireAuth(function(self)
        local account = TaxBankAccountQueries.show(tostring(self.params.id), self.current_user)

        if not account then
            return {
                json = { error = "Bank account not found" },
                status = 404
            }
        end

        return {
            json = { data = account },
            status = 200
        }
    end))

    -- Update a bank account
    app:put("/api/v2/tax/bank-accounts/:id", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        local account = TaxBankAccountQueries.update(tostring(self.params.id), self.params, self.current_user)

        if not account then
            return {
                json = { error = "Bank account not found" },
                status = 404
            }
        end

        return {
            json = { data = account },
            status = 200
        }
    end))

    -- Delete a bank account
    app:delete("/api/v2/tax/bank-accounts/:id", AuthMiddleware.requireAuth(function(self)
        local success, action = TaxBankAccountQueries.destroy(tostring(self.params.id), self.current_user)

        if not success then
            return {
                json = { error = "Bank account not found" },
                status = 404
            }
        end

        return {
            json = {
                message = "Bank account " .. (action or "deleted") .. " successfully"
            },
            status = 200
        }
    end))
end
