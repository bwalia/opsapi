-- Inbound email from people we have an opportunity with goes onto their timeline (Outlook / Gmail / IMAP via the
-- Property Deals mail connectors, which run their own mail_sync job).
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

return {
    every = "5m",
    run = function(job)
        -- The mail comes from Property Deals' connectors: nothing to import while it is off here.
        if not require("property_pa.setup").deals_on(job.namespace_id) then return end
        require("property_pa.integrations").mail_import(job.namespace_id, 14)
    end,
}
