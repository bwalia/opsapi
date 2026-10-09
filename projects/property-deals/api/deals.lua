-- Deals: /api/v2/property-deals/deals
--   GET    /deals          list  ?stage_key=&status=&health=&deal_type=&property_uuid=&owner_user_uuid=&q=&sort=
--   GET    /deals/:id      one deal (CRM fields + extension + property summary)
--   POST   /deals          create (from lead_uuid, contact_uuid, or neither)
--   PUT    /deals/:id      update extension fields (target dates re-time the tasks that count from them)
--   GET    /deals/:id/gate?to=   what stops the deal entering a stage (default: the next one)
--   POST   /deals/:id/stage      { to } move (409 with details.missing when the gate isn't met)
--   POST   /deals/:id/advance    move to the next stage that applies
--   GET    /deals/:id/health     health, reasons, money at risk, completion forecast (recomputed now)
-- Deal parties (buyers, sellers, solicitors...): /deal-parties CRUD.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local Deals = require("property_deals.deals")
local Engine = require("property_deals.engine")
local Health = require("property_deals.health")

local CREATE = {
    lead_uuid = { type = "uuid" },
    contact_uuid = { type = "uuid" },
    name = { type = "string" },
    deal_type = { enum = { "buy", "sell", "buy_and_assign", "sourcing" } },
    template = { type = "string", max = 80, label = "Template uuid or key" },
    property_uuid = { type = "uuid" },
    offer_amount = { type = "number", min = 0 },
    agreed_price = { type = "number", min = 0 },
    currency = { type = "string", min = 3, max = 3 },
    fees = { type = "json" },
    finance_route = { type = "string", max = 30 },
    target_exchange_date = { type = "date" },
    target_completion_date = { type = "date" },
    late_penalty_per_day = { type = "number", min = 0 },
    late_penalty_cap_days = { type = "integer", min = 0 },
    notes = { type = "text" },
}

return function(app)
    app:get("/deals", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local rows, meta = Deals.list(sdk.namespace_id(self), self.params)
        return sdk.ok(rows, meta)
    end))

    app:get("/deals/:id", sdk.handler({ permission = "property_deals_deals.read" }, function(self)
        local deal = Deals.get(sdk.namespace_id(self), self.params.id)
        if not deal then return sdk.not_found("Deal") end
        return sdk.ok(deal)
    end))

    app:post("/deals", sdk.handler({ permission = "property_deals_deals.create" }, U.guard_create(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, CREATE)
        if not data then return sdk.error(422, "Validation failed", errors) end
        if data.lead_uuid and data.contact_uuid then
            return sdk.error(422, "Validation failed", { lead_uuid = "give lead_uuid or contact_uuid, not both" })
        end
        local ns, settings = sdk.namespace_id(self), sdk.settings(self)
        local deal = Deals.create(ns, data, sdk.user(self).uuid, settings)
        Health.recompute_deal(ns, deal.uuid, settings)
        return sdk.created(Deals.get(ns, deal.uuid))
    end)))

    app:put("/deals/:id", sdk.handler({ permission = "property_deals_deals.update" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, Deals.UPDATABLE, true)
        if not data then return sdk.error(422, "Validation failed", errors) end
        local ns = sdk.namespace_id(self)
        local deal = Deals.update(ns, self.params.id, data, sdk.user(self).uuid)
        if not deal then return sdk.not_found("Deal") end
        Health.recompute_deal(ns, deal.uuid, sdk.settings(self))
        return sdk.ok(Deals.get(ns, deal.uuid))
    end)))

    -- What stops the deal entering a stage: GET /deals/:id/gate?to=<stage key>
    app:get("/deals/:id/gate", sdk.handler({ permission = "property_deals_deals.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local ctx = Engine.context(ns, self.params.id, sdk.settings(self))
        if not ctx then return sdk.not_found("Deal") end
        local to = self.params.to or Engine.next_stage(ctx)
        if not to then return sdk.error(422, "Validation failed", { to = "the deal is at its last stage" }) end
        local gate, err = Engine.gate(ctx, to)
        if not gate then return sdk.error(422, "Validation failed", { to = err }) end
        return sdk.ok(gate)
    end)))

    -- Move a deal: POST /deals/:id/stage { to }. 409 + details.missing when the gate isn't met.
    app:post("/deals/:id/stage", sdk.handler({ permission = "property_deals_deals.update" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, { to = { type = "string", required = true, max = 80 } })
        if not data then return sdk.error(422, "Validation failed", errors) end
        local ns, settings = sdk.namespace_id(self), sdk.settings(self)
        local created = U.tx(function() return Engine.move(ns, self.params.id, data.to, sdk.user(self).uuid, settings) end)
        Health.recompute_deal(ns, self.params.id, settings)
        return sdk.ok({ deal = Deals.get(ns, self.params.id), tasks_created = sdk.array(created) })
    end)))

    -- Move to the next stage that applies: POST /deals/:id/advance
    app:post("/deals/:id/advance", sdk.handler({ permission = "property_deals_deals.update" }, U.guard(function(self)
        local ns, settings = sdk.namespace_id(self), sdk.settings(self)
        local ctx = Engine.context(ns, self.params.id, settings)
        if not ctx then return sdk.not_found("Deal") end
        local to = Engine.next_stage(ctx)
        if not to then return sdk.error(409, "The deal is at its last stage") end
        local created = U.tx(function() return Engine.move(ns, self.params.id, to, sdk.user(self).uuid, settings) end)
        Health.recompute_deal(ns, self.params.id, settings)
        return sdk.ok({ deal = Deals.get(ns, self.params.id), tasks_created = sdk.array(created) })
    end)))

    -- Health, money at risk and the completion forecast, recomputed now:
    -- GET /deals/:id/health
    app:get("/deals/:id/health", sdk.handler({ permission = "property_deals_deals.read" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        if not Deals.get(ns, self.params.id) then return sdk.not_found("Deal") end
        local r = Health.recompute_deal(ns, self.params.id, sdk.settings(self))
        local deal = Deals.get(ns, self.params.id)
        return sdk.ok({
            health = deal.health, reasons = deal.health_reasons, money_at_risk = deal.money_at_risk,
            predicted_completion_date = deal.predicted_completion_date,
            target_completion_date = deal.target_completion_date,
            facts = r and {
                working_days_left = r.facts.wd_left, open_blocking_tasks = r.facts.open_blocking_tasks,
                overdue_blocking_tasks = r.facts.overdue_blocking, open_blocking_enquiries = r.facts.open_blockers,
                hours_since_third_party_reply = math.floor(r.facts.silence_hours), days_late = r.facts.days_late,
                days_at_risk = r.facts.days_at_risk, slip = r.facts.slip_detail,
            } or require("cjson").null,
        })
    end)))

    sdk.crud(app, "/deal-parties", {
        table = "property_deals_deal_parties",
        module = "property_deals_deals",
        fields = {
            deal_uuid = { type = "uuid", required = true, label = "Deal" },
            role = { required = true, enum = { "buyer", "seller", "buyer_solicitor", "seller_solicitor", "lender",
                                               "broker", "surveyor", "estate_agent", "freeholder", "managing_agent", "other" } },
            contact_uuid = { type = "uuid", label = "Contact" },
            account_uuid = { type = "uuid", label = "Company" },
            is_primary = { type = "boolean" },
            notes = { type = "text" },
        },
        filterable = { "deal_uuid", "role", "contact_uuid", "account_uuid" },
        sortable = { "role", "created_at" },
    })
end
