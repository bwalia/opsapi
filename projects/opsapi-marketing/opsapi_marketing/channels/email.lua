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
    if ctx.unsubscribe_url and not html:lower():find("unsubscribe", 1, true) then
        html = html .. '<p style="font-size:12px;color:#666"><a href="'
            .. ctx.unsubscribe_url .. '">Unsubscribe</a></p>'
    end
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

function C.send(payload, recipient, ctx)
    ctx = ctx or {}
    local settings = ctx.settings or {}
    local to = recipient.address or recipient.email
    local msg = {
        to = to,
        subject = payload.subject,
        html = payload.html,
        text = payload.text,
        from_email = (ctx.from_email and ctx.from_email ~= "") and ctx.from_email or settings.default_from_email,
        from_name = (ctx.from_name and ctx.from_name ~= "") and ctx.from_name or settings.default_from_name,
        reply_to = ctx.reply_to,
        sync = true,
        headers = payload.headers,
    }

    if settings.dry_run == true or ctx.dry_run == true then
        return {
            state = "accepted",
            provider_message_id = "dry-run-" .. tostring(ctx.delivery_uuid or ngx.now()),
            reason = "dry_run",
        }
    end

    local ns = ctx.namespace_id
    local smtp = ns and NamespaceMail.smtp(ns) or nil
    if smtp then
        msg.smtp = smtp
        msg.from_email = (msg.from_email and msg.from_email ~= "") and msg.from_email or smtp.from_email
        msg.from_name = (msg.from_name and msg.from_name ~= "") and msg.from_name or smtp.from_name
        msg.reply_to = msg.reply_to or smtp.reply_to
    elseif not Mail.isConfigured() then
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

    if ctx.unsubscribe_url then
        msg.headers = msg.headers or {}
        msg.headers["List-Unsubscribe"] = "<" .. ctx.unsubscribe_url .. ">"
        msg.headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    end

    local ok, err = Mail.send(msg)
    if not ok then
        return { state = "failed", reason = tostring(err):sub(1, 200) }
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
