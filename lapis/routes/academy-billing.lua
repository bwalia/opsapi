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
local CourseQueries = require("queries.CourseQueries")
local EnrollmentQueries = require("queries.EnrollmentQueries")
local EntitlementQueries = require("queries.EntitlementQueries")
local NamespaceQueries = require("queries.NamespaceQueries")
local BillingUrls = require("lib.billing-urls")
local Global = require("helper.global")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local function fee_percent()
    return tonumber(Global.getEnvVar("STRIPE_PLATFORM_FEE_PERCENT")) or 0
end

local function learner_base()
    local b = Global.getEnvVar("ACADEMY_FRONTEND_URL")
    if not b or b == "" then b = Global.getEnvVar("FRONTEND_URL") end
    if not b or b == "" then b = "http://localhost:3000" end
    return (b:gsub("/+$", ""))
end

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
    -- LEARNER: checkout — one-time course purchase (Connect destination charge)
    ---------------------------------------------------------------------------

    app:post("/api/v2/public/academy/:namespace/checkout/course/:slug", AuthMiddleware.requireAuth(function(self)
        local ns = NamespaceQueries.findBySlug(self.params.namespace)
        if not ns then return api_response(404, nil, "Namespace not found") end
        local uuid = self.current_user and self.current_user.uuid
        if not uuid then return api_response(401, nil, "Authentication required") end

        local course = CourseQueries.getBySlug(ns.id, self.params.slug)
        if not course or course.status ~= "published" then return api_response(404, nil, "Course not found") end
        if course.is_free == true or course.is_free == "t" then return api_response(400, nil, "Course is free") end
        if EntitlementQueries.hasCourseAccess(uuid, course) then
            return { status = 200, json = { already_has_access = true } }
        end

        local creator = CreatorQueries.getAccount(ns.id)
        if not creator or not creator.charges_enabled or not creator.stripe_account_id then
            return api_response(400, nil, "This creator isn't set up to take payments yet")
        end

        local amount = math.floor(tonumber(course.price) or 0)
        if amount <= 0 then return api_response(400, nil, "Invalid course price") end
        local fee = math.floor(amount * fee_percent() / 100)

        local pid = {
            transfer_data = { destination = creator.stripe_account_id },
            metadata = { kind = "course", course_id = tostring(course.id), namespace_id = tostring(ns.id), user_uuid = uuid },
        }
        if fee > 0 then pid.application_fee_amount = fee end

        local base = learner_base()
        local stripe = Stripe.new()
        local session, err = stripe:create_checkout_session({
            mode = "payment",
            success_url = base .. "/courses/" .. course.slug .. "?purchase=success",
            cancel_url = base .. "/courses/" .. course.slug .. "?purchase=cancel",
            client_reference_id = uuid,
            line_items = { {
                quantity = 1,
                price_data = {
                    currency = course.currency or "usd",
                    unit_amount = amount,
                    product_data = { name = course.title },
                },
            } },
            payment_intent_data = pid,
            metadata = { kind = "course", course_id = tostring(course.id), course_uuid = course.uuid, namespace_id = tostring(ns.id), user_uuid = uuid },
        })
        if not session then return api_response(502, nil, "Checkout failed: " .. tostring(err)) end
        return { status = 200, json = { url = session.url } }
    end))

    ---------------------------------------------------------------------------
    -- LEARNER: checkout — community subscription
    ---------------------------------------------------------------------------

    app:post("/api/v2/public/academy/:namespace/checkout/subscription", AuthMiddleware.requireAuth(function(self)
        local ns = NamespaceQueries.findBySlug(self.params.namespace)
        if not ns then return api_response(404, nil, "Namespace not found") end
        local uuid = self.current_user and self.current_user.uuid
        if not uuid then return api_response(401, nil, "Authentication required") end
        if EntitlementQueries.hasActiveSubscription(uuid, ns.id) then
            return { status = 200, json = { already_subscribed = true } }
        end

        local plan = CreatorQueries.getActivePlan(ns.id)
        if not plan or not plan.stripe_price_id then return api_response(400, nil, "This community has no subscription plan") end
        local creator = CreatorQueries.getAccount(ns.id)
        if not creator or not creator.charges_enabled or not creator.stripe_account_id then
            return api_response(400, nil, "This creator isn't set up to take payments yet")
        end

        local sub_data = {
            transfer_data = { destination = creator.stripe_account_id },
            metadata = { kind = "subscription", namespace_id = tostring(ns.id), user_uuid = uuid },
        }
        local pct = fee_percent()
        if pct > 0 then sub_data.application_fee_percent = pct end

        local base = learner_base()
        local stripe = Stripe.new()
        local session, err = stripe:create_checkout_session({
            mode = "subscription",
            success_url = base .. "/dashboard?subscribed=" .. ns.slug,
            cancel_url = base .. "/courses?subscribe=cancel",
            client_reference_id = uuid,
            line_items = { { price = plan.stripe_price_id, quantity = 1 } },
            subscription_data = sub_data,
            metadata = { kind = "subscription", namespace_id = tostring(ns.id), user_uuid = uuid },
        })
        if not session then return api_response(502, nil, "Checkout failed: " .. tostring(err)) end
        return { status = 200, json = { url = session.url } }
    end))

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

    ---------------------------------------------------------------------------
    -- PUBLIC: a community's subscription plan (so the learner UI can show price)
    ---------------------------------------------------------------------------

    app:get("/api/v2/public/academy/:namespace/plan", function(self)
        local ns = NamespaceQueries.findBySlug(self.params.namespace)
        if not ns then return api_response(404, nil, "Namespace not found") end
        local plan = CreatorQueries.getActivePlan(ns.id)
        if not plan then return { status = 200, json = { has_plan = false } } end
        return { status = 200, json = {
            has_plan = true,
            plan = { amount = plan.amount, currency = plan.currency, interval = plan.interval },
        } }
    end)
end
