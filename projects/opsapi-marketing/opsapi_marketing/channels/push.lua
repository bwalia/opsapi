-- Push channel adapter: FCM/APNs via helper/push-notification.lua.
local Push = require("helper.push-notification")
local TemplateRenderer = require("lib.template-renderer")

local C = {}

function C.capabilities()
    return {
        supports_html = false,
        supports_tracking_pixel = false,
        supports_link_rewrite = false,
        max_body_len = 2000,
        requires_verified_sender = false,
    }
end

function C.validate_message(message, _ctx)
    if type(message) ~= "table" then return nil, "message required" end
    if not message.title and not message.text then return nil, "title or text required" end
    return true
end

function C.render(template, merge_context, _ctx)
    local data = merge_context or {}
    local title = template.subject or template.title or ""
    local body = template.body_text or template.text or ""
    local ok_t, t = pcall(TemplateRenderer.render, title, data)
    local ok_b, b = pcall(TemplateRenderer.render, body, data)
    if not ok_t then return nil, tostring(t) end
    if not ok_b then return nil, tostring(b) end
    return { channel = "push", title = t, text = b }
end

function C.send(payload, recipient, ctx)
    ctx = ctx or {}
    local settings = ctx.settings or {}
    if settings.dry_run == true or ctx.dry_run == true then
        return {
            state = "accepted",
            provider_message_id = "dry-run-push-" .. tostring(ctx.delivery_uuid or ngx.now()),
            reason = "dry_run",
        }
    end
    local user_uuid = recipient.user_uuid or recipient.address
    if not user_uuid then return { state = "failed", reason = "missing_user_uuid" } end
    local ok, err = Push.sendToUsers({ user_uuid }, {
        title = payload.title or "Notification",
        body = payload.text or "",
    }, ctx.data or {})
    if not ok then
        return { state = "failed", reason = tostring(err):sub(1, 200) }
    end
    return { state = "accepted", reason = "push_accepted" }
end

function C.parse_webhook(_request, _ctx)
    return { state = "unknown" }
end

return C
