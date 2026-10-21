-- Leased job: forward pending pixel events to Meta CAPI / GA4, then prune old raw events.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local db = require("lapis.db")
local U = require("opsapi_marketing.util")
local F = require("opsapi_marketing.forwarding")

return {
    every = "1m",
    run = function(job)
        local ns = job.namespace_id
        local settings = job.settings or U.settings(ns)
        F.process(ns, settings, 200)

        local days = tonumber(settings.tracking_retention_days) or 365
        db.query([[
            DELETE FROM mkt_web_events
            WHERE id IN (
                SELECT id FROM mkt_web_events
                WHERE namespace_id = ? AND created_at < NOW() - make_interval(days => ?)
                  AND NOT is_conversion
                LIMIT 5000
            )
        ]], ns, days)
    end,
}
