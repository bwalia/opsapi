--[[
    Tax Bank Account Routes

    CRUD endpoints for tax bank accounts.
    All endpoints require authentication.
    Users can only access their own bank accounts.
]]

local cjson = require("cjson")
local TaxBankAccountQueries = require "queries.TaxBankAccountQueries"
local AuthMiddleware = require("middleware.auth")

-- Valid account types (lowercase and uppercase accepted)
local VALID_ACCOUNT_TYPES = {
    current = true, savings = true, business = true,
    CURRENT = true, SAVINGS = true, BUSINESS = true,
}

-- Valid currencies
local VALID_CURRENCIES = { GBP = true, EUR = true, USD = true }

-- Validate bank account input fields
local function validate_bank_account_params(params, is_create)
    -- bank_name: required on create, 1-100 chars
    if is_create then
        if not params.bank_name or type(params.bank_name) ~= "string" or params.bank_name:match("^%s*$") then
            return false, "bank_name is required and must not be empty"
        end
    end
    if params.bank_name then
        if type(params.bank_name) ~= "string" or #params.bank_name > 100 or params.bank_name:match("^%s*$") then
            return false, "bank_name must be a non-empty string (max 100 characters)"
        end
        params.bank_name = params.bank_name:match("^%s*(.-)%s*$")  -- trim
    end

    -- account_name: optional on create, 1-100 chars
    if params.account_name then
        if type(params.account_name) ~= "string" or #params.account_name > 100 then
            return false, "account_name must be a string (max 100 characters)"
        end
        params.account_name = params.account_name:match("^%s*(.-)%s*$")  -- trim
    end

    -- account_number: optional, 6-20 digits only
    if params.account_number and params.account_number ~= "" then
        local trimmed = params.account_number:match("^%s*(.-)%s*$")
        if not trimmed:match("^%d+$") or #trimmed < 6 or #trimmed > 20 then
            return false, "account_number must be 6-20 digits (numbers only)"
        end
        params.account_number = trimmed
    end

    -- sort_code: optional, must be XX-XX-XX format
    if params.sort_code and params.sort_code ~= "" then
        local trimmed = params.sort_code:match("^%s*(.-)%s*$")
        if not trimmed:match("^%d%d%-%d%d%-%d%d$") then
            return false, "sort_code must be in XX-XX-XX format (e.g. 20-00-00)"
        end
        params.sort_code = trimmed
    end

    -- account_type: must be a valid type
    if params.account_type then
        if not VALID_ACCOUNT_TYPES[params.account_type] then
            return false, "account_type must be one of: current, savings, business"
        end
    end

    -- currency: must be a valid currency
    if params.currency then
        local upper_currency = params.currency:upper()
        if not VALID_CURRENCIES[upper_currency] then
            return false, "currency must be one of: GBP, EUR, USD"
        end
        params.currency = upper_currency
    end

    return true
end

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

        local valid, validation_err = validate_bank_account_params(self.params, true)
        if not valid then
            return {
                json = { error = validation_err },
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

        local valid, validation_err = validate_bank_account_params(self.params, false)
        if not valid then
            return {
                json = { error = validation_err },
                status = 400
            }
        end

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
