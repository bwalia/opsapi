--[[
    Email Routes (routes/email.lua)

    REST API for sending emails. Designed for SaaS — any frontend can call these.

    SECURITY:
    - All endpoints require JWT authentication
    - Rate limited to prevent spam (20 emails/min per user)
    - Frontends can supply their own HTML body OR use server-side templates
    - Optional base layout wrapping for consistent branding
    - Template preview is admin-only

    Endpoints:
      POST /api/v2/email/send        — Send an email (template, HTML, or text)
      POST /api/v2/email/preview      — Preview a rendered template (admin only)
      GET  /api/v2/email/templates    — List available templates
      GET  /api/v2/email/config       — Check SMTP configuration status
]]

local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local AdminCheck = require("helper.admin-check")
local Mail = require("helper.mail")
local RateLimit = require("middleware.rate-limit")
local cjson = require("cjson")

-- Rate limits
local EMAIL_SEND_LIMIT = { rate = 20, window = 60, prefix = "email:send" }  -- 20/min per IP

--- Validate an email address (basic format check)
local function is_valid_email(email)
    if type(email) ~= "string" then return false end
    return email:match("^[%w%._%+%-]+@[%w%.%-]+%.[%a]+$") ~= nil
end

--- Validate recipient list, return sanitized table or nil + error
local function validate_recipients(to)
    if type(to) == "string" then
        if not is_valid_email(to) then
            return nil, "Invalid email address: " .. to
        end
        return { to }
    end

    if type(to) == "table" then
        if #to == 0 then
            return nil, "Recipient list is empty"
        end
        if #to > 50 then
            return nil, "Maximum 50 recipients per request"
        end
        for i, addr in ipairs(to) do
            if not is_valid_email(addr) then
                return nil, "Invalid email at position " .. i .. ": " .. tostring(addr)
            end
        end
        return to
    end

    return nil, "Recipient (to) must be a string or array of strings"
end

--- Sanitize subject line (strip control characters, limit length)
local function sanitize_subject(subject)
    if type(subject) ~= "string" then return nil end
    -- Strip control characters (newlines, tabs, etc.) to prevent header injection
    subject = subject:gsub("[%c]", "")
    -- Limit length
    if #subject > 998 then
        subject = subject:sub(1, 998)
    end
    return subject
end

--- Extract safe error for client, log full error server-side
local function safe_error(err, fallback)
    local msg = tostring(err)
    ngx.log(ngx.ERR, "[Email Route] ", msg)
    -- Expose validation errors but not internal SMTP details
    if msg:match("Invalid email") or msg:match("is required") or msg:match("Recipient")
        or msg:match("Maximum") or msg:match("not found") or msg:match("not configured")
        or msg:match("Invalid template") then
        return msg
    end
    return fallback or "Email operation failed"
end

return function(app)

    -- ========================================================================
    -- POST /api/v2/email/send — Send an email
    -- ========================================================================
    -- Supports three content modes (any authenticated user):
    --
    -- 1. Server-side template:
    --    { "to": "...", "subject": "...", "template": "welcome", "data": {...} }
    --
    -- 2. Frontend-supplied HTML:
    --    { "to": "...", "subject": "...", "html": "<h1>Hello</h1>" }
    --
    -- 3. Frontend HTML wrapped in server base layout (consistent branding):
    --    { "to": "...", "subject": "...", "html": "<h1>Hello</h1>", "wrap_in_layout": true }
    --
    -- 4. Plain text:
    --    { "to": "...", "subject": "...", "text": "Hello world" }
    --
    -- Optional: cc, bcc, reply_to, from_name, data (for layout variables)
    -- ========================================================================
    app:match("/api/v2/email/send", respond_to({
        before = function(self)
            AuthMiddleware.requireAuthBefore(self)
        end,

        POST = RateLimit.wrap(EMAIL_SEND_LIMIT, function(self)
            -- Parse JSON body
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if not body then
                return { json = { error = "Request body is required" }, status = 400 }
            end

            local ok, params = pcall(cjson.decode, body)
            if not ok then
                return { json = { error = "Invalid JSON" }, status = 400 }
            end

            -- Validate required fields
            if not params.to then
                return { json = { error = "Field 'to' is required" }, status = 400 }
            end
            if not params.subject or params.subject == "" then
                return { json = { error = "Field 'subject' is required" }, status = 400 }
            end

            -- Sanitize subject
            params.subject = sanitize_subject(params.subject)
            if not params.subject or params.subject == "" then
                return { json = { error = "Invalid subject" }, status = 400 }
            end

            -- Validate recipients
            local recipients, rec_err = validate_recipients(params.to)
            if not recipients then
                return { json = { error = rec_err }, status = 400 }
            end

            -- Validate cc/bcc if provided
            if params.cc then
                local cc, cc_err = validate_recipients(params.cc)
                if not cc then
                    return { json = { error = "cc: " .. cc_err }, status = 400 }
                end
                params.cc = cc
            end
            if params.bcc then
                local bcc, bcc_err = validate_recipients(params.bcc)
                if not bcc then
                    return { json = { error = "bcc: " .. bcc_err }, status = 400 }
                end
                params.bcc = bcc
            end

            -- Determine content source
            local has_template = params.template and params.template ~= ""
            local has_html = params.html and params.html ~= ""
            local has_text = params.text and params.text ~= ""

            if not has_template and not has_html and not has_text then
                return {
                    json = { error = "Provide 'template', 'html', or 'text' for email body" },
                    status = 400
                }
            end

            -- Build send options
            local send_opts = {
                to       = recipients,
                subject  = params.subject,
                cc       = params.cc,
                bcc      = params.bcc,
                reply_to = params.reply_to,
            }

            if has_template then
                -- Server-side template rendering
                send_opts.template = params.template
                send_opts.data = params.data or {}
                -- Inject useful context the frontend doesn't need to pass
                send_opts.data.recipient_email = type(params.to) == "string" and params.to or params.to[1]
                if self.current_user then
                    send_opts.data.sender_name = (self.current_user.first_name or "") .. " " .. (self.current_user.last_name or "")
                    send_opts.data.sender_email = self.current_user.email
                end
            elseif has_html then
                -- Frontend-supplied HTML (optionally wrapped in base layout)
                send_opts.html = params.html
                if params.wrap_in_layout then
                    send_opts.wrap_in_layout = true
                    send_opts.data = params.data or {}
                end
            end

            -- Plain text (can be combined with HTML as fallback)
            if has_text then
                send_opts.text = params.text
            end

            -- Override sender name if provided
            if params.from_name and params.from_name ~= "" then
                send_opts.from_name = params.from_name
            end

            -- Send (async)
            local success, err = Mail.send(send_opts)
            if not success then
                return { json = { error = safe_error(err, "Failed to send email") }, status = 500 }
            end

            return {
                json = {
                    success = true,
                    message = "Email queued for delivery",
                    recipients = #recipients,
                },
                status = 200
            }
        end),
    }))

    -- ========================================================================
    -- POST /api/v2/email/preview — Preview a rendered template (admin only)
    -- ========================================================================
    app:match("/api/v2/email/preview", respond_to({
        before = function(self)
            AuthMiddleware.requireAuthBefore(self)
            if self.res and self.res.status then return end

            if not AdminCheck.isPlatformAdmin(self.current_user) then
                self:write({
                    json = { error = "Platform admin access required" },
                    status = 403
                })
                return
            end
        end,

        POST = function(self)
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if not body then
                return { json = { error = "Request body is required" }, status = 400 }
            end

            local ok, params = pcall(cjson.decode, body)
            if not ok then
                return { json = { error = "Invalid JSON" }, status = 400 }
            end

            if not params.template or params.template == "" then
                return { json = { error = "Field 'template' is required" }, status = 400 }
            end

            local html, err = Mail.preview(params.template, params.data or {})
            if not html then
                return { json = { error = safe_error(err, "Template render failed") }, status = 400 }
            end

            return { json = { html = html, template = params.template } }
        end,
    }))

    -- ========================================================================
    -- GET /api/v2/email/templates — List available templates
    -- ========================================================================
    app:get("/api/v2/email/templates", AuthMiddleware.requireAuth(function(self)
        local templates = Mail.getTemplates()
        return {
            json = {
                templates = templates,
                count = #templates,
            }
        }
    end))

    -- ========================================================================
    -- GET /api/v2/email/config — Check SMTP configuration status
    -- ========================================================================
    app:get("/api/v2/email/config", AuthMiddleware.requireAuth(function(self)
        if not AdminCheck.isPlatformAdmin(self.current_user) then
            return {
                json = {
                    configured = Mail.isConfigured(),
                },
            }
        end

        local host = os.getenv("SMTP_HOST") or "smtp.gmail.com"
        local port = tonumber(os.getenv("SMTP_PORT")) or 587
        local from_email = os.getenv("SMTP_FROM_EMAIL") or os.getenv("SMTP_USER") or ""
        local from_name = os.getenv("SMTP_FROM_NAME") or "OpsAPI"

        return {
            json = {
                configured = Mail.isConfigured(),
                host = host,
                port = port,
                from_email = from_email,
                from_name = from_name,
                starttls = true,
            },
        }
    end))
end
