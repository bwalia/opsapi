-- Channel provider registry.
local R = {
    email = require("opsapi_marketing.channels.email"),
    sms = require("opsapi_marketing.channels.sms"),
    push = require("opsapi_marketing.channels.push"),
    webhook = require("opsapi_marketing.channels.webhook"),
}

local M = {}

function M.get(channel)
    return R[channel]
end

function M.list()
    local out = {}
    for name, adapter in pairs(R) do
        out[#out + 1] = { channel = name, capabilities = adapter.capabilities() }
    end
    table.sort(out, function(a, b) return a.channel < b.channel end)
    return out
end

return M
