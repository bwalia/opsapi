--[[
    CRM Leads Public API Routes
    ============================

    Unauthenticated endpoint for capturing leads from external sources
    (website forms, landing pages, etc.).

    Endpoints:
    - POST /api/v2/public/leads/:namespace_slug - Submit a lead (no auth required)
    - GET  /api/v2/public/crm/lead-reports/:token - The AI lead report PDF behind the link in the
      new-lead email (an HMAC-signed, expiring token: lib/crm/lead-report.lua)

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
local LeadConfirmation = require("lib.crm.lead-confirmation")
local ShopUtil = require("lib.shop-util")

return function(app)
    -- GET /api/v2/public/crm/lead-reports/:token - the AI report linked from the new-lead email.
    app:get("/api/v2/public/crm/lead-reports/:token",
        RateLimit.wrap({ rate = 30, window = 60, prefix = "lead_report" }, function(self)
            local Report = require("lib.crm.lead-report")
            local function fail(status, message)
                return { status = status, json = { success = false, error = message } }
            end
            local ok, t, why = pcall(Report.verify, self.params.token, ngx.time(), Report.linkKey(),
                require("lib.supplier-portal-files").hmac)
            if not ok then
                ngx.log(ngx.ERR, "[lead-report] verify: ", tostring(t))
                return fail(503, "Reports aren't available right now")
            end
            if not t then
                return fail(why == "expired" and 410 or 404, why == "expired"
                    and "This link has expired. Open the lead in OpsAPI to download the report."
                    or "Report not found")
            end
            local lead = db.query("SELECT id FROM crm_leads WHERE uuid::text = ? AND deleted_at IS NULL", t.lead_uuid)[1]
            if not lead then return fail(404, "Report not found") end
            local bytes, name_or_status, message = Report.bytes(lead.id, t.analysis_uuid)
            if not bytes then return fail(name_or_status == 404 and 404 or 503, message) end
            return {
                status = 200, layout = false, content_type = "application/pdf",
                headers = {
                    ["Content-Disposition"] = 'inline; filename="' .. name_or_status .. '"',
                    ["Cache-Control"] = "no-store, private",
                    ["X-Content-Type-Options"] = "nosniff",
                    ["X-Robots-Tag"] = "noindex, nofollow",
                    ["Referrer-Policy"] = "no-referrer",
                },
                bytes,
            }
        end)
    )

    -- POST /api/v2/public/leads/:namespace_slug - Public lead submission
    app:post("/api/v2/public/leads/:namespace_slug",
        RateLimit.wrap({ rate = 10, window = 60, prefix = "public_lead" }, function(self)
            -- Resolve namespace from slug
            local namespaces = db.query([[
                SELECT id, slug, name FROM namespaces
                WHERE slug = ? AND status = 'active'
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

            if type(data) ~= "table" then data = {} end

            -- Bots: a hidden "honeypot" field people never fill in (send it empty
            -- as _hp, hp or website_hp). A filled one gets the normal thank-you
            -- and nothing is stored, so the bot learns nothing.
            for _, k in ipairs({ "_hp", "hp", "website_hp" }) do
                if type(data[k]) == "string" and data[k] ~= "" then
                    ngx.log(ngx.NOTICE, "[public-lead] honeypot filled for ", namespace.slug)
                    return { status = 201, json = { success = true, message = "Thank you for your submission" } }
                end
            end
            -- Cloudflare Turnstile (the workspace's key from Forms settings): checked
            -- whenever a token is sent, and required when the lead settings say so.
            local token = data.captcha_token or data["cf-turnstile-response"]
            local required = require("lib.crm.lead-settings").get(namespace.id).public_captcha == true
            if required or (type(token) == "string" and token ~= "") then
                local ok_ws, Workspace = pcall(require, "lib.forms.workspace")
                local secret
                if ok_ws then
                    local ok_t, _, s2 = pcall(Workspace.turnstile, namespace.id)
                    if ok_t then secret = s2 end
                end
                local verified = type(secret) == "string" and secret ~= "" and type(token) == "string"
                    and Workspace.verify(secret, token, RateLimit.getClientIP())
                if not verified and (required or type(secret) == "string") then
                    return { status = 400, json = { success = false, code = "captcha",
                        error = "Please complete the security check and try again." } }
                end
            end

            -- Text fields only, with sensible lengths.
            local LIMITS = { first_name = 120, last_name = 120, email = 254, phone = 40, company_name = 200,
                job_title = 120, source = 64, channel = 64, campaign = 120, landing_page_url = 2000,
                referrer_url = 2000, message = 10000, comments = 10000, notes = 10000 }
            for k, max in pairs(LIMITS) do
                local v = data[k]
                if v ~= nil and type(v) ~= "string" then data[k] = nil
                elseif type(v) == "string" and #v > max then data[k] = v:sub(1, max) end
            end

            -- Require at least email or first_name
            if (not data.email or data.email == "") and (not data.first_name or data.first_name == "") then
                return { status = 400, json = { success = false, error = "Email or name is required" } }
            end
            if data.email and data.email ~= "" and not data.email:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
                return { status = 400, json = { success = false, error = "Please enter a valid email address" } }
            end

            -- Capture source metadata from request headers
            local referrer = ngx.var.http_referer or data.referrer_url
            local user_agent = ngx.var.http_user_agent

            -- Optional legal confirmation ticked on the form: { documents = [{ key, version, statement }] }.
            -- Kept on the lead and, when the shop is enabled, in the legal-acceptance ledger (checkpoint "contact").
            local consent
            if type(data.consent) == "table" and type(data.consent.documents) == "table" then
                local docs = {}
                for i, d in ipairs(data.consent.documents) do
                    if i > 6 then break end
                    if type(d) == "table" and type(d.key) == "string" and type(d.version) == "string"
                        and type(d.statement) == "string" then
                        docs[#docs + 1] = { key = d.key:sub(1, 48), version = d.version:sub(1, 32),
                            statement = d.statement:sub(1, 1000) }
                    end
                end
                if #docs > 0 then consent = { documents = docs, accepted_at = ngx.utctime() .. "Z" } end
            end

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
                    consent = consent,
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

            if consent and data.email and data.email ~= "" then
                local ok_q, Legal = pcall(require, "queries.ShopLegalQueries")
                if ok_q then
                    -- Kept as evidence of what was ticked; checkpoint "contact" never counts as an acceptance by
                    -- that email (anyone can type an address here), see lib/shop-legal.lua.
                    local ok_r, res, rec_err = pcall(Legal.record, namespace.id, {
                        email = data.email, checkpoint = "contact", subject_ref = lead.uuid,
                        ip = RateLimit.getClientIP(), user_agent = user_agent, documents = consent.documents,
                    })
                    if not ok_r or not res then
                        local why = not ok_r and tostring(res)
                            or (type(rec_err) == "table" and tostring(rec_err.message) or tostring(rec_err))
                        ngx.log(ngx.WARN, "[public-lead] legal acceptance not recorded: ", why)
                    end
                end
            end

            -- Fresh capture succeeded — fire configured notifications (confirmation
            -- to submitter, admin email, Telegram). Deferred to a timer internally,
            -- so this never blocks the response; failures are logged, not fatal.
            -- The shop's survey (BFF, X-Shop-Key) may add bullet points and how to reach us to the
            -- confirmation email. Never from an anonymous caller: see lib/crm/lead-confirmation.lua.
            local confirmation
            if data.confirmation ~= nil then
                local key = ShopUtil.env("SHOP_BFF_KEY")
                if key and ShopUtil.secure_equals(self.req.headers["x-shop-key"], key) then
                    confirmation = LeadConfirmation.sanitize(data.confirmation)
                end
            end
            CrmLeadNotificationQueries.notify(namespace, lead, { confirmation = confirmation })

            return { status = 201, json = { success = true, message = "Thank you for your submission" } }
        end)
    )
end
