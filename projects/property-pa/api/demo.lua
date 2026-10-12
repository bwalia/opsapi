-- Demo data for the How It Works scenes (fake people, fake numbers). Only rows tagged as fixtures are touched.
--   POST   /demo/reset   { sophie_user_uuid?, ashley_user_uuid?, story? } wipe and re-seed the fixtures;
--                         story = true adds sample history: captures, answers, handoffs, learnt rules (06-sample-data.md)
--   DELETE /demo         remove the fixtures
-- Platform admins only: a reset seeds fake people into the real CRM and re-runs setup. For everyone else the
-- routes don't exist (404, like a plugin that is off).
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

local function admin_only(fn)
    return function(self)
        if not self.is_platform_admin then return sdk.error(404, "Not found") end
        return fn(self)
    end
end

return function(app)
    app:post("/demo/reset", sdk.handler({}, admin_only(U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local d, errors = sdk.validate(body, { sophie_user_uuid = { type = "string", max = 64 },
            ashley_user_uuid = { type = "string", max = 64 }, story = { type = "boolean" } })
        if not d then return sdk.error(422, "Validation failed", errors) end
        d.sophie_user_uuid, d.ashley_user_uuid = d.sophie_user_uuid or me, d.ashley_user_uuid or me
        for k, v in pairs(d) do
            if k ~= "story" and not member(ns, v) then return sdk.error(422, "Validation failed", { [k] = "not a member of this workspace" }) end
        end
        return sdk.ok(FX.reset(ns, d.sophie_user_uuid, d.ashley_user_uuid, d.story == true, sdk.settings(self)))
    end))))

    app:delete("/demo", sdk.handler({}, admin_only(U.guard(function(self)
        local out = U.tx(function() return FX.clear(sdk.namespace_id(self)) end)
        return sdk.ok({ removed_opportunities = out.removed, kept_opportunities = out.kept })
    end))))
end
