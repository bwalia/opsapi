-- SMS channel adapter: Android SMS Gateway / generic HTTP provider (property-deals pattern).
local cjson = require("cjson")
local TemplateRenderer = require("lib.template-renderer")
local U = require("opsapi_marketing.util")

local C = {}

local STOP_WORDS = {
    stop = true, unsubscribe = true, cancel = true, ["end"] = true, quit = true,
}

function C.capabilities()
    return {
        supports_html = false,
        supports_tracking_pixel = false,
        supports_link_rewrite = true,
        max_body_len = 1600, -- concatenated SMS
        requires_verified_sender = false,
        gsm7_single = 160,
        unicode_single = 70,
    }
end

function C.is_stop_keyword(text)
    if type(text) ~= "string" then return false end
    local t = text:lower():match("^%s*(.-)%s*$")
    return STOP_WORDS[t] == true
end

function C.validate_message(message, ctx)
    if type(message) ~= "table" then return nil, "message required" end
    local text = message.text or message.body_text
    if not text or text == "" then return nil, "text required" end
    if #text > C.capabilities().max_body_len then return nil, "text too long" end
    local to = message.to or (ctx and ctx.address)
    if not U.e164(to) then return nil, "invalid E.164 phone" end
    return true
end

function C.render(template, merge_context, ctx)
    local data = merge_context or {}
    local src = template.body_text or template.text or ""
    local ok, text = pcall(TemplateRenderer.render, src, data)
    if not ok then return nil, "sms render failed: " .. tostring(text) end
    text = tostring(text):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    if ctx and ctx.unsubscribe_hint ~= false then
        if not text:lower():find("stop", 1, true) then
            text = text .. " Reply STOP to opt out."
        end
    end
    if #text > C.capabilities().max_body_len then
        return nil, "rendered sms too long"
    end
    return { channel = "sms", text = text }
end

function C.send(payload, recipient, ctx)
    ctx = ctx or {}
    local settings = ctx.settings or {}
    local to = U.e164(recipient.address or recipient.phone)
    if not to then return { state = "failed", reason = "invalid_phone" } end

    if settings.dry_run == true or ctx.dry_run == true then
        return {
            state = "accepted",
            provider_message_id = "dry-run-sms-" .. tostring(ctx.delivery_uuid or ngx.now()),
            reason = "dry_run",
        }
    end

    local base = settings.sms_gateway_url
    if type(base) ~= "string" or base == "" then
        local env = os.getenv("LAPIS_ENVIRONMENT") or "development"
        if env ~= "production" then
            return {
                state = "accepted",
                provider_message_id = "sink-sms-" .. tostring(ctx.delivery_uuid or ngx.now()),
                reason = "sms_sink",
            }
        end
        return { state = "failed", reason = "sms_gateway_not_configured" }
    end

    base = base:gsub("/+$", "")
    local user = settings.sms_gateway_username or ""
    local pass = settings.sms_gateway_password or ""
    local auth
    if user ~= "" then
        auth = "Basic " .. ngx.encode_base64(user .. ":" .. pass)
    end

    local res, err = require("helper.plugin-sdk").http(base .. "/message", {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            Authorization = auth,
        },
        body = cjson.encode({
            message = payload.text,
            phoneNumbers = { to },
        }),
        timeout_ms = 15000,
    })
    if not res then
        return { state = "failed", reason = tostring(err):sub(1, 200) }
    end
    local status = res.status or 0
    if status < 200 or status >= 300 then
        return { state = "failed", reason = "sms_http_" .. tostring(status) }
    end
    return { state = "accepted", provider_message_id = nil, reason = "sms_accepted" }
end

function C.parse_webhook(request, _ctx)
    local body = request and request.body or {}
    local text = body.message or body.text or body.body or ""
    if C.is_stop_keyword(text) then
        return {
            state = "opt_out",
            address = body.phone or body.from or body.sender,
            keyword = text:lower():match("^%s*(.-)%s*$"),
        }
    end
    return {
        state = "inbound",
        address = body.phone or body.from,
        text = text,
    }
end

return C
