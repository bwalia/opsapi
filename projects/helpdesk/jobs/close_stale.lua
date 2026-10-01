-- Close pending tickets nobody has touched for the workspace's auto_close_days
-- (Workspace -> Plugins -> Helpdesk). Each closed ticket publishes
-- helpdesk.ticket.closed. Safe to run twice: it only touches pending tickets.
local sdk = require("helper.plugin-sdk")

return {
    every = "1h",
    run = function(job)
        local res = sdk.db.query([[
            UPDATE helpdesk_tickets SET status = 'closed', updated_at = NOW()
            WHERE namespace_id = ? AND status = 'pending'
              AND updated_at < NOW() - make_interval(days => ?)
        ]], job.namespace_id, job.settings.auto_close_days)
        if res.affected_rows > 0 then
            ngx.log(ngx.NOTICE, "[helpdesk] closed ", res.affected_rows, " stale ticket(s) in namespace ",
                job.namespace_id)
        end
    end,
}
