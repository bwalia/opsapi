-- Approvals (SPEC §3.5, hard rule 6: nothing leaves the system without a named human's approval).
--   GET  /approvals/inbox           pending approvals I may decide, with the agent run behind each
--   POST /approvals                 ask for approval { subject_type, action, title, payload, rule?, deal_uuid?, task_uuid? }
--   POST /approvals/:id/decide      { decision: approve|reject, note?, payload? (edited version),
--                                     payload_version?, payload_sha256? (the version you looked at) }
--   POST /approvals/:id/retry       run a failed approved action again (managers)
--   POST /bookings/:id/confirm      ask to confirm one supplier's slot { slot_start?, slot_end?, cost?, body? }
-- Rules and the executor: property_deals/approvals.lua, property_deals/ai/executor.lua.
-- Sending payload_version (or payload_sha256) makes the decision fail with 409
-- if the draft changed after you opened it (ios-approval-version-guard).
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local cjson = require("cjson")
local U = require("property_deals.util")
local Approvals = require("property_deals.approvals")

local SUBJECTS = { "agent_draft", "chase", "booking", "compliance_close", "offer", "deal_pack", "stage_gate", "other" }
local RULES = { "any_operator", "manager", "two_person" }

return function(app)
    app:get("/approvals/inbox", sdk.handler({ permission = "property_deals_approvals.read" }, function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local manager = sdk.can(self, "property_deals_approvals", "manage")
        local rows = db.query([[
            SELECT a.*, cd.name AS deal_name, t.title AS task_title,
                   r.agent_key, r.provider, r.model, r.cost_usd, r.tokens_in, r.tokens_out, r.sources AS run_sources,
                   r.steps AS run_steps, r.output AS run_output,
                   (r.provider = 'jobshout' OR a.jobshout_approval_id IS NOT NULL) AS from_jobshout,
                   (a.rule <> 'manager' OR ?) AND a.requested_by_user_uuid IS DISTINCT FROM ?
                     AND NOT (a.decisions @> ?::jsonb) AS can_decide
            FROM property_deals_approvals a
            LEFT JOIN property_deals_agent_runs r ON r.uuid = a.agent_run_uuid
            LEFT JOIN property_deals_deals dl ON dl.uuid = a.deal_uuid
            LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
            LEFT JOIN kanban_tasks t ON t.uuid = a.task_uuid
            WHERE a.namespace_id = ? AND a.status = 'pending'
            ORDER BY a.created_at
        ]], manager, me, cjson.encode({ { user_uuid = me } }), ns)
        local mine = {}
        for _, r in ipairs(rows) do
            if self.params.all == "true" or r.can_decide then mine[#mine + 1] = r end
        end
        return sdk.ok(sdk.array(mine), { total = #mine })
    end))

    app:post("/approvals", sdk.handler({ permission = "property_deals_approvals.create" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, {
            subject_type = { required = true, enum = SUBJECTS },
            action = { type = "string", required = true, max = 40 },
            title = { type = "string", required = true },
            payload = { type = "json", required = true },
            rule = { enum = RULES },
            deal_uuid = { type = "uuid" }, task_uuid = { type = "uuid" }, agent_run_uuid = { type = "uuid" },
            expires_at = { type = "datetime" },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        data.requested_by_user_uuid = me
        if Approvals.is_agent(ns, me) then data.requested_by_agent = "service_account" end
        return sdk.created(Approvals.create(ns, data))
    end)))

    app:post("/approvals/:id/decide", sdk.handler({ permission = "property_deals_approvals.update" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, {
            decision = { required = true, enum = { "approve", "reject" } },
            note = { type = "text" },
            payload = { type = "json", label = "Edited payload (approve only)" },
            payload_version = { type = "integer", min = 1, label = "Version you looked at" },
            payload_sha256 = { type = "string", max = 64, label = "Hash of the version you looked at" },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        if data.decision == "reject" and not data.note then
            return sdk.error(422, "Validation failed", { note = "say why it is rejected (the agent can retry with it)" })
        end
        if data.decision == "reject" and data.payload then
            return sdk.error(422, "Validation failed", { payload = "only an approval can carry an edited version" })
        end
        local row = Approvals.decide(ns, self.params.id, me, data, sdk.can(self, "property_deals_approvals", "manage"))
        return sdk.ok(row)
    end)))

    app:post("/approvals/:id/retry", sdk.handler({ permission = "property_deals_approvals.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local a = Approvals.get(ns, self.params.id)
        if not a then return sdk.not_found("Approval") end
        if a.status ~= "failed" then return sdk.error(409, "Only a failed action can be retried (this one is " .. a.status .. ")") end
        local res, err = Approvals.execute(ns, a.uuid, sdk.user(self).uuid)
        local row = Approvals.get(ns, a.uuid)
        if not res then return sdk.error(422, err or "Failed again", { approval = row }) end
        return sdk.ok(row)
    end)))

    app:post("/bookings/:id/confirm", sdk.handler({ permission = "property_deals_suppliers.update" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, {
            slot_start = { type = "datetime" }, slot_end = { type = "datetime" }, cost = { type = "number", min = 0 },
            subject = { type = "string" }, body = { type = "text" },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        local ns = sdk.namespace_id(self)
        local b = U.is_uuid(self.params.id) and U.one([[
            SELECT b.*, a.name AS supplier_name FROM property_deals_bookings b
            JOIN property_deals_suppliers s ON s.uuid = b.supplier_uuid JOIN crm_accounts a ON a.uuid = s.account_uuid
            WHERE b.namespace_id = ? AND b.uuid = ?
        ]], ns, self.params.id)
        if not b then return sdk.not_found("Booking") end
        if b.status ~= "requested" and b.status ~= "tentative" then
            return sdk.error(409, "This booking is " .. b.status)
        end
        local when = data.slot_start and (" on " .. data.slot_start) or ""
        local subject = data.subject or ("Booking confirmed" .. when .. (b.deal_uuid ~= db.NULL
            and (" " .. require("property_deals.ai.agents").ref(b.deal_uuid)) or ""))
        local a = Approvals.create(ns, {
            subject_type = "booking", action = "confirm_booking", rule = "any_operator",
            title = "Confirm " .. tostring(b.service):gsub("_", " ") .. " with " .. tostring(b.supplier_name) .. when,
            payload = { booking_uuid = b.uuid, slot_start = data.slot_start, slot_end = data.slot_end, cost = data.cost,
                subject = subject, body = data.body or ("Thank you — please go ahead with the booking" .. when .. ".") },
            task_uuid = b.task_uuid ~= db.NULL and b.task_uuid or nil,
            deal_uuid = b.deal_uuid ~= db.NULL and b.deal_uuid or nil,
            requested_by_user_uuid = sdk.user(self).uuid,
        })
        if b.status == "requested" then
            db.update("property_deals_bookings", { status = "tentative", slot_start = data.slot_start,
                slot_end = data.slot_end, updated_at = db.raw("NOW()") }, { id = b.id })
        end
        return sdk.created(a)
    end)))
end
