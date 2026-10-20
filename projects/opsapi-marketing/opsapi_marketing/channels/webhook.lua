-- Webhook / programmatic channel: outbound HTTP via sdk.http (SSRF-checked).
local cjson = require("cjson")
local TemplateRenderer = require("lib.template-renderer")

local C = {}

function C.capabilities()
    return {
        supports_html = true,
        supports_tracking_pixel = false,
        supports_link_rewrite = false,
        max_body_len = 512 * 1024,
        requires_verified_sender = false,
    }
end

function C.validate_message(message, ctx)
    if type(message) ~= "table" then return nil, "message required" end
    local url = message.url or (ctx and ctx.address)
    if type(url) ~= "string" or not url:match("^https?://") then
        return nil, "https url required"
    end
    return true
end

function C.render(template, merge_context, _ctx)
    local data = merge_context or {}
    local body = template.body_text or template.body_html or template.text or "{}"
    local ok, out = pcall(TemplateRenderer.render, body, data)
    if not ok then return nil, tostring(out) end
    return { channel = "webhook", text = out, content_type = "application/json" }
end

function C.send(payload, recipient, ctx)
    ctx = ctx or {}
    local settings = ctx.settings or {}
    local url = recipient.address or recipient.webhook_url
    if settings.dry_run == true or ctx.dry_run == true then
        return {
            state = "accepted",
            provider_message_id = "dry-run-webhook-" .. tostring(ctx.delivery_uuid or ngx.now()),
            reason = "dry_run",
        }
    end
    local res, err = require("helper.plugin-sdk").http(url, {
        method = "POST",
        headers = { ["Content-Type"] = payload.content_type or "application/json" },
        body = payload.text or cjson.encode(payload),
        timeout_ms = 15000,
    })
    if not res then
        return { state = "failed", reason = tostring(err):sub(1, 200) }
    end
    if (res.status or 0) < 200 or (res.status or 0) >= 300 then
        return { state = "failed", reason = "webhook_http_" .. tostring(res.status) }
    end
    return { state = "accepted", reason = "webhook_accepted" }
end

function C.parse_webhook(_request, _ctx)
    return { state = "unknown" }
end

return C
