-- Deals: /api/v2/property-deals/deals
--   GET    /deals          list  ?stage_key=&status=&health=&deal_type=&property_uuid=&owner_user_uuid=&q=&sort=
--   GET    /deals/:id      one deal (CRM fields + extension + property summary)
--   POST   /deals          create (from lead_uuid, contact_uuid, or neither)
--   PUT    /deals/:id      update extension fields (stage moves: POST /deals/:id/stage, Phase 3)
-- Deal parties (buyers, sellers, solicitors...): /deal-parties CRUD.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local U = require("property_deals.util")
local Deals = require("property_deals.deals")

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

    app:post("/deals", sdk.handler({ permission = "property_deals_deals.create" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, CREATE)
        if not data then return sdk.error(422, "Validation failed", errors) end
        if data.lead_uuid and data.contact_uuid then
            return sdk.error(422, "Validation failed", { lead_uuid = "give lead_uuid or contact_uuid, not both" })
        end
        local deal = Deals.create(sdk.namespace_id(self), data, sdk.user(self).uuid, sdk.settings(self))
        return sdk.created(deal)
    end)))

    app:put("/deals/:id", sdk.handler({ permission = "property_deals_deals.update" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local data, errors = sdk.validate(body, Deals.UPDATABLE, true)
        if not data then return sdk.error(422, "Validation failed", errors) end
        local deal = Deals.update(sdk.namespace_id(self), self.params.id, data)
        if not deal then return sdk.not_found("Deal") end
        return sdk.ok(deal)
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
