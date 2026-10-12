-- Nightly at 03:00 UTC, per workspace: the words of PA interactions older than the workspace's retention_text_days
-- (default 365, like Property Deals' inbox retention) are removed: note text, voice transcripts, imported email
-- bodies. The interaction stays (who, when, channel, subject, summary), so timelines and metrics keep working.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

return {
    every = "1d",
    at = "03:00",
    run = function(job)
        local n = require("property_pa.interactions").redact(job.namespace_id, job.settings.retention_text_days)
        if n > 0 then ngx.log(ngx.NOTICE, "[property_pa] retention ns=", job.namespace_id, " redacted=", n) end
    end,
}
