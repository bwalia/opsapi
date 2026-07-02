--[[
    Academy Billing Routes (platform-as-merchant-of-record)
    =======================================================

    All charges settle in the PLATFORM Stripe account (no Connect). Creators add
    bank details for manual payouts; the cut is recorded in the ledger by the
    webhook using the creator's effective fee %.

    Creator (auth + namespace + RBAC "courses"):
      GET  /api/v2/academy/creator/account            -> bank details + fee + plan + earnings
      PUT  /api/v2/academy/creator/account            -> save bank/payout details
      PUT  /api/v2/academy/creator/subscription-plan  -> set community price

    Learner (auth; namespace by slug):
      POST /api/v2/public/academy/:ns/checkout/course/:slug -> Stripe Checkout URL
      POST /api/v2/public/academy/:ns/checkout/subscription -> Stripe Checkout URL
      GET  /api/v2/public/academy/:ns/me/entitlements

    Public:
      GET  /api/v2/public/academy/:ns/plan            -> community subscription price
]]

local cJson = require("cjson")
local Stripe = require("lib.stripe")
local CreatorQueries = require("queries.CreatorQueries")
local CourseQueries = require("queries.CourseQueries")
local InstructorQueries = require("queries.InstructorQueries")
local EnrollmentQueries = require("queries.EnrollmentQueries")
local EntitlementQueries = require("queries.EntitlementQueries")
local PayoutQueries = require("queries.PayoutQueries")
local NamespaceQueries = require("queries.NamespaceQueries")
local Global = require("helper.global")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local function learner_base()
    local b = Global.getEnvVar("ACADEMY_FRONTEND_URL")
    if not b or b == "" then b = Global.getEnvVar("FRONTEND_URL") end
    if not b or b == "" then b = "http://localhost:3000" end
    return (b:gsub("/+$", ""))
end

local BANK_OUT_FIELDS = {
    "account_holder_name", "bank_name", "account_number", "routing_number",
    "sort_code", "iban", "swift_bic", "bank_country", "payout_email",
}

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

    ---------------------------------------------------------------------------
    -- CREATOR: account (bank details + fee + plan + earnings)
    ---------------------------------------------------------------------------

    app:get("/api/v2/academy/creator/account", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "read", function(self)
            local ns = self.namespace
            local uid = self.current_user and self.current_user.uuid
            -- Account, fee and earnings are per-instructor (user_uuid); the
            -- community subscription plan stays academy-wide (namespace-level).
            local acc = CreatorQueries.getAccount(uid)
            local plan = CreatorQueries.getActivePlan(ns.id)
            local earnings = PayoutQueries.earningsForInstructor(uid)
            local bank = {}
            if acc then
                for _, k in ipairs(BANK_OUT_FIELDS) do bank[k] = acc[k] end
            end
            return { status = 200, json = {
                bank = bank,
                bank_details_complete = acc and acc.bank_details_complete or false,
                fee_pct = CreatorQueries.effectiveFeePct(uid),
                plan = plan and { amount = plan.amount, currency = plan.currency, interval = plan.interval } or nil,
                earnings = {
                    total_net = tonumber(earnings.total_net) or 0,
                    owed = tonumber(earnings.owed) or 0,
                    paid = tonumber(earnings.paid) or 0,
                    currency = earnings.currency or "usd",
                    sales = tonumber(earnings.sales) or 0,
                },
            } }
        end)))

    -- Instructors (courses "update") manage their own payout bank details.
    app:put("/api/v2/academy/creator/account", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "update", function(self)
            local ns = self.namespace
            local uid = self.current_user and self.current_user.uuid
            local body = parse_body()
            local acc = CreatorQueries.updateBankDetails(uid, ns.id, body)
            return { status = 200, json = { bank_details_complete = acc.bank_details_complete } }
        end)))

    ---------------------------------------------------------------------------
    -- CREATOR: public instructor profile (bio, achievements, education, skills)
    ---------------------------------------------------------------------------

    app:get("/api/v2/academy/creator/profile", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "read", function(self)
            local uid = self.current_user and self.current_user.uuid
            return { status = 200, json = InstructorQueries.getProfile(uid) }
        end)))

    app:put("/api/v2/academy/creator/profile", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("courses", "update", function(self)
            local ns = self.namespace
            local uid = self.current_user and self.current_user.uuid
            local body = parse_body()
            -- JSON list/object fields may arrive as JSON strings (form-encoded)
            -- or as real values (JSON body); upsertProfile handles both.
            InstructorQueries.upsertProfile(uid, ns.id, {
                headline = body.headline,
                bio = body.bio,
                avatar_url = body.avatar_url,
                location = body.location,
                website = body.website,
                socials = body.socials,
                achievements = body.achievements,
                education = body.education,
                skills = body.skills,
            })
            return { status = 200, json = InstructorQueries.getProfile(uid) }
        end)))

    ---------------------------------------------------------------------------
    -- CREATOR: community subscription price (Stripe price on the PLATFORM account)
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
    -- LEARNER: checkout — one-time course purchase (charged to the platform)
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

        local amount = math.floor(tonumber(course.price) or 0)
        if amount <= 0 then return api_response(400, nil, "Invalid course price") end

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
            metadata = { kind = "course", course_id = tostring(course.id), course_uuid = course.uuid, namespace_id = tostring(ns.id), user_uuid = uuid },
        })
        if not session then return api_response(502, nil, "Checkout failed: " .. tostring(err)) end
        return { status = 200, json = { url = session.url } }
    end))

    ---------------------------------------------------------------------------
    -- LEARNER: checkout — community subscription (charged to the platform)
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

        local base = learner_base()
        local stripe = Stripe.new()
        local session, err = stripe:create_checkout_session({
            mode = "subscription",
            success_url = base .. "/dashboard?subscribed=" .. ns.slug,
            cancel_url = base .. "/courses?subscribe=cancel",
            client_reference_id = uuid,
            line_items = { { price = plan.stripe_price_id, quantity = 1 } },
            subscription_data = { metadata = { kind = "subscription", namespace_id = tostring(ns.id), user_uuid = uuid } },
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
    -- PUBLIC: a community's subscription plan (for showing the price)
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
