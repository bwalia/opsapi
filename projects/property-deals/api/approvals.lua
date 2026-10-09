-- Approvals (SPEC §3.5, hard rule 6: nothing leaves the system without a named human's approval).
--   GET  /approvals/inbox           pending approvals I may decide, with the agent run behind each
--   POST /approvals                 ask for approval { subject_type, action, title, payload, rule?, deal_uuid?, task_uuid? }
--   POST /approvals/:id/decide      { decision: approve|reject, note?, payload? (edited version) }
-- Rules: any_operator = one person with approvals.update; manager = one person with
-- approvals.manage; two_person = two different people. Nobody decides their own
-- request, and the AI service account (pd_agent) never decides. Editing the payload
-- while approving records the new version and its hash; the original is kept.
-- Approved actions are carried out by the action executor (Phase 5); until then an
-- approval ends at `approved`.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local cjson = require("cjson")
local U = require("property_deals.util")

local SUBJECTS = { "agent_draft", "chase", "booking", "compliance_close", "offer", "deal_pack", "stage_gate", "other" }
local RULES = { "any_operator", "manager", "two_person" }

local function sha256_hex(s)
    local sha = require("resty.sha256"):new()
    sha:update(s)
    return require("resty.string").to_hex(sha:final())
end

local function canonical(v)
    return cjson.encode(v == nil and cjson.null or v)
end

local function is_agent(ns, user_uuid)
    return U.one([[
        SELECT 1 FROM namespace_user_roles ur
        JOIN namespace_roles r ON r.id = ur.namespace_role_id
        JOIN namespace_members m ON m.id = ur.namespace_member_id
        JOIN users u ON u.id = m.user_id
        WHERE m.namespace_id = ? AND u.uuid = ? AND r.role_name = 'pd_agent'
    ]], ns, user_uuid) ~= nil
end

local function get(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one("SELECT * FROM property_deals_approvals WHERE namespace_id = ? AND uuid = ?", ns, id)
end

return function(app)
    app:get("/approvals/inbox", sdk.handler({ permission = "property_deals_approvals.read" }, function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local manager = sdk.can(self, "property_deals_approvals", "manage")
        local rows = db.query([[
            SELECT a.*, cd.name AS deal_name, t.title AS task_title,
                   r.agent_key, r.provider, r.model, r.cost_usd, r.tokens_in, r.tokens_out, r.sources AS run_sources,
                   (r.provider = 'jobshout') AS from_jobshout,
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

    app:post("/approvals", sdk.handler({ permission = "property_deals_approvals.create" }, U.guard(function(self)
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
        data.namespace_id = ns
        data.payload_sha256 = sha256_hex(data.payload)
        if is_agent(ns, me) then data.requested_by_agent = "service_account" end
        data.requested_by_user_uuid = me
        local row = db.insert("property_deals_approvals", data, { returning = "*" })[1]
        return sdk.created(row)
    end)))

    app:post("/approvals/:id/decide", sdk.handler({ permission = "property_deals_approvals.update" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, {
            decision = { required = true, enum = { "approve", "reject" } },
            note = { type = "text" },
            payload = { type = "json", label = "Edited payload (approve only)" },
        })
        if not data then return sdk.error(422, "Validation failed", errors) end
        if data.decision == "reject" and not data.note then
            return sdk.error(422, "Validation failed", { note = "say why it is rejected (the agent can retry with it)" })
        end
        if data.decision == "reject" and data.payload then
            return sdk.error(422, "Validation failed", { payload = "only an approval can carry an edited version" })
        end
        if is_agent(ns, me) then return sdk.error(403, "An AI agent can't decide approvals; a person must") end

        local result = U.tx(function()
            local a = U.one("SELECT * FROM property_deals_approvals WHERE namespace_id = ? AND uuid = ? FOR UPDATE",
                ns, U.is_uuid(self.params.id) and self.params.id or "00000000-0000-0000-0000-000000000000")
            if not a then U.fail(404, "Approval not found") end
            if a.status ~= "pending" then U.fail(409, "Already " .. a.status) end
            if a.requested_by_user_uuid == me then U.fail(403, "You can't decide your own request") end
            if a.rule == "manager" and not sdk.can(self, "property_deals_approvals", "manage") then
                U.fail(403, "This needs a manager's approval")
            end
            local decisions = U.json(a.decisions) or {}
            for _, d in ipairs(decisions) do
                if d.user_uuid == me then U.fail(409, "You have already approved this; it needs someone else") end
            end

            local changes = { updated_at = db.raw("NOW()") }
            local payload_text = canonical(U.json(a.payload))
            if data.payload then
                if not a.original_payload then changes.original_payload = payload_text end
                changes.payload = data.payload
                changes.payload_version = (tonumber(a.payload_version) or 1) + 1
                changes.payload_sha256 = sha256_hex(data.payload)
                payload_text = data.payload
            end
            local entry = {
                user_uuid = me, decision = data.decision, note = data.note or cjson.null,
                at = require("property_deals.workdays").now(),
                payload_version = changes.payload_version or tonumber(a.payload_version) or 1,
                payload_sha256 = changes.payload_sha256 or a.payload_sha256 or sha256_hex(payload_text),
                edited = data.payload ~= nil,
            }
            decisions[#decisions + 1] = entry
            changes.decisions = cjson.encode(U.array(decisions))

            local final
            if data.decision == "reject" then
                final = "rejected"
            else
                local approvers = 0
                for _, d in ipairs(decisions) do if d.decision == "approve" then approvers = approvers + 1 end end
                if a.rule ~= "two_person" or approvers >= 2 then final = "approved" end
            end
            if final then
                changes.status, changes.decided_at = final, db.raw("NOW()")
            end
            db.update("property_deals_approvals", changes, { id = a.id })
            if final then
                sdk.emit(ns, "property_deals.approval.decided", {
                    uuid = a.uuid, decision = final, rule = a.rule, deal_uuid = a.deal_uuid, task_uuid = a.task_uuid,
                    subject_type = a.subject_type, action = a.action, by = me,
                })
            end
            return { final = final, waiting_for = final == nil and "a second person" or nil }
        end)
        local row = get(ns, self.params.id)
        row.waiting_for = result.waiting_for
        return sdk.ok(row)
    end)))
end
