-- GoHighLevel contacts, hourly, when the workspace has set a location and token (read only).
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

return {
    every = "1h",
    run = function(job)
        local s = job.settings or {}
        if (s.ghl_location_id or "") == "" or (s.ghl_token or "") == "" then return end
        local owner = require("lapis.db").query([[SELECT u.uuid FROM namespaces n JOIN users u ON u.id = n.owner_user_id
            WHERE n.id = ?]], job.namespace_id)[1]
        if not owner then return false, "workspace has no owner to own imported contacts" end
        local out, err = require("property_pa.integrations").ghl_sync(job.namespace_id, s, owner.uuid)
        if not out then return false, err end
    end,
}
