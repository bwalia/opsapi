--[[
    CRM Contacts API Routes
    =======================

    RESTful API for CRM contact management.

    Endpoints:
    - GET    /api/v2/crm/contacts          - List contacts
    - POST   /api/v2/crm/contacts          - Create contact
    - GET    /api/v2/crm/contacts/:uuid     - Get contact
    - PUT    /api/v2/crm/contacts/:uuid     - Update contact
    - DELETE /api/v2/crm/contacts/:uuid     - Soft delete contact
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

    -- GET /api/v2/crm/contacts - List contacts
    app:get("/api/v2/crm/contacts", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = CrmQueries.getContacts(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                account_id = self.params.account_id,
                status = self.params.status,
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

    -- POST /api/v2/crm/contacts - Create contact
    app:post("/api/v2/crm/contacts", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if not data.first_name or data.first_name == "" then
                return api_response(400, nil, "first_name is required")
            end

            local metadata = data.metadata
            if metadata and type(metadata) == "table" then
                metadata = cjson.encode(metadata)
            end

            local contact = CrmQueries.createContact({
                namespace_id = self.namespace.id,
                account_id = data.account_id,
                first_name = data.first_name,
                last_name = data.last_name,
                email = data.email,
                phone = data.phone,
                mobile = data.mobile,
                job_title = data.job_title,
                department = data.department,
                owner_user_uuid = data.owner_user_uuid or self.current_user.uuid,
                status = data.status or "active",
                metadata = metadata or "{}"
            })

            if not contact then
                return api_response(500, nil, "Failed to create contact")
            end

            return api_response(201, contact)
        end)
    ))

    -- GET /api/v2/crm/contacts/:uuid - Get contact
    app:get("/api/v2/crm/contacts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local contact = CrmQueries.getContact(self.params.uuid)
            if not contact then
                return api_response(404, nil, "Contact not found")
            end

            if tonumber(contact.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, contact)
        end)
    ))

    -- PUT /api/v2/crm/contacts/:uuid - Update contact
    app:put("/api/v2/crm/contacts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local contact = CrmQueries.getContact(self.params.uuid)
            if not contact then
                return api_response(404, nil, "Contact not found")
            end

            if tonumber(contact.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = {
                "first_name", "last_name", "email", "phone", "mobile",
                "job_title", "department", "account_id", "owner_user_uuid", "status"
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

            local updated = CrmQueries.updateContact(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update contact")
            end

            return api_response(200, updated)
        end)
    ))

    -- DELETE /api/v2/crm/contacts/:uuid - Soft delete contact
    app:delete("/api/v2/crm/contacts/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local contact = CrmQueries.getContact(self.params.uuid)
            if not contact then
                return api_response(404, nil, "Contact not found")
            end

            if tonumber(contact.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local deleted = CrmQueries.deleteContact(self.params.uuid)
            if not deleted then
                return api_response(500, nil, "Failed to delete contact")
            end

            return api_response(200, { message = "Contact deleted successfully" })
        end)
    ))
end
