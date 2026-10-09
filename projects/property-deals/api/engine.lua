-- Run the workflow engine's checks now, for this workspace only (managers):
--   POST /engine/run { "checks": ["sla", "health", "compliance_expiry", "digest", "agents", "mail", "scout", "nightly"] }
--   (default: sla + health)
-- The same work the scheduled jobs do (jobs/*.lua); useful after bulk edits and in tests.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")

local CHECKS = { sla = true, health = true, compliance_expiry = true, digest = true, agents = true, mail = true,
    scout = true, nightly = true }

return function(app)
    app:post("/engine/run", sdk.handler({ permission = "property_deals_settings.manage" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local checks = type(body.checks) == "table" and body.checks or { "sla", "health" }
        for _, c in ipairs(checks) do
            if not CHECKS[c] then return sdk.error(422, "Validation failed", { checks = "unknown check '" .. tostring(c) .. "'" }) end
        end
        local ns, settings = sdk.namespace_id(self), sdk.settings(self)
        local out = {}
        for _, c in ipairs(checks) do
            if c == "sla" then
                out.sla = require("property_deals.sla").tick(ns, settings)
                local Metrics = require("property_deals.metrics")
                Metrics.sla(ns, out.sla)
                pcall(Metrics.gauges, ns)
            elseif c == "health" then
                out.health = { deals = require("property_deals.health").recompute_workspace(ns, settings) }
            elseif c == "compliance_expiry" then
                out.compliance_expiry = require("property_deals.compliance").expire(ns, settings)
            elseif c == "digest" then
                out.digest = { sent = require("property_deals.digest").run(ns, settings, true) }
            elseif c == "agents" then
                out.agents = require("property_deals.ai.tick").run(ns, settings)
            elseif c == "mail" then
                out.mail = require("property_deals.mail").sync_all(ns)
            elseif c == "nightly" then
                out.nightly = require("property_deals.retention").run(ns, settings)
                out.nightly.suppliers = require("property_deals.reports").update_supplier_stats(ns)
            elseif c == "scout" then
                local Scout = require("property_deals.scout")
                out.scout = Scout.run(ns, settings)
                out.scout.synced = Scout.sync(ns)
            end
        end
        return sdk.ok(out)
    end)))
end
