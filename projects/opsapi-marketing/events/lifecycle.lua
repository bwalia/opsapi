-- React to marketing outbox events (idempotent on event.id).
local sdk = require("helper.plugin-sdk")

return {
    ["opsapi_marketing.subscription.opted_out"] = function(event)
        -- Suppression already written in eligibility.opt_out; log only.
        ngx.log(ngx.NOTICE, "[opsapi_marketing] opted_out ns=", tostring(event.namespace_id),
            " event=", tostring(event.id))
    end,

    ["opsapi_marketing.campaign.scheduled"] = function(event)
        ngx.log(ngx.NOTICE, "[opsapi_marketing] campaign scheduled ns=", tostring(event.namespace_id),
            " event=", tostring(event.id))
    end,

    ["opsapi_marketing.delivery.accepted"] = function(event)
        -- Hook for analytics rollups later; must be idempotent.
        if not event.namespace_id then return end
    end,
}
