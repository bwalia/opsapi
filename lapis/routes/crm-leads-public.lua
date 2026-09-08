--[[
    CRM Leads Public API Routes
    ============================

    Unauthenticated endpoint for capturing leads from external sources
    (website forms, landing pages, etc.).

    Endpoints:
    - POST /api/v2/public/leads/:namespace_slug - Submit a lead (no auth required)

    Notifications:
    On a fresh capture, CrmLeadNotificationQueries.notify() fires the configured
    channels for the namespace (see crm_lead_notification_settings): a
    confirmation email to the submitter, a "you got a lead" email to the
    namespace owner/admin, and an optional Telegram alert. It reads settings in
    request context and defers the actual sends to an ngx.timer, so the HTTP
    response never waits on SMTP / Telegram. Duplicates (same email in the same
    namespace within 5 minutes) do NOT re-notify — the earlier submission
    already did.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local RateLimit = require("middleware.rate-limit")
local CrmLeadQueries = require("queries.CrmLeadQueries")
local CrmLeadNotificationQueries = require("queries.CrmLeadNotificationQueries")

return function(app)
    -- POST /api/v2/public/leads/:namespace_slug - Public lead submission
    app:post("/api/v2/public/leads/:namespace_slug",
        RateLimit.wrap({ rate = 10, window = 60, prefix = "public_lead" }, function(self)
            -- Resolve namespace from slug
            local namespaces = db.query([[
                SELECT id, slug, name FROM namespaces
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
                -- The enquiry text a visitor types. Public forms name this
                -- field inconsistently (`message` is the most common, then
                -- `comments`/`notes`) — accept all three so the message is
                -- never silently dropped. It lands in `notes` (shown + editable
                -- in the lead detail view).
                notes = data.message or data.comments or data.notes,
                metadata = cjson.encode({
                    user_agent = user_agent,
                    ip = RateLimit.getClientIP(),
                    -- Keep the ORIGINAL submitted message verbatim so a later
                    -- edit to `notes` can never lose the visitor's own words.
                    message = data.message or data.comments or data.notes,
                })
            })

            if not lead then
                if err == "duplicate" then
                    -- Return success to avoid leaking info about existing submissions.
                    -- Do NOT re-send the confirmation email — the original submission
                    -- (within the last 5 minutes) already produced one; sending again
                    -- would risk looking like phishing to the recipient.
                    return { status = 200, json = { success = true, message = "Thank you for your submission" } }
                end
                return { status = 500, json = { success = false, error = "Submission failed" } }
            end

            -- Fresh capture succeeded — fire configured notifications (confirmation
            -- to submitter, admin email, Telegram). Deferred to a timer internally,
            -- so this never blocks the response; failures are logged, not fatal.
            CrmLeadNotificationQueries.notify(namespace, lead)

            return { status = 201, json = { success = true, message = "Thank you for your submission" } }
        end)
    )
end
