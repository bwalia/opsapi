-- PA runs whose webhook didn't arrive are polled; runs that never finish are failed after 30 minutes.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

return {
    every = "2m",
    run = function(job)
        local out = require("property_pa.bridge").sweep(job.namespace_id)
        if out.timed_out > 0 then ngx.log(ngx.WARN, "[property_pa] ", out.timed_out, " PA run(s) timed out") end
    end,
}
