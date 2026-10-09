-- Daily digest (rules-based):
--   GET  /digest           the signed-in person's digest for today, built now
--   GET  /digest/history   digests sent to me (latest first)
--   POST /digest/send      send today's digests now (once per person per day; managers)
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local Digest = require("property_deals.digest")

return function(app)
    app:get("/digest", sdk.handler({ permission = "property_deals_tasks.read" }, U.guard(function(self)
        local d = Digest.build(sdk.namespace_id(self), sdk.user(self).uuid, sdk.settings(self))
        d.summary = Digest.summary(d)
        return sdk.ok(d)
    end)))

    app:get("/digest/history", sdk.handler({ permission = "property_deals_tasks.read" }, function(self)
        local page, per_page, offset = sdk.page(self.params)
        local rows = sdk.db.query([[
            SELECT local_date, payload, empty, created_at FROM property_deals_digest_log
            WHERE namespace_id = ? AND user_uuid = ? ORDER BY local_date DESC LIMIT ? OFFSET ?
        ]], sdk.namespace_id(self), sdk.user(self).uuid, per_page, offset)
        return sdk.ok(sdk.array(rows), { page = page, per_page = per_page })
    end))

    app:post("/digest/send", sdk.handler({ permission = "property_deals_settings.manage" }, U.guard(function(self)
        local sent = Digest.run(sdk.namespace_id(self), sdk.settings(self), true)
        return sdk.ok({ sent = sent })
    end)))
end
