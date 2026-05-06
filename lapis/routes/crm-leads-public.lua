--[[
    CRM Leads Public API Routes
    ============================

    Unauthenticated endpoint for capturing leads from external sources
    (website forms, landing pages, etc.).

    Endpoints:
    - POST /api/v2/public/leads/:namespace_slug - Submit a lead (no auth required)
]]

local cjson = require("cjson")
local db = require("lapis.db")
local RateLimit = require("middleware.rate-limit")
local CrmLeadQueries = require("queries.CrmLeadQueries")

return function(app)
    -- POST /api/v2/public/leads/:namespace_slug - Public lead submission
    app:post("/api/v2/public/leads/:namespace_slug",
        RateLimit.wrap({ rate = 10, window = 60, prefix = "public_lead" }, function(self)
            -- Resolve namespace from slug
            local namespaces = db.query([[
                SELECT id, slug FROM namespaces
                WHERE slug = ?
                LIMIT 1
            ]], self.params.namespace_slug)

            if not namespaces or #namespaces == 0 then
                return { status = 404, json = { success = false, error = "Not found" } }
            end

            local namespace = namespaces[1]

            -- Parse body
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            local data = {}
            if body and body ~= "" then
                local ok, parsed = pcall(cjson.decode, body)
                if ok then data = parsed end
            end

            -- Require at least email or first_name
            if (not data.email or data.email == "") and (not data.first_name or data.first_name == "") then
                return { status = 400, json = { success = false, error = "Email or name is required" } }
            end

            -- Capture source metadata from request headers
            local referrer = ngx.var.http_referer or data.referrer_url
            local user_agent = ngx.var.http_user_agent

            local lead, err = CrmLeadQueries.createLeadFromPublic({
                namespace_id = namespace.id,
                first_name = data.first_name or "",
                last_name = data.last_name,
                email = data.email,
                phone = data.phone,
                company_name = data.company_name,
                job_title = data.job_title,
                source = data.source or "website_form",
                channel = data.channel,
                campaign = data.campaign,
                referrer_url = referrer,
                landing_page_url = data.landing_page_url,
                notes = data.comments or data.notes,
                metadata = cjson.encode({
                    user_agent = user_agent,
                    ip = RateLimit.getClientIP()
                })
            })

            if not lead then
                if err == "duplicate" then
                    -- Return success to avoid leaking info about existing submissions
                    return { status = 200, json = { success = true, message = "Thank you for your submission" } }
                end
                return { status = 500, json = { success = false, error = "Submission failed" } }
            end

            return { status = 201, json = { success = true, message = "Thank you for your submission" } }
        end)
    )
end
