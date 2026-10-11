-- Week 4 "Work": the manager's day, measurement, integrations, and a go-live checklist.
--   GET  /manager/today                 exceptions only: handoffs waiting, unusual negotiations, relationship and deal
--                                       risks, overdue actions, top opportunities (managers)
--   GET  /metrics                       is the PA working? ?days=30 (managers)
--   POST /integrations/mail/import      inbound email (Outlook / Gmail / IMAP connectors) onto timelines
--   POST /integrations/ghl/sync         pull GoHighLevel contacts now (managers; also hourly)
--   POST /runs/sweep                    poll PA runs whose webhook hasn't come, fail ones stuck past the timeout
--                                       (managers; the pa_runs job does this every 2 minutes)
--   GET  /status                        what is set up and what isn't, for going live with a real agent
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local M = require("property_pa.manager")
local I = require("property_pa.integrations")

local function manager_only(self)
    if not sdk.can(self, "property_pa_knowledge", "manage") then return sdk.error(403, "For managers") end
end

local function set(v) return type(v) == "string" and v ~= "" end

return function(app)
    app:get("/manager/today", sdk.handler({ permission = "property_pa_handoffs.read" }, U.guard(function(self)
        local denied = manager_only(self)
        if denied then return denied end
        return sdk.ok(M.today(sdk.namespace_id(self), sdk.user(self).uuid))
    end)))

    app:get("/metrics", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local denied = manager_only(self)
        if denied then return denied end
        local days = tonumber(self.params.days) or 30
        if days < 1 or days > 365 or days % 1 ~= 0 then return sdk.error(422, "Validation failed", { days = "1 to 365" }) end
        return sdk.ok(M.metrics(sdk.namespace_id(self), days))
    end)))

    app:post("/integrations/mail/import", sdk.handler({ permission = "property_pa_records.create" }, U.guard(function(self)
        return sdk.ok(I.mail_import(sdk.namespace_id(self), 14))
    end)))

    app:post("/integrations/ghl/sync", sdk.handler({ permission = "property_pa_knowledge.manage" }, U.guard(function(self)
        local out, err = I.ghl_sync(sdk.namespace_id(self), sdk.settings(self), sdk.user(self).uuid)
        if not out then return sdk.error(err and err:find("^Set the") and 409 or 502, err) end
        return sdk.ok(out)
    end)))

    app:post("/runs/sweep", sdk.handler({ permission = "property_pa_knowledge.manage" }, U.guard(function(self)
        return sdk.ok(require("property_pa.bridge").sweep(sdk.namespace_id(self)))
    end)))

    app:get("/status", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local ns, st = sdk.namespace_id(self), sdk.settings(self)
        local link = set(st.jobshout_provider_uuid) and U.is_uuid(st.jobshout_provider_uuid) and U.one([[SELECT uuid, enabled,
            last_error FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ? AND provider_type = 'jobshout']],
            ns, st.jobshout_provider_uuid)
        local mail = U.one([[SELECT COUNT(*)::int AS n FROM property_deals_mail_connectors WHERE namespace_id = ?]], ns)
        local knowledge = U.one("SELECT COUNT(*)::int AS n FROM pa_knowledge WHERE namespace_id = ? AND status = 'approved'", ns)
        local checks = {
            { key = "playbook", ok = knowledge.n > 0, text = knowledge.n .. " approved rules", fix = "POST /setup" },
            { key = "jobshout_link", ok = link and link.enabled == true or false,
              text = link and "JobShout link set" or "No JobShout link", fix = "Workspace -> AI providers, then the PA settings" },
            { key = "seller_agent", ok = set(st.jobshout_seller_agent_id), text = "Seller PA agent id",
              fix = "JobShout POST /property-pa/install, then the PA settings" },
            { key = "manager_agent", ok = set(st.jobshout_manager_agent_id), text = "Manager PA agent id",
              fix = "JobShout POST /property-pa/install, then the PA settings" },
            { key = "webhook", ok = st.jobshout_webhook_secret ~= nil and st.jobshout_webhook_secret ~= "",
              text = "Webhook secret (answers arrive without waiting for a poll)", fix = "PA settings + JobShout webhook endpoint" },
            { key = "speech", ok = set(os.getenv("PA_STT_URL")) or set(os.getenv("VOICE_URL")),
              text = "Speech-to-text for voice notes", fix = "PA_STT_URL on the server" },
            { key = "mail", ok = mail.n > 0, text = mail.n .. " mailbox connector(s) (Outlook / Gmail / IMAP)",
              fix = "Property Deals -> Settings -> Mail", optional = true },
            { key = "ghl", ok = set(st.ghl_location_id) and st.ghl_token ~= nil and st.ghl_token ~= "",
              text = "GoHighLevel contacts", fix = "PA settings: location id and token", optional = true },
        }
        local ready = true
        for _, c in ipairs(checks) do if not c.ok and not c.optional then ready = false end end
        return sdk.ok({ ready = ready, checks = sdk.array(checks),
            limits = { running_per_person = require("property_pa.bridge").MAX_RUNNING,
                       per_person_per_hour = require("property_pa.bridge").MAX_PER_HOUR,
                       run_timeout_minutes = require("property_pa.bridge").TIMEOUT_MINUTES } })
    end)))
end
