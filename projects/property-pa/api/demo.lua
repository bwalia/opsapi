-- Demo data for the How It Works scenes (fake people, fake numbers). Only rows tagged as fixtures are touched.
--   POST   /demo/reset   { sophie_user_uuid?, ashley_user_uuid? } wipe and re-seed the fixtures (managers)
--   DELETE /demo         remove the fixtures
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local FX = require("property_pa.fixtures")

local function member(ns, uuid)
    return U.one([[SELECT 1 FROM users u JOIN namespace_members m ON m.user_id = u.id AND m.namespace_id = ?
        WHERE u.uuid = ?]], ns, uuid) ~= nil
end

return function(app)
    app:post("/demo/reset", sdk.handler({ permission = "property_pa_knowledge.manage" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local d, errors = sdk.validate(body, { sophie_user_uuid = { type = "string", max = 64 },
            ashley_user_uuid = { type = "string", max = 64 } })
        if not d then return sdk.error(422, "Validation failed", errors) end
        for k, v in pairs(d) do
            if not member(ns, v) then return sdk.error(422, "Validation failed", { [k] = "not a member of this workspace" }) end
        end
        return sdk.ok(FX.reset(ns, d.sophie_user_uuid or me, d.ashley_user_uuid or me))
    end)))

    app:delete("/demo", sdk.handler({ permission = "property_pa_knowledge.manage" }, U.guard(function(self)
        return sdk.ok({ removed_opportunities = U.tx(function() return FX.clear(sdk.namespace_id(self)) end) })
    end)))
end
