-- Tell Slack when a ticket is escalated — a custom event emitted by
-- api/escalate.lua. Each workspace sets its own Slack webhook URL under
-- Workspace -> Plugins -> Helpdesk; PLUGIN_HELPDESK_SLACK_URL on the OpsAPI
-- container is the fallback for every workspace.
local cjson = require("cjson")
local sdk = require("helper.plugin-sdk")

return {
    ["helpdesk.ticket.escalated"] = function(event)
        local url = event.settings.slack_webhook_url or sdk.env("PLUGIN_HELPDESK_SLACK_URL")
        if not url then return end
        -- sdk.http refuses internal addresses: the URL comes from a workspace.
        local res, err = sdk.http(url, {
            method = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body = cjson.encode({ text = "Ticket escalated: " .. (event.data.title or event.data.uuid) }),
            timeout_ms = 5000,
        })
        if not res or res.status >= 300 then
            return false, err or ("Slack answered " .. res.status) -- retried with backoff
        end
    end,
}
