local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local Channels = require("opsapi_marketing.channels")

return function(app)
    app:get("/channels", sdk.handler({ permission = "opsapi_marketing_settings.read" }, function()
        return sdk.ok(sdk.array(Channels.list()))
    end))
end
