--[[
    Webhook dispatcher — manual, user-controlled delivery
    =====================================================
    Content changes do NOT fire webhooks automatically. Instead a person triggers
    a webhook deliberately (e.g. from the post editor's publish modal, or the
    Webhooks tab) so they can batch several edits and notify once. `trigger()`
    delivers ONE signed webhook synchronously and returns the result, so the UI
    can show success/failure.

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

--- Deliver one signed webhook synchronously.
-- @param webhook table  a cms_webhooks row (url, secret, namespace_id, id)
-- @param event string   e.g. "post.published"
-- @param data table     payload data (e.g. { uuid, slug, status })
-- @return ok (boolean), status (number|nil), err (string|nil)
function WebhookDispatcher.trigger(webhook, event, data)
    event = event or "manual.trigger"
    local body = cjson.encode({
        event = event,
        namespace_id = webhook.namespace_id,
        data = data or {},
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
    local signature = sign(webhook.secret, body)
    if not signature then return false, nil, "could not sign payload" end

    local ok, http = pcall(require, "resty.http")
    if not ok then return false, nil, "resty.http not available" end
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
        return false, nil, tostring(err)
    end
    if status >= 400 then
        ngx.log(ngx.WARN, "webhook: ", webhook.url, " -> HTTP ", status, " (", event, ")")
        return false, status, "receiver returned HTTP " .. status
    end
    ngx.log(ngx.NOTICE, "webhook: delivered ", event, " -> ", webhook.url, " (", status, ")")
    return true, status, nil
end

return WebhookDispatcher
