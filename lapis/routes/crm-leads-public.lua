--[[
    CRM Leads Public API Routes
    ============================

    Unauthenticated endpoint for capturing leads from external sources
    (website forms, landing pages, etc.).

    Endpoints:
    - POST /api/v2/public/leads/:namespace_slug - Submit a lead (no auth required)

    Confirmation email:
    On successful capture with a valid email, a "we got your enquiry"
    confirmation is sent to the submitter via helper.mail. The send is
    fire-and-forget (Mail.send default is async via ngx.timer.at) so the
    HTTP response never waits on SMTP. If SMTP isn't configured, Mail.send
    logs a warning and returns false — the lead is still stored, only the
    email side-effect is skipped. Duplicates (same email in same namespace
    within 5 minutes) do not re-send the email — the earlier submission
    already produced one.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local RateLimit = require("middleware.rate-limit")
local CrmLeadQueries = require("queries.CrmLeadQueries")
local Mail = require("helper.mail")

--- Fire the "thanks for reaching out" confirmation to the submitter.
-- Non-blocking (Mail.send is async by default) and non-throwing: any
-- SMTP problem is logged and swallowed so a mail-side-effect never
-- fails a lead capture that already succeeded database-side.
-- @param lead_data table  Parsed request body (first_name, company_name, notes, ...)
-- @param recipient string Verified email from the request
local function send_lead_confirmation(lead_data, recipient)
    if not recipient or recipient == "" then return end
    if not Mail.isConfigured() then
        ngx.log(ngx.NOTICE, "[crm-leads-public] SMTP not configured — skipping confirmation email to ", recipient)
        return
    end

    local ok, err = pcall(Mail.send, {
        to = recipient,
        subject = "We got your enquiry — thanks for getting in touch",
        template = "lead_confirmation",
        data = {
            first_name = lead_data.first_name,
            company_name = lead_data.company_name,
            notes = lead_data.comments or lead_data.notes,
            -- app_name / current_year are auto-populated by render_template.
        },
    })
    if not ok then
        ngx.log(ngx.WARN, "[crm-leads-public] confirmation email send raised: ", tostring(err))
    elseif err then
        -- Mail.send returns (false, "reason") on non-fatal failures.
        ngx.log(ngx.WARN, "[crm-leads-public] confirmation email not sent: ", tostring(err))
    end
end

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
                    -- Return success to avoid leaking info about existing submissions.
                    -- Do NOT re-send the confirmation email — the original submission
                    -- (within the last 5 minutes) already produced one; sending again
                    -- would risk looking like phishing to the recipient.
                    return { status = 200, json = { success = true, message = "Thank you for your submission" } }
                end
                return { status = 500, json = { success = false, error = "Submission failed" } }
            end

            -- Fresh capture succeeded — fire the confirmation. Non-blocking, non-throwing.
            send_lead_confirmation(data, data.email)

            return { status = 201, json = { success = true, message = "Thank you for your submission" } }
        end)
    )
end
