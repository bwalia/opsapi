--[[
    Webhook dispatcher
    ==================
    Generic outgoing webhooks. On a content event, POST a signed (HMAC-SHA256)
    payload to every active webhook a tenant registered for that event. This is
    how a consumer (e.g. a website) learns a post changed — OPSAPI knows nothing
    about the consumer beyond the URL + secret it stored.

    Guarantees (it runs on the content-save path):
      * Non-blocking — deliveries run in ngx.timer(0), AFTER the response, so a
        slow/down consumer never delays or fails saving a post.
      * Never throws — pcall-wrapped; a bug here can't break a create/update/delete.

    Signature: header `X-Opsapi-Signature-256: sha256=<hex>` = HMAC-SHA256 of the
    raw JSON body with the webhook's secret. The receiver recomputes and compares.
]]

local CmsWebhookQueries = require "queries.CmsWebhookQueries"
local cjson = require "cjson"

local WebhookDispatcher = {}

local function sign(secret, body)
    local ok, hmac = pcall(require, "resty.hmac")
    local ok2, resty_string = pcall(require, "resty.string")
    if not (ok and ok2) then return nil end
    local h = hmac:new(secret, hmac.ALGOS.SHA256)
    if not h then return nil end
    h:update(body)
    return "sha256=" .. resty_string.to_hex(h:final())
end

-- ngx.timer callback: one delivery, outside the request.
local function deliver(premature, webhook, event, body, signature)
    if premature then return end
    local ok, http = pcall(require, "resty.http")
    if not ok then return end
    local httpc = http.new()
    httpc:set_timeout(10000)
    local res, err = httpc:request_uri(webhook.url, {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "opsapi-webhooks",
            ["X-Opsapi-Event"] = event,
            ["X-Opsapi-Signature-256"] = signature,
        },
        body = body,
        ssl_verify = os.getenv("OPSAPI_SSL_VERIFY") ~= "false",
    })
    local status = res and res.status or 0
    CmsWebhookQueries.recordDelivery(webhook.id, status)
    if not res then
        ngx.log(ngx.ERR, "webhook: POST ", webhook.url, " failed: ", tostring(err))
    elseif status >= 400 then
        ngx.log(ngx.WARN, "webhook: ", webhook.url, " -> HTTP ", status, " (", event, ")")
    else
        ngx.log(ngx.NOTICE, "webhook: delivered ", event, " -> ", webhook.url, " (", status, ")")
    end
end

--- Emit an event to every active webhook for a namespace. Never blocks/throws.
-- @param namespace_id number
-- @param event string   one of post.created | post.updated | post.deleted
-- @param data table     the payload's `data` field (e.g. { uuid, slug, status })
function WebhookDispatcher.emit(namespace_id, event, data)
    local ok, err = pcall(function()
        if not (ngx and ngx.timer and ngx.timer.at) then return end
        local webhooks = CmsWebhookQueries.activeForEvent(namespace_id, event)
        if #webhooks == 0 then return end

        local body = cjson.encode({
            event = event,
            namespace_id = namespace_id,
            data = data or {},
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        })

        for _, w in ipairs(webhooks) do
            local signature = sign(w.secret, body)
            if signature then
                ngx.timer.at(0, deliver, w, event, body, signature)
            else
                ngx.log(ngx.ERR, "webhook: could not sign payload for ", tostring(w.url))
            end
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "webhook dispatcher error: ", tostring(err))
    end
end

return WebhookDispatcher
