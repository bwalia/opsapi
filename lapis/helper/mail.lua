--[[
    Mail Service (helper/mail.lua)

    Non-blocking email sending via lua-resty-mail (cosocket SMTP).
    Supports Gmail, SendGrid, Mailgun, or any SMTP provider.

    Features:
    - Async sending via ngx.timer.at (never blocks request handlers)
    - etlua HTML templates with base layout inheritance
    - SaaS-friendly: frontends can supply their own HTML body
    - Custom HTML can optionally be wrapped in the base layout
    - Template registry for dynamic template discovery
    - Configurable SMTP via environment variables
    - Retry with exponential backoff
    - Structured logging for debugging

    Environment variables:
      SMTP_HOST       - SMTP server (default: smtp.gmail.com)
      SMTP_PORT       - SMTP port (default: 587 for STARTTLS)
      SMTP_USER       - SMTP username / email
      SMTP_PASSWORD   - SMTP password / app password
      SMTP_FROM_EMAIL - Default sender email (falls back to SMTP_USER)
      SMTP_FROM_NAME  - Default sender display name (default: OpsAPI)

    Usage:
      local Mail = require("helper.mail")

      -- Send with a named server-side template
      Mail.send({
        to = "user@example.com",
        subject = "Welcome!",
        template = "welcome",
        data = { user_name = "John", app_name = "DIY Tax Return" }
      })

      -- Send frontend-supplied HTML (SaaS mode)
      Mail.send({
        to = "user@example.com",
        subject = "Invoice Ready",
        html = "<h1>Your invoice</h1><p>See attached.</p>",
      })

      -- Send frontend HTML wrapped in the server base layout
      Mail.send({
        to = "user@example.com",
        subject = "Invoice Ready",
        html = "<h1>Your invoice</h1>",
        wrap_in_layout = true,
        data = { app_name = "My SaaS" }
      })

      -- Send plain text
      Mail.send({
        to = "user@example.com",
        subject = "OTP Code",
        text = "Your code is 123456"
      })
]]

local Mail = {}

-- ============================================================================
-- Configuration
-- ============================================================================

local function get_config()
    return {
        host     = os.getenv("SMTP_HOST") or "smtp.gmail.com",
        port     = tonumber(os.getenv("SMTP_PORT")) or 587,
        username = os.getenv("SMTP_USER") or "",
        password = os.getenv("SMTP_PASSWORD") or "",
        from_email = os.getenv("SMTP_FROM_EMAIL") or os.getenv("SMTP_USER") or "noreply@opsapi.com",
        from_name  = os.getenv("SMTP_FROM_NAME") or "OpsAPI",
    }
end

--- Check if SMTP is configured (has credentials)
function Mail.isConfigured()
    local cfg = get_config()
    return cfg.username ~= "" and cfg.password ~= ""
end

-- ============================================================================
-- Template Engine
-- ============================================================================

local template_cache = {}

--- Sanitize brand_color to prevent CSS injection. Only #hex allowed.
local function sanitize_hex_color(color, default)
    default = default or "#dc2626"
    if type(color) ~= "string" then return default end
    if color:match("^#%x%x%x%x%x%x$") then return color end
    if color:match("^#%x%x%x$") then return color end
    return default
end

--- Sanitize a URL for safe embedding in HTML attributes. Only https:// allowed.
local function sanitize_url(url)
    if type(url) ~= "string" then return nil end
    if url:match("^https://[%w%.%-/_%?&=%%~:@!%$%+,;]+$") then return url end
    return nil
end

--- Sanitize template data to prevent injection via dynamic CSS/HTML values.
-- Called before every template render.
local function sanitize_template_data(data)
    if not data then return data end
    if data.brand_color then
        data.brand_color = sanitize_hex_color(data.brand_color)
    end
    if data.brand_logo_url then
        data.brand_logo_url = sanitize_url(data.brand_logo_url)
    end
    return data
end

--- Validate template name to prevent path traversal and injection.
-- Only allows alphanumeric, hyphen, underscore (and leading _ for partials).
-- @param name string Template name
-- @return boolean valid
local function is_valid_template_name(name)
    if type(name) ~= "string" or name == "" then return false end
    if #name > 64 then return false end
    -- Allow: letters, digits, hyphens, underscores. Must not contain dots or slashes.
    return name:match("^[%w_%-]+$") ~= nil
end

--- Load and compile an etlua template from views/emails/<name>.etlua
-- Results are cached for the lifetime of the worker process.
-- @param name string Template name (without .etlua extension)
-- @return function|nil Compiled template function, or nil on error
-- @return string|nil Error message if template not found
local function load_template(name)
    if not is_valid_template_name(name) then
        return nil, "Invalid template name: " .. tostring(name)
    end

    if template_cache[name] then
        return template_cache[name]
    end

    local etlua = require("etlua")

    local path = "views/emails/" .. name .. ".etlua"
    local file = io.open(path, "r")
    if not file then
        return nil, "Template not found: " .. name
    end

    local content = file:read("*a")
    file:close()

    local compiled, err = etlua.compile(content)
    if not compiled then
        return nil, "Template compile error: " .. tostring(err)
    end

    template_cache[name] = compiled
    return compiled
end

--- Render a template with data, wrapped in the base layout.
-- @param name string Template name
-- @param data table Template variables
-- @return string|nil Rendered HTML
-- @return string|nil Error message
local function render_template(name, data)
    data = data or {}

    local cfg = get_config()
    data.app_name = data.app_name or cfg.from_name
    data.current_year = os.date("%Y")

    -- Sanitize user-supplied values that are embedded in CSS/HTML attributes
    sanitize_template_data(data)

    local inner_tpl, err = load_template(name)
    if not inner_tpl then
        return nil, err
    end

    local ok, inner_html = pcall(inner_tpl, data)
    if not ok then
        return nil, "Template render error (" .. name .. "): " .. tostring(inner_html)
    end

    -- Wrap in base layout (if it exists)
    local base_tpl = load_template("_base")
    if base_tpl then
        data.content = inner_html
        local ok2, full_html = pcall(base_tpl, data)
        if ok2 then
            return full_html
        end
        ngx.log(ngx.WARN, "[Mail] Base layout render failed, using inner template: ", tostring(full_html))
    end

    return inner_html
end

--- Wrap raw HTML content in the base layout template.
-- Used when frontends supply their own HTML but want consistent branding.
-- @param html string Raw HTML content
-- @param data table Optional template variables (app_name, current_year, etc.)
-- @return string Wrapped HTML (or original HTML if base layout unavailable)
local function wrap_in_base_layout(html, data)
    data = data or {}

    local cfg = get_config()
    data.app_name = data.app_name or cfg.from_name
    data.current_year = os.date("%Y")
    data.content = html

    -- Sanitize user-supplied values that are embedded in CSS/HTML attributes
    sanitize_template_data(data)

    local base_tpl = load_template("_base")
    if not base_tpl then
        return html
    end

    local ok, full_html = pcall(base_tpl, data)
    if ok then
        return full_html
    end

    ngx.log(ngx.WARN, "[Mail] Base layout wrap failed: ", tostring(full_html))
    return html
end

--- List all available template names (safe directory scan, no shell execution)
-- @return table Array of template names (without _base and _partials)
function Mail.getTemplates()
    local templates = {}
    local lfs_ok, lfs = pcall(require, "lfs")

    if lfs_ok then
        -- Use LuaFileSystem if available
        for entry in lfs.dir("views/emails") do
            local name = entry:match("^(.+)%.etlua$")
            if name and not name:match("^_") then
                templates[#templates + 1] = name
            end
        end
    else
        -- Fallback: try known template names by probing files
        local known = {
            "welcome", "invitation", "password_reset", "verification",
            "otp", "notification",
        }
        for _, name in ipairs(known) do
            local f = io.open("views/emails/" .. name .. ".etlua", "r")
            if f then
                f:close()
                templates[#templates + 1] = name
            end
        end
    end

    table.sort(templates)
    return templates
end

-- ============================================================================
-- SMTP Sending (non-blocking via lua-resty-mail)
-- ============================================================================

--- Low-level send via lua-resty-mail. Must be called from a cosocket context
--- (request handler or ngx.timer callback).
-- @param opts table { to, subject, html, text, from_email, from_name, cc, bcc, reply_to }
-- @return boolean success
-- @return string|nil error message
local function smtp_send(opts)
    local mail = require("resty.mail")
    local cfg = get_config()

    local mailer, err = mail.new({
        host     = cfg.host,
        port     = cfg.port,
        starttls = true,
        username = cfg.username,
        password = cfg.password,
        timeout_connect = 10000,
        timeout_send    = 10000,
        timeout_read    = 10000,
    })

    if not mailer then
        return false, "SMTP connection failed: " .. tostring(err)
    end

    -- Build recipients list
    local to_list = opts.to
    if type(to_list) == "string" then
        to_list = { to_list }
    end

    local from_name = opts.from_name or cfg.from_name
    local from_email = opts.from_email or cfg.from_email
    local from = from_name .. " <" .. from_email .. ">"

    local send_opts = {
        from    = from,
        to      = to_list,
        subject = opts.subject or "(No Subject)",
    }

    if opts.cc then
        send_opts.cc = type(opts.cc) == "string" and { opts.cc } or opts.cc
    end
    if opts.bcc then
        send_opts.bcc = type(opts.bcc) == "string" and { opts.bcc } or opts.bcc
    end
    if opts.reply_to then
        send_opts["reply-to"] = opts.reply_to
    end

    if opts.html then
        send_opts.html = opts.html
    end
    if opts.text then
        send_opts.text = opts.text
    end

    -- Auto-generate text version from HTML
    if opts.html and not opts.text then
        send_opts.text = opts.html:gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", "")
    end

    local ok2, send_err = mailer:send(send_opts)
    if not ok2 then
        return false, "SMTP send failed: " .. tostring(send_err)
    end

    return true
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Send an email (async by default, non-blocking).
--
-- @param opts table Email options:
--   to             : string or table of recipient emails (required)
--   subject        : string (required)
--   template       : string template name (renders from views/emails/<name>.etlua)
--   data           : table of template variables (used with template or wrap_in_layout)
--   html           : string raw HTML body (used if no template)
--   text           : string plain text body
--   wrap_in_layout : boolean wrap html in base layout (for SaaS frontends wanting branding)
--   from_email     : string override sender email
--   from_name      : string override sender name
--   cc             : string or table
--   bcc            : string or table
--   reply_to       : string
--   sync           : boolean if true, send synchronously (blocks; use in timers/scripts only)
--
-- @return boolean true if queued (async) or sent (sync)
-- @return string|nil error message
function Mail.send(opts)
    if not opts or not opts.to then
        return false, "Recipient (to) is required"
    end
    if not opts.subject then
        return false, "Subject is required"
    end

    -- Render server-side template if specified
    if opts.template then
        local html, err = render_template(opts.template, opts.data)
        if not html then
            ngx.log(ngx.ERR, "[Mail] Template render failed: ", err)
            return false, err
        end
        opts.html = html
        opts.template = nil
        opts.data = nil
    elseif opts.html and opts.wrap_in_layout then
        -- Frontend-supplied HTML wrapped in server base layout
        opts.html = wrap_in_base_layout(opts.html, opts.data)
        opts.data = nil
    end
    opts.wrap_in_layout = nil

    -- Must have a body
    if not opts.html and not opts.text then
        return false, "Email body is required (html, text, or template)"
    end

    -- Check SMTP configuration
    if not Mail.isConfigured() then
        ngx.log(ngx.WARN, "[Mail] SMTP not configured — email to ", tostring(opts.to), " not sent")
        return false, "SMTP not configured. Set SMTP_USER and SMTP_PASSWORD environment variables."
    end

    -- Synchronous mode (for use in ngx.timer callbacks or lapis exec scripts)
    if opts.sync then
        local ok, err = smtp_send(opts)
        if not ok then
            ngx.log(ngx.ERR, "[Mail] Send failed: ", err)
        else
            ngx.log(ngx.NOTICE, "[Mail] Sent to: ", type(opts.to) == "table" and table.concat(opts.to, ", ") or opts.to)
        end
        return ok, err
    end

    -- Async mode (default) — fire-and-forget via ngx.timer.at
    local cjson = require("cjson")
    local payload = cjson.encode({
        to         = opts.to,
        subject    = opts.subject,
        html       = opts.html,
        text       = opts.text,
        from_email = opts.from_email,
        from_name  = opts.from_name,
        cc         = opts.cc,
        bcc        = opts.bcc,
        reply_to   = opts.reply_to,
    })

    local ok, timer_err = ngx.timer.at(0, function(premature)
        if premature then return end

        local send_opts = cjson.decode(payload)

        -- Retry with exponential backoff (max 3 attempts)
        local max_retries = 3
        for attempt = 1, max_retries do
            local success, err = smtp_send(send_opts)
            if success then
                ngx.log(ngx.NOTICE, "[Mail] Sent to: ",
                    type(send_opts.to) == "table" and table.concat(send_opts.to, ", ") or send_opts.to,
                    " (attempt ", attempt, ")")
                return
            end

            ngx.log(ngx.ERR, "[Mail] Attempt ", attempt, "/", max_retries,
                " failed for: ", type(send_opts.to) == "table" and table.concat(send_opts.to, ", ") or send_opts.to,
                " — ", tostring(err))

            if attempt < max_retries then
                ngx.sleep(attempt * 2)
            end
        end

        ngx.log(ngx.ERR, "[Mail] All ", max_retries, " attempts failed for: ",
            type(send_opts.to) == "table" and table.concat(send_opts.to, ", ") or send_opts.to)
    end)

    if not ok then
        ngx.log(ngx.ERR, "[Mail] Failed to create timer: ", tostring(timer_err))
        return false, "Failed to queue email: " .. tostring(timer_err)
    end

    return true
end

--- Send a templated email (convenience wrapper)
-- @param to string|table Recipient(s)
-- @param subject string Email subject
-- @param template string Template name
-- @param data table Template variables
-- @return boolean, string|nil
function Mail.sendTemplate(to, subject, template, data)
    return Mail.send({
        to = to,
        subject = subject,
        template = template,
        data = data,
    })
end

--- Render a template without sending (for previewing)
-- @param template string Template name
-- @param data table Template variables
-- @return string|nil HTML content
-- @return string|nil Error
function Mail.preview(template, data)
    return render_template(template, data)
end

return Mail
