local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local Channels = require("opsapi_marketing.channels")
local U = require("opsapi_marketing.util")

local function first(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" and v ~= "" then return v end
    end
end

return function(app)
    app:get("/channels", sdk.handler({ permission = "opsapi_marketing_settings.read" }, function()
        return sdk.ok(sdk.array(Channels.list()))
    end))

    -- How this workspace's email goes out: which SMTP (its own from Workspace -> Email, or
    -- the deployment's), the From it defaults to (a campaign can set its own), test mode,
    -- the daily limit and what's used of it. Never any credentials.
    app:get("/sending", sdk.handler({ permission = "opsapi_marketing_settings.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local settings = U.settings(ns)
        local Mail = require("helper.mail")
        local NamespaceMail = require("helper.namespace-mail")
        local own = NamespaceMail.settings(ns)
        local smtp = NamespaceMail.smtp(ns)
        local deployment = Mail.deploymentSender()
        local via = smtp and "workspace" or (deployment.configured and "deployment" or "none")
        local used = U.one([[
            SELECT COUNT(*)::int AS n FROM mkt_deliveries
            WHERE namespace_id = ? AND channel = 'email' AND attempt_key NOT LIKE 'test-%'
              AND ((state IN ('accepted', 'delivered') AND accepted_at > NOW() - interval '24 hours')
                   OR state = 'sending')
        ]], ns).n
        return sdk.ok({
            via = via,
            workspace_smtp_saved = own ~= nil,
            workspace_smtp_enabled = own ~= nil and own.enabled == true,
            host = smtp and smtp.host or (via == "deployment" and deployment.host or nil),
            from_email = first(smtp and smtp.from_email, settings.default_from_email,
                via == "deployment" and deployment.from_email or nil),
            from_name = first(smtp and smtp.from_name, settings.default_from_name,
                via == "deployment" and deployment.from_name or nil),
            dry_run = settings.dry_run == true,
            env_tag = Mail.envTag(),
            daily_limit = tonumber(settings.email_daily_limit) or 0,
            sent_last_24h = used,
            parallel = tonumber(settings.email_parallel) or 1,
            rate_per_min = tonumber(settings.email_rate_per_min) or 60,
            public_url = require("opsapi_marketing.send").public_base(settings),
            sender_address_set = tostring(settings.sender_address or ""):match("%S") ~= nil,
        })
    end))
end
