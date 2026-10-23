-- Email channel adapter: SMTP via helper/mail.lua + optional namespace SMTP.
local Mail = require("helper.mail")
local NamespaceMail = require("helper.namespace-mail")
local TemplateRenderer = require("lib.template-renderer")
local U = require("opsapi_marketing.util")
local Links = require("opsapi_marketing.links")

local C = {}

function C.capabilities()
    return {
        supports_html = true,
        supports_tracking_pixel = true,
        supports_link_rewrite = true,
        max_body_len = 1024 * 1024,
        requires_verified_sender = false,
        max_subject_len = 998,
    }
end

local function strip_dangerous(html)
    if type(html) ~= "string" then return "" end
    html = html:gsub("<%s*[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-<%s*/%s*[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", "")
    html = html:gsub("<%s*[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>", "")
    html = html:gsub("%s[Oo][Nn]%w+%s*=%s*\"[^\"]*\"", "")
    html = html:gsub("%s[Oo][Nn]%w+%s*=%s*'[^']*'", "")
    html = html:gsub("[Jj][Aa][Vv][Aa][Ss][Cc][Rr][Ii][Pp][Tt]%s*:", "")
    html = html:gsub("[Vv][Bb][Ss][Cc][Rr][Ii][Pp][Tt]%s*:", "")
    html = html:gsub("[Dd][Aa][Tt][Aa]%s*:", "")
    return html
end

-- strict: a template error fails the message instead of sending the error comment.
-- Only the HTML body is HTML-escaped; subject and plain text are not HTML.
local function render_str(tpl, data, html)
    if type(tpl) ~= "string" or tpl == "" then return "" end
    local ok, out = pcall(TemplateRenderer.render, tpl, data or {}, { strict = true, escape_html = html })
    if not ok then return nil, tostring(out) end
    return out
end

function C.validate_message(message, ctx)
    if type(message) ~= "table" then return nil, "message required" end
    if not message.subject or message.subject == "" then return nil, "subject required" end
    if #(message.subject or "") > 998 then return nil, "subject too long" end
    if not message.html and not message.text then return nil, "html or text body required" end
    local caps = C.capabilities()
    if message.html and #message.html > caps.max_body_len then return nil, "html too large" end
    local to = message.to or (ctx and ctx.address)
    if not U.norm_email(to) then return nil, "invalid recipient email" end
    return true
end

function C.render(template, merge_context, ctx)
    ctx = ctx or {}
    local data = merge_context or {}
    -- Templates link the opt-out with {{unsubscribe_url}}.
    if ctx.unsubscribe_url and data.unsubscribe_url == nil then data.unsubscribe_url = ctx.unsubscribe_url end
    local subject, serr = render_str(template.subject or "", data, false)
    if not subject then return nil, "subject render failed: " .. tostring(serr) end
    local html, herr = render_str(template.body_html or template.html or "", data, true)
    if not html then return nil, "html render failed: " .. tostring(herr) end
    local text_src = template.body_text or template.text or ""
    if text_src == "" then text_src = (template.body_html or template.html or ""):gsub("<[^>]+>", " ") end
    local text, terr = render_str(text_src, data, false)
    if not text then return nil, "text render failed: " .. tostring(terr) end

    html = strip_dangerous(html)
    -- Footer: who sent it (PECR / CAN-SPAM) and a working unsubscribe link, unless the
    -- template already links the real unsubscribe URL (the word alone isn't enough).
    local foot, text_foot = {}, {}
    if type(ctx.sender_address) == "string" and ctx.sender_address:match("%S") then
        foot[#foot + 1] = (ctx.sender_address:gsub("[<>&\"]",
            { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" }))
        text_foot[#text_foot + 1] = ctx.sender_address
    end
    if ctx.unsubscribe_url and not html:find(ctx.unsubscribe_url, 1, true) then
        foot[#foot + 1] = '<a href="' .. ctx.unsubscribe_url .. '">Unsubscribe</a>'
    end
    if #foot > 0 then
        html = html .. '<p style="max-width:600px;margin:16px auto 0;font-family:Helvetica,Arial,sans-serif;'
            .. 'font-size:12px;line-height:1.5;color:#6b7280;text-align:center">' .. table.concat(foot, " · ") .. "</p>"
    end
    if ctx.unsubscribe_url and not text:find(ctx.unsubscribe_url, 1, true) then
        text_foot[#text_foot + 1] = "Unsubscribe: " .. ctx.unsubscribe_url
    end
    if #text_foot > 0 then text = text .. "\n\n" .. table.concat(text_foot, "\n") end
    if ctx.link_rewriter then
        html = Links.rewrite_html(html, ctx.link_rewriter, ctx.link_skip)
        text = Links.rewrite_text(text, ctx.link_rewriter, ctx.link_skip)
    end
    if type(ctx.preheader) == "string" and ctx.preheader ~= "" then
        -- Inbox preview line; hidden in the body. Padding stops clients pulling body text in.
        local pre = ctx.preheader:gsub("[<>&\"]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;" })
        html = '<div style="display:none;max-height:0;overflow:hidden;opacity:0;mso-hide:all">' .. pre
            .. string.rep("&#847;&zwnj;&nbsp;", 40) .. "</div>" .. html
    end
    if ctx.open_pixel_url then
        html = html .. '<img src="' .. ctx.open_pixel_url
            .. '" width="1" height="1" alt="" style="display:none" />'
    end

    return {
        channel = "email",
        subject = subject,
        html = html,
        text = text,
        headers = ctx.headers or {},
    }
end

-- The first non-empty string.
local function first(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" and v ~= "" then return v end
    end
end

--- Is an SMTP failure worth retrying? 4xx replies (mailbox busy, rate limited) and
-- connection problems are temporary; 5xx replies (unknown address, refused) are not.
function C.temporary(err)
    err = tostring(err or "")
    -- lua-resty-mail: "SMTP response was not successful: 550 ..." / "connect failure: timeout"
    local code = err:match("not successful:%s*(%d)%d%d")
    if code then return code == "4" end
    return err:find("connect", 1, true) ~= nil or err:find("timeout", 1, true) ~= nil
        or err:find("closed", 1, true) ~= nil or err:find("refused", 1, true) ~= nil
end

function C.send(payload, recipient, ctx)
    ctx = ctx or {}
    local settings = ctx.settings or {}

    if settings.dry_run == true or ctx.dry_run == true then
        return {
            state = "accepted",
            provider_message_id = "dry-run-" .. tostring(ctx.delivery_uuid or ngx.now()),
            reason = "dry_run",
        }
    end

    -- The workspace's own SMTP (Workspace -> Email) when it has one, else the deployment's.
    -- ctx.smtp is looked up by the caller (false = none) so this makes no database call.
    local ns = ctx.namespace_id
    local smtp = ctx.smtp
    if smtp == nil and ns then smtp = NamespaceMail.smtp(ns) or false end
    if not smtp and not Mail.isConfigured() then
        local env = os.getenv("LAPIS_ENVIRONMENT") or "development"
        if env ~= "production" then
            return {
                state = "accepted",
                provider_message_id = "sink-" .. tostring(ctx.delivery_uuid or ngx.now()),
                reason = "smtp_sink",
            }
        end
        return { state = "failed", reason = "smtp_not_configured" }
    end

    -- From: the campaign's, else the workspace SMTP's, else the plugin default, else the
    -- deployment's (helper/mail.lua). The plugin default no longer hides the workspace name.
    local msg = {
        to = recipient.address or recipient.email,
        subject = payload.subject,
        html = payload.html,
        text = payload.text,
        from_email = first(ctx.from_email, smtp and smtp.from_email, settings.default_from_email),
        from_name = first(ctx.from_name, smtp and smtp.from_name, settings.default_from_name),
        reply_to = first(ctx.reply_to, smtp and smtp.reply_to),
        smtp = smtp or nil,
        sync = true,
        headers = payload.headers,
    }

    if ctx.unsubscribe_url then
        msg.headers = msg.headers or {}
        msg.headers["List-Unsubscribe"] = "<" .. ctx.unsubscribe_url .. ">"
        msg.headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    end

    -- The workspace's SMTP host must still be public (no SSRF into the cluster; DNS can change).
    if smtp then
        local okh, herr = NamespaceMail.hostOk(smtp.host)
        if not okh then
            herr = "workspace SMTP: " .. tostring(herr)
            return { state = "failed", reason = herr:sub(1, 200), retry = herr:find("DNS", 1, true) ~= nil }
        end
    end
    local ok, err = Mail.send(msg)
    if not ok then
        return { state = "failed", reason = tostring(err):sub(1, 200), retry = C.temporary(err) }
    end
    -- Accepted by provider ≠ delivered. Delivery webhooks update state later.
    return { state = "accepted", provider_message_id = nil, reason = "smtp_accepted" }
end

function C.parse_webhook(request, _ctx)
    local body = request and request.body or {}
    local event = body.event or body.type or body.notificationType
    local state = "unknown"
    if event == "bounce" or event == "Bounce" then state = "bounced"
    elseif event == "complaint" or event == "Complaint" then state = "complained"
    elseif event == "delivery" or event == "Delivery" then state = "delivered"
    end
    local bounce = body.bounce
    local addr = body.email
    if not addr and type(bounce) == "table" and type(bounce.bouncedRecipients) == "table"
        and bounce.bouncedRecipients[1] then
        addr = bounce.bouncedRecipients[1].emailAddress
    end
    local mid = body.messageId
    if not mid and type(body.mail) == "table" then mid = body.mail.messageId end
    return { state = state, provider_message_id = mid, address = addr, raw_type = event }
end

return C
