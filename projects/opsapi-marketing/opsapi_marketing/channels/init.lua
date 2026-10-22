-- Channel provider registry. Push and webhook were removed: CRM contacts have no
-- device token or endpoint URL, so those campaigns could never deliver.
local R = {
    email = require("opsapi_marketing.channels.email"),
    sms = require("opsapi_marketing.channels.sms"),
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
