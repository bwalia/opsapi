-- The system of record behind the PA: opportunities, interactions, the timeline, events, offers, next actions,
-- people and the change history of any record.
--   POST   /setup                          set the workspace up for the PA (idempotent)
--   GET    /opportunities                  ?status=open&mine=true&kind=sell
--   POST   /opportunities                  a person creates one (each given field is recorded as a human fact)
--   GET    /opportunities/:id              the record + its live facts (fact vs inference), offers, events, actions
--   PUT    /opportunities/:id              a person edits fields (history kept)
--   GET    /opportunities/:id/timeline     interactions, events, offers, next actions and changes, newest first
--   GET    /people?q=                      find people by name, email, phone or their property's address
--   GET    /people/:id                     contact + roles + relationship + opportunities
--   PUT    /people/:id/consent             { consent_basis?, opted_out? } record consent or an opt-out
--   GET    /people/:id/timeline
--   POST   /interactions                   log a call / email / note / voice note (text stored as data)
--   GET    /interactions/:id
--   POST   /events                         valuation, price reduction, promise, appointment, deadline...
--   PUT    /events/:id                     { done?, title?, at?, details? } e.g. a promise kept (history kept)
--   POST   /offers                         record an offer (the person recording it is the authority)
--   PUT    /offers/:id                     { response, response_note? }
--   POST   /next-actions                   { title, due_at, reason, opportunity_uuid?, owner_user_uuid? }
--   GET    /next-actions                   ?opportunity_uuid= | ?mine=true
--   GET    /history/:table/:id             every value a field ever had: source, model, prompt version, approver
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
for _, p in ipairs({ root, root and (root:match("^(.*)/[^/]+$") .. "/property-deals") }) do
    if p and not package.path:find(p .. "/?.lua", 1, true) then package.path = p .. "/?.lua;" .. package.path end
end

local cjson = require("cjson")
local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local F = require("property_pa.facts")
local I = require("property_pa.interactions")
local A = require("property_pa.actions")

local OPP_RULES = {
    kind = { enum = { "sell", "buy" } }, title = { type = "string", max = 255 },
    person_uuid = { type = "string", max = 64 }, lead_uuid = { type = "string", max = 64 },
    property_uuid = { type = "uuid" }, deal_uuid = { type = "uuid" }, owner_user_uuid = { type = "string", max = 64 },
    motivation = { type = "text", max = 5000 }, expectation_price = { type = "number", min = 0 },
    our_position = { type = "text", max = 5000 }, temperature = { enum = { "hot", "warm", "cold" } },
    decision_makers = { type = "json" }, primary_concern = { type = "text", max = 5000 },
    status = { enum = { "open", "won", "lost", "paused" } },
}
-- Fields whose every value is kept in the fact history.
local TRACKED = { "title", "motivation", "expectation_price", "our_position", "temperature", "decision_makers",
    "primary_concern", "status" }

local function opp_row(ns, id)
    if not U.is_uuid(id) then return nil end
    local r = U.one([[
        SELECT o.*, NULLIF(TRIM(CONCAT(c.first_name, ' ', c.last_name)), '') AS person_name,
               p.address_line1 AS property_address, p.postcode AS property_postcode
        FROM pa_opportunities o LEFT JOIN crm_contacts c ON c.uuid = o.person_uuid
        LEFT JOIN property_deals_properties p ON p.uuid = o.property_uuid
        WHERE o.namespace_id = ? AND o.uuid = ?::uuid
    ]], ns, id)
    if r then
        r.decision_makers = setmetatable(U.json(r.decision_makers) or {}, cjson.array_mt)
        r.metadata = U.json(r.metadata)
        r.id = nil
    end
    return r
end

local function body_or_fail(self)
    local body, err = sdk.body(self)
    if not body then U.fail(400, err) end
    return body
end

local function valid(body, rules, partial)
    local data, errors = sdk.validate(body, rules, partial)
    if not data then U.fail(422, "Validation failed", errors) end
    return data
end

return function(app)
    app:post("/setup", sdk.handler({ permission = "property_pa_knowledge.manage" }, U.guard(function(self)
        return sdk.ok(require("property_pa.setup").run(sdk.namespace_id(self), sdk.user(self).uuid))
    end)))

    -- ------------------------------------------------------------------ opportunities
    app:get("/opportunities", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local where = { "o.namespace_id = " .. db.escape_literal(ns) }
        local p = self.params
        if p.status and p.status:match("^[a-z]+$") then where[#where + 1] = "o.status = " .. db.escape_literal(p.status) end
        if p.kind == "sell" or p.kind == "buy" then where[#where + 1] = "o.kind = " .. db.escape_literal(p.kind) end
        if p.mine == "true" then where[#where + 1] = "o.owner_user_uuid = " .. db.escape_literal(me) end
        local page, per_page, offset = sdk.page(p)
        local rows = db.query([[
            SELECT o.uuid, o.kind, o.title, o.status, o.temperature, o.expectation_price, o.owner_user_uuid,
                   o.person_uuid, NULLIF(TRIM(CONCAT(c.first_name, ' ', c.last_name)), '') AS person_name,
                   o.property_uuid, o.last_meaningful_contact_at, o.updated_at,
                   (SELECT MIN(d.due_at) FROM property_deals_task_details d WHERE d.namespace_id = o.namespace_id
                      AND d.opportunity_uuid = o.uuid AND d.pd_status NOT IN ('done', 'cancelled')) AS next_action_at,
                   COUNT(*) OVER()::int AS total
            FROM pa_opportunities o LEFT JOIN crm_contacts c ON c.uuid = o.person_uuid
            WHERE ]] .. table.concat(where, " AND ") .. [[
            ORDER BY o.last_meaningful_contact_at DESC NULLS LAST, o.id DESC LIMIT ? OFFSET ?
        ]], per_page, offset)
        local total = rows[1] and rows[1].total or 0
        for _, r in ipairs(rows) do r.total = nil end
        return sdk.ok(sdk.array(rows), { page = page, per_page = per_page, total = total })
    end)))

    app:post("/opportunities", sdk.handler({ permission = "property_pa_records.create" }, U.guard_create(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local body = body_or_fail(self)
        local data = valid(body, OPP_RULES)
        if not data.title then U.fail(422, "Validation failed", { title = "is required" }) end
        data.namespace_id = ns
        data.owner_user_uuid = data.owner_user_uuid or me
        if data.decision_makers then data.decision_makers = db.raw(db.escape_literal(data.decision_makers) .. "::jsonb") end
        local id = U.tx(function()
            local r = db.insert("pa_opportunities", data, { returning = { "uuid" } })[1]
            for _, f in ipairs(TRACKED) do
                local v = data[f]
                if v ~= nil and v ~= db.NULL then
                    if f == "decision_makers" then v = body.decision_makers end
                    F.record(ns, { target_table = "pa_opportunities", target_uuid = r.uuid, field = f, value = v,
                        action = "create", source = "human", confirmed_by = me })
                end
            end
            return r.uuid
        end)
        return { status = 201, json = { success = true, data = opp_row(ns, id) } }
    end)))

    app:get("/opportunities/:id", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local r = opp_row(ns, self.params.id)
        if not r then return sdk.not_found("Opportunity") end
        r.facts = F.current_facts(ns, "pa_opportunities", r.uuid)
        r.offers = sdk.array(db.query([[SELECT uuid, amount, currency, made_at, conditions, response, response_note,
            responded_at, authority_user_uuid FROM pa_offers WHERE namespace_id = ? AND opportunity_uuid = ?::uuid
            ORDER BY made_at DESC]], ns, r.uuid))
        r.events = sdk.array(db.query([[SELECT uuid, kind, at, title, details, done, source_interaction_uuid FROM pa_events
            WHERE namespace_id = ? AND opportunity_uuid = ?::uuid ORDER BY at DESC LIMIT 50]], ns, r.uuid))
        r.next_actions = A.open(ns, { opportunity_uuid = r.uuid })
        r.pending_updates = require("property_pa.updates").list(ns, { status = "proposed", target_uuid = r.uuid })
        return sdk.ok(r)
    end)))

    app:put("/opportunities/:id", sdk.handler({ permission = "property_pa_records.update" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local r = opp_row(ns, self.params.id)
        if not r then return sdk.not_found("Opportunity") end
        local body = body_or_fail(self)
        local rules = {}
        for _, f in ipairs(TRACKED) do rules[f] = OPP_RULES[f] end
        for _, f in ipairs({ "person_uuid", "lead_uuid", "property_uuid", "deal_uuid", "owner_user_uuid", "kind" }) do
            rules[f] = OPP_RULES[f]
        end
        local data = valid(body, rules, true)
        U.tx(function()
            local links = {}
            for k, v in pairs(data) do
                if F.TARGETS.pa_opportunities.fields[k] then
                    local value = v
                    if v == db.NULL then value = nil elseif k == "decision_makers" then value = body.decision_makers end
                    F.set(ns, { target_table = "pa_opportunities", target_uuid = r.uuid, field = k, value = value,
                        action = v == db.NULL and "clear" or "set", source = "human", confirmed_by = me })
                else
                    links[k] = v
                end
            end
            if next(links) then
                links.updated_at = db.raw("NOW()")
                db.update("pa_opportunities", links, { namespace_id = ns, uuid = r.uuid })
            end
        end)
        return sdk.ok(opp_row(ns, r.uuid))
    end)))

    app:get("/opportunities/:id/timeline", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        if not opp_row(ns, self.params.id) then return sdk.not_found("Opportunity") end
        return sdk.ok(I.timeline(ns, { opportunity_uuid = self.params.id, limit = self.params.limit }))
    end)))

    -- ------------------------------------------------------------------ people
    local function person(ns, id)
        return U.one([[SELECT uuid, first_name, last_name, email, phone, mobile, job_title, person_roles, preferred_channel,
            owner_user_uuid, created_at FROM crm_contacts WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL]],
            ns, tostring(id or ""))
    end

    -- Resolve "Sarah" / "22 Station Road" to people (name, email, phone, or the address of their opportunity).
    app:get("/people", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local q = tostring(self.params.q or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #q < 2 then return sdk.error(422, "Validation failed", { q = "at least 2 characters" }) end
        local like = "%" .. q:sub(1, 100):gsub("[%%_\\]", "\\%0") .. "%"
        return sdk.ok(sdk.array(db.query([[
            SELECT DISTINCT ON (c.id) c.uuid, c.first_name, c.last_name, c.email, c.mobile, c.person_roles,
                   o.uuid AS opportunity_uuid, o.title AS opportunity_title, p.address_line1 AS property_address
            FROM crm_contacts c
            LEFT JOIN pa_opportunities o ON o.person_uuid = c.uuid AND o.namespace_id = c.namespace_id
            LEFT JOIN property_deals_properties p ON p.uuid = o.property_uuid
            WHERE c.namespace_id = ? AND c.deleted_at IS NULL
              AND (CONCAT(c.first_name, ' ', c.last_name) ILIKE ? OR c.email ILIKE ? OR c.mobile ILIKE ?
                   OR c.phone ILIKE ? OR p.address_line1 ILIKE ?)
            ORDER BY c.id, o.updated_at DESC NULLS LAST LIMIT 20
        ]], sdk.namespace_id(self), like, like, like, like, like)))
    end)))

    app:get("/people/:id", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local p = person(ns, self.params.id)
        if not p then return sdk.not_found("Person") end
        p.person_roles = setmetatable(U.json(p.person_roles) or {}, cjson.array_mt)
        p.relationship = U.one([[SELECT strength, last_meaningful_contact_at, preferences FROM pa_relationships
            WHERE namespace_id = ? AND user_uuid = ? AND person_uuid = ?]], ns, me, p.uuid) or cjson.null
        p.opportunities = sdk.array(db.query([[SELECT uuid, kind, title, status, temperature, last_meaningful_contact_at
            FROM pa_opportunities WHERE namespace_id = ? AND person_uuid = ? ORDER BY updated_at DESC]], ns, p.uuid))
        local k = require("property_pa.consent").get(ns, p.uuid)
        p.consent_basis, p.opted_out_at = k.consent_basis, k.opted_out_at
        return sdk.ok(p)
    end)))

    -- Consent: { consent_basis?, opted_out? }. opted_out = false (a person only) lifts an opt-out.
    app:put("/people/:id/consent", sdk.handler({ permission = "property_pa_records.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local p = person(ns, self.params.id)
        if not p then return sdk.not_found("Person") end
        local K = require("property_pa.consent")
        local d = valid(body_or_fail(self), { consent_basis = { enum = K.BASES }, opted_out = { type = "boolean" } })
        local opted = d.opted_out
        if opted == db.NULL then opted = nil end
        K.set(ns, p.uuid, { consent_basis = d.consent_basis ~= db.NULL and d.consent_basis or nil, opted_out = opted,
            source = "human" })
        local k = K.get(ns, p.uuid)
        return sdk.ok({ person_uuid = p.uuid, consent_basis = k.consent_basis, opted_out_at = k.opted_out_at })
    end)))

    app:get("/people/:id/timeline", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        if not person(ns, self.params.id) then return sdk.not_found("Person") end
        return sdk.ok(I.timeline(ns, { person_uuid = self.params.id, limit = self.params.limit }))
    end)))

    -- ------------------------------------------------------------------ interactions

    app:post("/interactions", sdk.handler({ permission = "property_pa_records.create" }, U.guard_create(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local d = valid(body_or_fail(self), I.RULES)
        for k, v in pairs(d) do if v == db.NULL then d[k] = nil end end
        if not (d.raw_text or d.transcript or d.summary) then
            U.fail(422, "Validation failed", { raw_text = "raw_text, transcript or summary is required" })
        end
        return { status = 201, json = { success = true, data = I.log(ns, d, me) } }
    end)))

    app:get("/interactions/:id", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local r = I.get(sdk.namespace_id(self), tostring(self.params.id or ""))
        if not r then return sdk.not_found("Interaction") end
        return sdk.ok(r)
    end)))

    -- ------------------------------------------------------------------ events + offers
    app:post("/events", sdk.handler({ permission = "property_pa_records.create" }, U.guard_create(function(self)
        local ns = sdk.namespace_id(self)
        local body = body_or_fail(self)
        local d = valid(body, {
            kind = { enum = { "valuation", "price_reduction", "promise", "appointment", "deadline", "listing", "sstc",
                "fall_through", "other" }, required = true },
            at = { type = "datetime", required = true }, title = { type = "string", required = true },
            details = { type = "json" }, person_uuid = { type = "string", max = 64 }, property_uuid = { type = "uuid" },
            opportunity_uuid = { type = "uuid" }, deal_uuid = { type = "uuid" },
            source_interaction_uuid = { type = "string", max = 64 },
        })
        d.namespace_id = ns
        if d.details then d.details = db.raw(db.escape_literal(d.details) .. "::jsonb") end
        local r = db.insert("pa_events", d, { returning = { "uuid", "kind", "at", "title", "details", "opportunity_uuid" } })[1]
        r.details = U.json(r.details)
        return { status = 201, json = { success = true, data = r } }
    end)))

    -- Mark an event done (a promise kept, a deadline met) or correct it. Each change goes in the event's history.
    app:put("/events/:id", sdk.handler({ permission = "property_pa_records.update" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        if not U.is_uuid(self.params.id) then return sdk.not_found("Event") end
        local body = body_or_fail(self)
        -- required + partial: only the fields sent are checked, and none of them may be cleared.
        local d = valid(body, { done = { type = "boolean", required = true },
            title = { type = "string", required = true }, at = { type = "datetime", required = true },
            details = { type = "json", required = true } }, true)
        if not next(d) then U.fail(422, "Validation failed", { done = "send done, title, at or details" }) end
        local set = { updated_at = db.raw("NOW()") }
        for k, v in pairs(d) do set[k] = v end
        if d.details then set.details = db.raw(db.escape_literal(d.details) .. "::jsonb") end
        U.tx(function()
            local res = db.update("pa_events", set, { namespace_id = ns, uuid = self.params.id })
            if (res.affected_rows or 0) == 0 then U.fail(404, "Event not found") end
            for k, v in pairs(d) do
                F.record(ns, { target_table = "pa_events", target_uuid = self.params.id, field = k,
                    value = k == "details" and body.details or v, source = "human", confirmed_by = me })
            end
        end)
        local r = U.one([[SELECT uuid, kind, at, title, details, done, opportunity_uuid FROM pa_events
            WHERE namespace_id = ? AND uuid = ?::uuid]], ns, self.params.id)
        r.details = U.json(r.details)
        return sdk.ok(r)
    end)))

    app:post("/offers", sdk.handler({ permission = "property_pa_records.create" }, U.guard_create(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local d = valid(body_or_fail(self), {
            amount = { type = "number", min = 1, required = true }, opportunity_uuid = { type = "uuid" },
            deal_uuid = { type = "uuid" }, conditions = { type = "text", max = 5000 }, made_at = { type = "datetime" },
        })
        if not d.opportunity_uuid and not d.deal_uuid then
            U.fail(422, "Validation failed", { opportunity_uuid = "opportunity_uuid or deal_uuid is required" })
        end
        d.namespace_id, d.authority_user_uuid = ns, me
        local r = db.insert("pa_offers", d, { returning = { "uuid" } })[1]
        F.record(ns, { target_table = "pa_offers", target_uuid = r.uuid, field = "_create", value = { amount = d.amount },
            action = "create", source = "human", confirmed_by = me })
        return { status = 201, json = { success = true, data = U.one([[SELECT uuid, amount, currency, made_at, conditions,
            response, authority_user_uuid, opportunity_uuid FROM pa_offers WHERE uuid = ?::uuid]], r.uuid) } }
    end)))

    app:put("/offers/:id", sdk.handler({ permission = "property_pa_records.update" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        if not U.is_uuid(self.params.id) then return sdk.not_found("Offer") end
        local d = valid(body_or_fail(self), {
            response = { enum = { "pending", "accepted", "rejected", "countered", "withdrawn" }, required = true },
            response_note = { type = "text", max = 5000 },
        })
        d.responded_at, d.updated_at = db.raw("NOW()"), db.raw("NOW()")
        local res = db.update("pa_offers", d, { namespace_id = ns, uuid = self.params.id })
        if (res.affected_rows or 0) == 0 then return sdk.not_found("Offer") end
        F.record(ns, { target_table = "pa_offers", target_uuid = self.params.id, field = "response", value = d.response,
            source = "human", confirmed_by = me })
        return sdk.ok(U.one([[SELECT uuid, amount, currency, made_at, conditions, response, response_note, responded_at,
            authority_user_uuid, opportunity_uuid FROM pa_offers WHERE uuid = ?::uuid]], self.params.id))
    end)))

    -- ------------------------------------------------------------------ next actions
    app:post("/next-actions", sdk.handler({ permission = "property_pa_records.create" }, U.guard_create(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local d = valid(body_or_fail(self), {
            title = { type = "string", required = true }, due_at = { type = "datetime", required = true },
            reason = { type = "text", max = 2000, required = true }, opportunity_uuid = { type = "uuid" },
            owner_user_uuid = { type = "string", max = 64 }, lead_uuid = { type = "string", max = 64 },
            property_uuid = { type = "uuid" }, priority = { enum = { "low", "medium", "high", "urgent" } },
        })
        return { status = 201, json = { success = true, data = A.create(ns, d, me, nil, nil) } }
    end)))

    app:get("/next-actions", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        return sdk.ok(A.open(ns, { opportunity_uuid = self.params.opportunity_uuid,
            owner_user_uuid = self.params.mine == "true" and me or nil }))
    end)))

    -- ------------------------------------------------------------------ change history (P10, P11)
    app:get("/history/:table/:id", sdk.handler({ permission = "property_pa_records.read" }, U.guard(function(self)
        local t = tostring(self.params.table or "")
        if not F.TARGETS[t] and not F.CREATES[t] then return sdk.not_found("Record type") end
        local field = self.params.field
        if field and not field:match("^[a-z_]+$") then field = nil end
        return sdk.ok(F.history(sdk.namespace_id(self), t, tostring(self.params.id or ""), field))
    end)))
end
