--[[
    CRM Accounts API Routes
    =======================

    RESTful API for CRM account (company/organization) management.

    Endpoints:
    - GET    /api/v2/crm/accounts          - List accounts
    - POST   /api/v2/crm/accounts          - Create account
    - GET    /api/v2/crm/accounts/:uuid     - Get account with stats
    - PUT    /api/v2/crm/accounts/:uuid     - Update account
    - DELETE /api/v2/crm/accounts/:uuid     - Soft delete account
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local CrmQueries = require("queries.CrmQueries")

return function(app)
    -- Helper to parse JSON body
    local function parse_json_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, data = pcall(cjson.decode, body)
        return ok and data or {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    -- GET /api/v2/crm/accounts - List accounts
    app:get("/api/v2/crm/accounts", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = CrmQueries.getAccounts(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                status = self.params.status,
                owner_user_uuid = self.params.owner,
                search = self.params.search
            })

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.items,
                    meta = result.meta
                }
            }
        end)
    ))

    -- POST /api/v2/crm/accounts - Create account
    app:post("/api/v2/crm/accounts", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.name or data.name == "" then
                return api_response(400, nil, "name is required")
            end

            local metadata = data.metadata
            if metadata and type(metadata) == "table" then
                metadata = cjson.encode(metadata)
            end

            local account = CrmQueries.createAccount({
                namespace_id = self.namespace.id,
                name = data.name,
                industry = data.industry,
                website = data.website,
                phone = data.phone,
                email = data.email,
                address_line1 = data.address_line1,
                address_line2 = data.address_line2,
                city = data.city,
                state = data.state,
                postal_code = data.postal_code,
                country = data.country,
                annual_revenue = data.annual_revenue,
                employee_count = data.employee_count,
                owner_user_uuid = data.owner_user_uuid or self.current_user.uuid,
                status = data.status or "active",
                metadata = metadata or "{}"
            })

            if not account then
                return api_response(500, nil, "Failed to create account")
            end

            return api_response(201, account)
        end)
    ))

    -- GET /api/v2/crm/accounts/:uuid - Get account with stats
    app:get("/api/v2/crm/accounts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local account = CrmQueries.getAccount(self.params.uuid)
            if not account then
                return api_response(404, nil, "Account not found")
            end

            if tonumber(account.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, account)
        end)
    ))

    -- PUT /api/v2/crm/accounts/:uuid - Update account
    app:put("/api/v2/crm/accounts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local account = CrmQueries.getAccount(self.params.uuid)
            if not account then
                return api_response(404, nil, "Account not found")
            end

            if tonumber(account.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = {
                "name", "industry", "website", "phone", "email",
                "address_line1", "address_line2", "city", "state",
                "postal_code", "country", "annual_revenue", "employee_count",
                "owner_user_uuid", "status"
            }

            for _, field in ipairs(allowed_fields) do
                if data[field] ~= nil then
                    update_params[field] = data[field]
                end
            end

            if data.metadata ~= nil then
                update_params.metadata = type(data.metadata) == "table" and cjson.encode(data.metadata) or data.metadata
            end

            if next(update_params) == nil then
                return api_response(400, nil, "No valid fields to update")
            end

            local updated = CrmQueries.updateAccount(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update account")
            end

            return api_response(200, updated)
        end)
    ))

    -- DELETE /api/v2/crm/accounts/:uuid - Soft delete account
    app:delete("/api/v2/crm/accounts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local account = CrmQueries.getAccount(self.params.uuid)
            if not account then
                return api_response(404, nil, "Account not found")
            end

            if tonumber(account.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local deleted = CrmQueries.deleteAccount(self.params.uuid)
            if not deleted then
                return api_response(500, nil, "Failed to delete account")
            end

            return api_response(200, { message = "Account deleted successfully" })
        end)
    ))
end
