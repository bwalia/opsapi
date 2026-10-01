-- Tell Slack when a ticket is escalated — a custom event emitted by
-- api/escalate.lua. Set PLUGIN_HELPDESK_SLACK_URL (an incoming-webhook URL)
-- on the OpsAPI container to turn it on.
local cjson = require("cjson")
local sdk = require("helper.plugin-sdk")

return {
    ["helpdesk.ticket.escalated"] = function(event)
        local url = sdk.env("PLUGIN_HELPDESK_SLACK_URL")
        if not url then return end
        local http = require("resty.http").new()
        http:set_timeouts(2000, 5000, 5000)
        local res, err = http:request_uri(url, {
            method = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body = cjson.encode({ text = "Ticket escalated: " .. (event.data.title or event.data.uuid) }),
        })
        if not res or res.status >= 300 then
            return false, err or ("Slack answered " .. res.status) -- retried with backoff
        end
    end,
}
