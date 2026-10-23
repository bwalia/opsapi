-- Leased job: claim due campaigns, enqueue recipients, dispatch queued deliveries.
-- Backbone = Postgres + plugin-jobs (NOT Kafka).
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local db = require("lapis.db")
local U = require("opsapi_marketing.util")
local Send = require("opsapi_marketing.send")

return {
    every = "1m",
    run = function(job)
        local ns = job.namespace_id

        -- Promote due scheduled campaigns
        local due = db.query([[
            SELECT id, uuid, name FROM mkt_campaigns
            WHERE namespace_id = ?
              AND status = 'scheduled'
              AND scheduled_at IS NOT NULL
              AND scheduled_at <= NOW()
            ORDER BY scheduled_at ASC
            LIMIT 10
            FOR UPDATE SKIP LOCKED
        ]], ns)

        for _, c in ipairs(due) do
            local ok, err = pcall(Send.start_campaign, ns, c.id)
            if not ok then
                ngx.log(ngx.ERR, "[opsapi_marketing] start_campaign ", c.uuid, ": ", tostring(err))
                db.query("UPDATE mkt_campaigns SET status = 'failed', updated_at = NOW() WHERE id = ?", c.id)
            end
        end

        -- Dispatch due queued deliveries, as many as the per-minute rate setting allows
        -- (re-checks can_send per message)
        local out = Send.process_queue(ns)
        if out.sent + out.skipped + out.failed > 0 then
            ngx.log(ngx.NOTICE, "[opsapi_marketing] ns=", ns,
                " sent=", out.sent, " skipped=", out.skipped, " failed=", out.failed)
        end

        -- Mark campaigns complete when nothing is queued or mid-send
        db.query([[
            UPDATE mkt_campaigns c SET status = 'completed', completed_at = NOW(), updated_at = NOW()
            WHERE c.namespace_id = ? AND c.status = 'sending'
              AND NOT EXISTS (
                SELECT 1 FROM mkt_deliveries d
                WHERE d.campaign_id = c.id AND d.state IN ('queued', 'sending')
              )
              AND EXISTS (
                SELECT 1 FROM mkt_deliveries d2 WHERE d2.campaign_id = c.id
              )
        ]], ns)

        assert(U) -- keep require used
    end,
}
