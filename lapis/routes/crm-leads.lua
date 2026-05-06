--[[
    CRM Leads API Routes
    ====================

    RESTful API for CRM lead management with conversion workflow.

    Endpoints:
    - GET    /api/v2/crm/leads              - List leads
    - POST   /api/v2/crm/leads              - Create lead
    - GET    /api/v2/crm/leads/stats         - Lead statistics
    - GET    /api/v2/crm/leads/:uuid         - Get lead
    - PUT    /api/v2/crm/leads/:uuid         - Update lead
    - DELETE /api/v2/crm/leads/:uuid         - Soft delete lead
    - POST   /api/v2/crm/leads/:uuid/convert - Convert lead to contact + deal
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local CrmLeadQueries = require("queries.CrmLeadQueries")

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

    -- GET /api/v2/crm/leads - List leads
    app:get("/api/v2/crm/leads", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local result = CrmLeadQueries.getLeads(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                status = self.params.status,
                source = self.params.source,
                priority = self.params.priority,
                owner_user_uuid = self.params.owner_user_uuid,
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

    -- POST /api/v2/crm/leads - Create lead manually
    app:post("/api/v2/crm/leads", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            if (not data.first_name or data.first_name == "") and (not data.email or data.email == "") then
                return api_response(400, nil, "first_name or email is required")
            end

            local metadata = data.metadata
            if metadata and type(metadata) == "table" then
                metadata = cjson.encode(metadata)
            end

            local lead = CrmLeadQueries.createLead({
                namespace_id = self.namespace.id,
                first_name = data.first_name or "",
                last_name = data.last_name,
                email = data.email,
                phone = data.phone,
                company_name = data.company_name,
                job_title = data.job_title,
                source = data.source or "manual",
                channel = data.channel,
                campaign = data.campaign,
                referrer_url = data.referrer_url,
                landing_page_url = data.landing_page_url,
                status = data.status or "new",
                owner_user_uuid = data.owner_user_uuid or self.current_user.uuid,
                score = tonumber(data.score) or 0,
                priority = data.priority or "medium",
                notes = data.notes,
                metadata = metadata or "{}"
            })

            if not lead then
                return api_response(500, nil, "Failed to create lead")
            end

            return api_response(201, lead)
        end)
    ))

    -- GET /api/v2/crm/leads/stats - Lead statistics
    app:get("/api/v2/crm/leads/stats", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local stats = CrmLeadQueries.getLeadStats(self.namespace.id)
            return api_response(200, stats)
        end)
    ))

    -- GET /api/v2/crm/leads/:uuid - Get lead
    app:get("/api/v2/crm/leads/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local lead = CrmLeadQueries.getLead(self.params.uuid)
            if not lead then
                return api_response(404, nil, "Lead not found")
            end

            if tonumber(lead.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, lead)
        end)
    ))

    -- PUT /api/v2/crm/leads/:uuid - Update lead
    app:put("/api/v2/crm/leads/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local lead = CrmLeadQueries.getLead(self.params.uuid)
            if not lead then
                return api_response(404, nil, "Lead not found")
            end

            if tonumber(lead.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local data = parse_json_body()
            local update_params = {}
            local allowed_fields = {
                "first_name", "last_name", "email", "phone",
                "company_name", "job_title",
                "source", "channel", "campaign", "referrer_url", "landing_page_url",
                "status", "lost_reason",
                "owner_user_uuid", "score", "priority",
                "notes"
            }

            for _, field in ipairs(allowed_fields) do
                if data[field] ~= nil then
                    update_params[field] = data[field]
                end
            end

            -- Handle score as number
            if data.score ~= nil then
                update_params.score = tonumber(data.score) or 0
            end

            if data.metadata ~= nil then
                update_params.metadata = type(data.metadata) == "table" and cjson.encode(data.metadata) or data.metadata
            end

            if next(update_params) == nil then
                return api_response(400, nil, "No valid fields to update")
            end

            local updated = CrmLeadQueries.updateLead(self.params.uuid, update_params)
            if not updated then
                return api_response(500, nil, "Failed to update lead")
            end

            return api_response(200, updated)
        end)
    ))

    -- DELETE /api/v2/crm/leads/:uuid - Soft delete lead
    app:delete("/api/v2/crm/leads/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local lead = CrmLeadQueries.getLead(self.params.uuid)
            if not lead then
                return api_response(404, nil, "Lead not found")
            end

            if tonumber(lead.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local deleted = CrmLeadQueries.deleteLead(self.params.uuid)
            if not deleted then
                return api_response(500, nil, "Failed to delete lead")
            end

            return api_response(200, { message = "Lead deleted successfully" })
        end)
    ))

    -- POST /api/v2/crm/leads/:uuid/convert - Convert lead to contact + optional deal
    app:post("/api/v2/crm/leads/:uuid/convert", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()

            local result, err = CrmLeadQueries.convertLead(
                self.params.uuid,
                self.namespace.id,
                self.current_user.uuid,
                data.deal
            )

            if not result then
                local status_code = 500
                if err == "Lead not found" then status_code = 404 end
                if err == "Access denied" then status_code = 403 end
                if err == "Lead is already converted" then status_code = 409 end
                return api_response(status_code, nil, err)
            end

            return api_response(200, result)
        end)
    ))
end
