--[[
    Tax Statement Routes

    CRUD endpoints for tax statements.
    All endpoints require authentication.
    Users can only access their own statements.
]]

local cjson = require("cjson")
local TaxStatementQueries = require "queries.TaxStatementQueries"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
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
    -- List all statements for the current user
    app:get("/api/v2/tax/statements", AuthMiddleware.requireAuth(function(self)
        local statements = TaxStatementQueries.all(self.params, self.current_user)
        return {
            json = statements,
            status = 200
        }
    end))

    -- Create a new statement (file upload metadata)
    app:post("/api/v2/tax/statements", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.bank_account_id and not self.params.bank_account_uuid then
            return {
                json = { error = "bank_account_id is required" },
                status = 400
            }
        end

        -- Use bank_account_uuid if provided, otherwise bank_account_id
        self.params.bank_account_uuid = self.params.bank_account_uuid or self.params.bank_account_id

        local result, err = TaxStatementQueries.create(self.params, self.current_user)

        if not result then
            return {
                json = { error = err or "Failed to create statement" },
                status = 400
            }
        end

        return {
            json = result,
            status = 201
        }
    end))

    -- Get a single statement
    app:get("/api/v2/tax/statements/:id", AuthMiddleware.requireAuth(function(self)
        local statement = TaxStatementQueries.show(tostring(self.params.id), self.current_user)

        if not statement then
            return {
                json = { error = "Statement not found" },
                status = 404
            }
        end

        return {
            json = { data = statement },
            status = 200
        }
    end))

    -- Update a statement (metadata, status, workflow, etc.)
    app:put("/api/v2/tax/statements/:id", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        local statement = TaxStatementQueries.update(tostring(self.params.id), self.params, self.current_user)

        if not statement then
            return {
                json = { error = "Statement not found" },
                status = 404
            }
        end

        return {
            json = { data = statement },
            status = 200
        }
    end))

    -- Update statement workflow step only
    app:patch("/api/v2/tax/statements/:id/workflow", AuthMiddleware.requireAuth(function(self)
        merge_params(self)

        if not self.params.workflow_step then
            return {
                json = { error = "workflow_step is required" },
                status = 400
            }
        end

        local statement = TaxStatementQueries.update(tostring(self.params.id), {
            workflow_step = self.params.workflow_step
        }, self.current_user)

        if not statement then
            return {
                json = { error = "Statement not found" },
                status = 404
            }
        end

        return {
            json = { data = statement },
            status = 200
        }
    end))

    -- Delete a statement
    app:delete("/api/v2/tax/statements/:id", AuthMiddleware.requireAuth(function(self)
        local success = TaxStatementQueries.destroy(tostring(self.params.id), self.current_user)

        if not success then
            return {
                json = { error = "Statement not found" },
                status = 404
            }
        end

        return {
            json = { message = "Statement deleted successfully" },
            status = 200
        }
    end))

    -- Get audit trail for a statement
    app:get("/api/v2/tax/statements/:id/audit", AuthMiddleware.requireAuth(function(self)
        local statement = TaxStatementQueries.show(tostring(self.params.id), self.current_user)

        if not statement then
            return {
                json = { error = "Statement not found" },
                status = 404
            }
        end

        local audit_logs = TaxAuditLogQueries.getByStatement(tostring(self.params.id), self.params)
        return {
            json = audit_logs,
            status = 200
        }
    end))
end
