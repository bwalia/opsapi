--[[
    Billing — Plans catalogue
    =========================

    Dynamic, namespace-scoped plans (subscription | one_time) with lazy Stripe
    Product/Price sync. Plans are our source of truth; Stripe objects are
    created on demand and re-pointed when a price-affecting field changes
    (Stripe Prices are immutable).

    Endpoints:
      POST   /api/v2/billing/plans              (auth, owner)  create
      GET    /api/v2/billing/plans              (auth)         list (namespace)
      GET    /api/v2/billing/plans/:uuid        (auth)         get one
      PUT    /api/v2/billing/plans/:uuid        (auth, owner)  update
      DELETE /api/v2/billing/plans/:uuid        (auth, owner)  soft delete
      POST   /api/v2/billing/plans/:uuid/sync   (auth, owner)  retry Stripe sync
      GET    /api/v2/public/billing/plans?ns=…  (public)       active plans (pricing page)

    Amounts are MINOR units (pence).
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local PaymentProvider = require("lib.payment-provider")
local BillingPlanQueries = require("queries.BillingPlanQueries")
local NamespaceQueries = require("queries.NamespaceQueries")

-- Fields whose change requires a new Stripe Price (Prices are immutable).
local PRICE_FIELDS = { "amount", "currency", "billing_interval", "interval_count", "plan_type" }

return function(app)
    local function parse_json_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, data = pcall(cjson.decode, body)
        return ok and data or {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    -- Billing management is a namespace-admin action: the owner, a platform
    -- admin, or anyone holding the namespace.manage permission. (hasPermission
    -- already returns true for owners and platform admins.)
    local function is_manager(self)
        return NamespaceMiddleware.hasPermission(self, "namespace", "manage")
    end

    -- Public projection — never leak Stripe ids or internal columns.
    local function public_plan(p)
        return {
            uuid = p.uuid,
            name = p.name,
            description = p.description,
            plan_type = p.plan_type,
            amount = tonumber(p.amount),
            currency = p.currency,
            billing_interval = p.billing_interval,
            interval_count = tonumber(p.interval_count),
            trial_days = tonumber(p.trial_days),
            features = p.features,
        }
    end

    -- Best-effort Stripe sync for a freshly created/updated plan. Never throws;
    -- returns a sync_error string (or nil) to surface in the response.
    local function try_sync(plan)
        if not PaymentProvider.stripe_configured() then
            return nil, "Stripe not configured; plan saved without a Stripe price"
        end
        local stripe = PaymentProvider.get_stripe()
        if not stripe then return nil, "Stripe not configured" end
        local _, serr = BillingPlanQueries.ensureStripeSync(plan, stripe)
        return BillingPlanQueries.getByUuid(plan.uuid), serr
    end

    -- ----------------------------------------------------------------------
    -- POST /api/v2/billing/plans
    -- ----------------------------------------------------------------------
    app:post("/api/v2/billing/plans", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            if not is_manager(self) then
                return api_response(403, nil, "Only a namespace owner can manage plans")
            end
            local body = parse_json_body()

            local ok, verr = BillingPlanQueries.validate(body)
            if not ok then
                return api_response(400, nil, verr)
            end

            local plan = BillingPlanQueries.create({
                namespace_id = self.namespace.id,
                name = body.name,
                description = body.description,
                plan_type = body.plan_type or "subscription",
                amount = body.amount,
                currency = body.currency or "gbp",
                billing_interval = body.billing_interval,
                interval_count = body.interval_count,
                trial_days = body.trial_days,
                features = body.features,
                active = (body.active ~= false),
                sort_order = tonumber(body.sort_order) or 0,
                metadata = body.metadata,
            })
            if not plan then
                return api_response(500, nil, "Failed to create plan")
            end

            local synced, sync_error = try_sync(plan)
            local row = BillingPlanQueries.decode_row(synced or BillingPlanQueries.getByUuid(plan.uuid))
            return {
                status = 201,
                json = { success = true, data = row, sync_error = sync_error },
            }
        end)
    ))

    -- ----------------------------------------------------------------------
    -- GET /api/v2/billing/plans
    -- ----------------------------------------------------------------------
    app:get("/api/v2/billing/plans", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local plans = BillingPlanQueries.listByNamespace(self.namespace.id, {
                include_inactive = self.params.include_inactive == "true",
                plan_type = self.params.plan_type,
            })
            return api_response(200, plans)
        end)
    ))

    -- ----------------------------------------------------------------------
    -- GET /api/v2/billing/plans/:uuid
    -- ----------------------------------------------------------------------
    app:get("/api/v2/billing/plans/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local plan = BillingPlanQueries.getByUuid(self.params.uuid)
            if not plan then
                return api_response(404, nil, "Plan not found")
            end
            if tonumber(plan.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end
            return api_response(200, BillingPlanQueries.decode_row(plan))
        end)
    ))

    -- ----------------------------------------------------------------------
    -- PUT /api/v2/billing/plans/:uuid
    -- ----------------------------------------------------------------------
    app:put("/api/v2/billing/plans/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            if not is_manager(self) then
                return api_response(403, nil, "Only a namespace owner can manage plans")
            end
            local plan = BillingPlanQueries.getByUuid(self.params.uuid)
            if not plan then
                return api_response(404, nil, "Plan not found")
            end
            if tonumber(plan.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            local body = parse_json_body()

            -- Validate the merged result so partial updates stay consistent.
            local merged = {
                name = body.name ~= nil and body.name or plan.name,
                plan_type = body.plan_type ~= nil and body.plan_type or plan.plan_type,
                amount = body.amount ~= nil and body.amount or plan.amount,
                billing_interval = body.billing_interval ~= nil and body.billing_interval or plan.billing_interval,
            }
            local ok, verr = BillingPlanQueries.validate(merged)
            if not ok then
                return api_response(400, nil, verr)
            end

            -- Did a price-affecting field change?
            local price_changed = false
            for _, f in ipairs(PRICE_FIELDS) do
                if body[f] ~= nil and tostring(body[f]) ~= tostring(plan[f]) then
                    price_changed = true
                    break
                end
            end

            local fields = {}
            for _, f in ipairs({ "name", "description", "plan_type", "amount", "currency",
                "billing_interval", "interval_count", "trial_days", "features", "sort_order", "metadata" }) do
                if body[f] ~= nil then fields[f] = body[f] end
            end
            if body.active ~= nil then fields.active = (body.active == true) end

            local sync_error
            local updated = BillingPlanQueries.update(self.params.uuid, fields)
            if not updated then
                return api_response(500, nil, "Failed to update plan")
            end

            -- Reconcile Stripe (best-effort): update the product, and when a
            -- price-affecting field changed, archive the old (immutable) price
            -- and let ensureStripeSync create a fresh one.
            if PaymentProvider.stripe_configured() then
                local stripe = PaymentProvider.get_stripe()
                if stripe then
                    if plan.stripe_product_id and plan.stripe_product_id ~= ""
                        and (body.name ~= nil or body.description ~= nil) then
                        stripe:update_product(plan.stripe_product_id,
                            { name = updated.name, description = updated.description })
                    end
                    if price_changed and plan.stripe_price_id and plan.stripe_price_id ~= "" then
                        stripe:update_price(plan.stripe_price_id, { active = false })
                        BillingPlanQueries.clearStripePrice(self.params.uuid)
                    end
                    local _, serr = BillingPlanQueries.ensureStripeSync(
                        BillingPlanQueries.getByUuid(self.params.uuid), stripe)
                    sync_error = serr
                end
            end

            local row = BillingPlanQueries.decode_row(BillingPlanQueries.getByUuid(self.params.uuid))
            return { status = 200, json = { success = true, data = row, sync_error = sync_error } }
        end)
    ))

    -- ----------------------------------------------------------------------
    -- DELETE /api/v2/billing/plans/:uuid
    -- ----------------------------------------------------------------------
    app:delete("/api/v2/billing/plans/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            if not is_manager(self) then
                return api_response(403, nil, "Only a namespace owner can manage plans")
            end
            local plan = BillingPlanQueries.getByUuid(self.params.uuid)
            if not plan then
                return api_response(404, nil, "Plan not found")
            end
            if tonumber(plan.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            -- Best-effort archive the Stripe product/price so it can't be bought.
            if PaymentProvider.stripe_configured() then
                local stripe = PaymentProvider.get_stripe()
                if stripe then
                    if plan.stripe_price_id and plan.stripe_price_id ~= "" then
                        stripe:update_price(plan.stripe_price_id, { active = false })
                    end
                    if plan.stripe_product_id and plan.stripe_product_id ~= "" then
                        stripe:update_product(plan.stripe_product_id, { active = false })
                    end
                end
            end

            BillingPlanQueries.softDelete(self.params.uuid)
            return api_response(200, { message = "Plan deleted" })
        end)
    ))

    -- ----------------------------------------------------------------------
    -- POST /api/v2/billing/plans/:uuid/sync — retry Stripe sync
    -- ----------------------------------------------------------------------
    app:post("/api/v2/billing/plans/:uuid/sync", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            if not is_manager(self) then
                return api_response(403, nil, "Only a namespace owner can manage plans")
            end
            local plan = BillingPlanQueries.getByUuid(self.params.uuid)
            if not plan then
                return api_response(404, nil, "Plan not found")
            end
            if tonumber(plan.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end
            if not PaymentProvider.stripe_configured() then
                return api_response(503, nil, "Billing is not configured")
            end
            local stripe = PaymentProvider.get_stripe()
            local _, serr = BillingPlanQueries.ensureStripeSync(plan, stripe)
            if serr then
                return api_response(502, nil, serr)
            end
            return api_response(200, BillingPlanQueries.decode_row(BillingPlanQueries.getByUuid(self.params.uuid)))
        end)
    ))

    -- ----------------------------------------------------------------------
    -- GET /api/v2/public/billing/plans?ns=<namespace_uuid|slug> — pricing page
    -- ----------------------------------------------------------------------
    app:get("/api/v2/public/billing/plans", function(self)
        local ns = self.params.ns
        if not ns or ns == "" then
            return api_response(400, nil, "ns (namespace) is required")
        end
        local namespace = NamespaceQueries.findByIdentifier(ns)
        if not namespace then
            return api_response(404, nil, "Namespace not found")
        end
        local plans = BillingPlanQueries.listByNamespace(namespace.id, { include_inactive = false })
        local out = {}
        for i = 1, #plans do
            out[i] = public_plan(plans[i])
        end
        return api_response(200, out)
    end)
end
