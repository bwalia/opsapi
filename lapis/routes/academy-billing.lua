--[[
    Academy Billing Routes (Stripe Connect — per-creator marketplace)
    =================================================================

    Creator (auth + namespace + RBAC "courses"):
      POST /api/v2/academy/creator/connect/onboard   -> Connect onboarding URL
      GET  /api/v2/academy/creator/account           -> onboarding status + plan
      PUT  /api/v2/academy/creator/subscription-plan -> set community price

    Learner (auth; namespace by slug):
      GET  /api/v2/public/academy/:namespace/me/entitlements

    Reuses lib/stripe.lua (the existing platform Stripe client, which already
    supports Connect pass-throughs) and lib/billing-urls.lua (server-controlled
    redirect URLs). opsapi remains the source of truth for entitlements.
]]

local cJson = require("cjson")
local Stripe = require("lib.stripe")
local CreatorQueries = require("queries.CreatorQueries")
local EnrollmentQueries = require("queries.EnrollmentQueries")
local EntitlementQueries = require("queries.EntitlementQueries")
local NamespaceQueries = require("queries.NamespaceQueries")
local BillingUrls = require("lib.billing-urls")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

return function(app)
    local function parse_body()
        ngx.req.read_body()
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then return post_args end
        local body = ngx.req.get_body_data()
        if not body or body == "" then
            local path = ngx.req.get_body_file()
            if path then
                local f = io.open(path, "rb")
                if f then body = f:read("*a"); f:close() end
            end
        end
        if not body or body == "" then return {} end
        local ok, decoded = pcall(cJson.decode, body)
        if ok and type(decoded) == "table" then return decoded end
        local args = ngx.decode_args(body)
        return type(args) == "table" and args or {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    local CREATOR_PATH = "/dashboard/academy/creator"

    ---------------------------------------------------------------------------
    -- CREATOR: Connect onboarding
    ---------------------------------------------------------------------------

    app:post("/api/v2/academy/creator/connect/onboard", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "manage", function(self)
            local ns = self.namespace
            local acc = CreatorQueries.getOrCreateAccount(ns.id)
            local stripe = Stripe.new()

            if not acc.stripe_account_id or acc.stripe_account_id == "" then
                local account, err = stripe:create_account({
                    email = self.current_user and self.current_user.email,
                    metadata = { namespace_id = tostring(ns.id), namespace_slug = ns.slug },
                })
                if not account then
                    return api_response(502, nil, "Could not create Stripe account: " .. tostring(err))
                end
                CreatorQueries.update(ns.id, { stripe_account_id = account.id, onboarding_status = "pending" })
                acc.stripe_account_id = account.id
            end

            local return_url = BillingUrls.dashboard_url(ns.id, "ACADEMY_CREATOR_PATH", CREATOR_PATH, { connect = "done" })
            local refresh_url = BillingUrls.dashboard_url(ns.id, "ACADEMY_CREATOR_PATH", CREATOR_PATH, { connect = "refresh" })
            local link, lerr = stripe:create_account_link({
                account = acc.stripe_account_id,
                return_url = return_url,
                refresh_url = refresh_url,
            })
            if not link then
                return api_response(502, nil, "Could not create onboarding link: " .. tostring(lerr))
            end
            return { status = 200, json = { url = link.url } }
        end)))

    ---------------------------------------------------------------------------
    -- CREATOR: account status (refreshes from Stripe)
    ---------------------------------------------------------------------------

    app:get("/api/v2/academy/creator/account", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "read", function(self)
            local ns = self.namespace
            local acc = CreatorQueries.getAccount(ns.id)
            if not acc then
                return { status = 200, json = { onboarded = false, status = "none", charges_enabled = false } }
            end

            if acc.stripe_account_id and acc.stripe_account_id ~= "" then
                local stripe = Stripe.new()
                local account = stripe:retrieve_account(acc.stripe_account_id)
                if account then
                    local status = (account.details_submitted and account.charges_enabled) and "complete" or "pending"
                    CreatorQueries.update(ns.id, {
                        charges_enabled = account.charges_enabled or false,
                        payouts_enabled = account.payouts_enabled or false,
                        onboarding_status = status,
                    })
                    acc.charges_enabled = account.charges_enabled or false
                    acc.onboarding_status = status
                end
            end

            local plan = CreatorQueries.getActivePlan(ns.id)
            return { status = 200, json = {
                onboarded = acc.onboarding_status == "complete",
                status = acc.onboarding_status,
                charges_enabled = acc.charges_enabled or false,
                plan = plan and { amount = plan.amount, currency = plan.currency, interval = plan.interval } or nil,
            } }
        end)))

    ---------------------------------------------------------------------------
    -- CREATOR: set community subscription price
    ---------------------------------------------------------------------------

    app:put("/api/v2/academy/creator/subscription-plan", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "manage", function(self)
            local ns = self.namespace
            local body = parse_body()
            local amount = tonumber(body.amount)
            if not amount or amount <= 0 then
                return api_response(400, nil, "amount (in minor units, e.g. 999 = $9.99) is required")
            end
            local interval = (body.interval == "year") and "year" or "month"
            local currency = body.currency or "usd"

            local acc = CreatorQueries.getAccount(ns.id)
            if not acc or not acc.charges_enabled then
                return api_response(400, nil, "Complete Stripe onboarding before setting a price")
            end

            local stripe = Stripe.new()
            local product, perr = stripe:create_product({
                name = (ns.name or ns.slug) .. " membership",
                metadata = { namespace_id = tostring(ns.id) },
            })
            if not product then return api_response(502, nil, "Stripe product failed: " .. tostring(perr)) end

            local price, prerr = stripe:create_price({
                product = product.id,
                unit_amount = math.floor(amount),
                currency = currency,
                recurring = { interval = interval },
            })
            if not price then return api_response(502, nil, "Stripe price failed: " .. tostring(prerr)) end

            local plan = CreatorQueries.upsertPlan(ns.id, {
                stripe_price_id = price.id,
                interval = interval,
                amount = math.floor(amount),
                currency = currency,
            })
            return { status = 200, json = { amount = plan.amount, currency = plan.currency, interval = plan.interval } }
        end)))

    ---------------------------------------------------------------------------
    -- LEARNER: my entitlements within a community
    ---------------------------------------------------------------------------

    app:get("/api/v2/public/academy/:namespace/me/entitlements", AuthMiddleware.requireAuth(function(self)
        local ns = NamespaceQueries.findBySlug(self.params.namespace)
        if not ns then return api_response(404, nil, "Namespace not found") end

        local uuid = self.current_user and self.current_user.uuid
        local sub = uuid and EntitlementQueries.activeSubscription(uuid, ns.id) or nil
        local enrolled = uuid and EnrollmentQueries.listCoursesForUser(ns.id, uuid) or {}
        local ids = {}
        for _, c in ipairs(enrolled) do table.insert(ids, c.uuid) end

        return { status = 200, json = {
            has_subscription = sub ~= nil,
            subscription = sub and { status = sub.status, current_period_end = sub.current_period_end } or nil,
            enrolled_course_ids = ids,
        } }
    end))
end
