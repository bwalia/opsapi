--[[
    Billing & Entitlements — a customer's billing data: export and delete
    (docs/BILLING_ENTITLEMENTS.md §16).

    Delete revokes licences, ends subscriptions, removes devices, links,
    sessions and grants, and anonymises the customer. Purchases, payments,
    refunds, coupon uses and plan history stay, against the anonymised
    customer, because accounting law needs them.
]]

local db = require("lapis.db")
local Common = require("queries.FieldServiceCommon")
local EntitlementService = require("helper.entitlement-service")

local Privacy = {}

local function customer(namespace_id, uuid)
    return db.query("SELECT * FROM customers WHERE namespace_id = ? AND uuid = ?", namespace_id, uuid)[1]
end

local function rows(sql, ...)
    return Common.arr(db.query(sql, ...))
end

function Privacy.export(namespace_id, uuid)
    local c = customer(namespace_id, uuid)
    if not c then return nil, "Customer not found" end
    local id = c.id
    return {
        exported_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        customer = { uuid = c.uuid, email = c.email, first_name = c.first_name, last_name = c.last_name,
            external_id = c.external_id, created_at = c.created_at },
        subscriptions = rows([[SELECT s.uuid, a.name AS app, p.name AS plan, s.status, s.source, s.current_period_end,
                s.canceled_at, s.created_at
            FROM billing_subscriptions s JOIN billing_apps a ON a.id = s.app_id LEFT JOIN billing_plans p ON p.id = s.plan_id
            WHERE s.customer_id = ?]], id),
        purchases = rows([[SELECT pu.uuid, a.name AS app, p.name AS plan, pu.purchase_type, pu.source, pu.status,
                pu.amount, pu.currency, pu.access_until, pu.updates_until, pu.refunded_amount, pu.created_at
            FROM billing_purchases pu JOIN billing_apps a ON a.id = pu.app_id JOIN billing_plans p ON p.id = pu.plan_id
            WHERE pu.customer_id = ?]], id),
        grants = rows([[SELECT g.uuid, a.name AS app, p.name AS plan, g.features, g.reason, g.starts_at, g.expires_at,
                g.revoked_at FROM billing_grants g JOIN billing_apps a ON a.id = g.app_id
            LEFT JOIN billing_plans p ON p.id = g.plan_id WHERE g.customer_id = ?]], id),
        licences = rows([[SELECT l.uuid, a.name AS app, p.name AS plan, l.key_prefix, l.status, l.access_until,
                l.updates_until, l.created_at FROM billing_licenses l JOIN billing_apps a ON a.id = l.app_id
            LEFT JOIN billing_plans p ON p.id = l.plan_id WHERE l.customer_id = ?]], id),
        devices = rows([[SELECT l.key_prefix AS licence, x.name, x.platform, x.app_version, x.first_seen_at,
                x.last_seen_at, x.deactivated_at
            FROM billing_license_activations x JOIN billing_licenses l ON l.id = x.license_id WHERE l.customer_id = ?]], id),
        plan_changes = rows([[SELECT h.kind, a.name AS app, f.name AS from_plan, t.name AS to_plan, h.source, h.amount,
                h.currency, h.created_at FROM billing_plan_changes h JOIN billing_apps a ON a.id = h.app_id
            LEFT JOIN billing_plans f ON f.id = h.from_plan_id LEFT JOIN billing_plans t ON t.id = h.to_plan_id
            WHERE h.customer_id = ?]], id),
        coupons = rows([[SELECT co.code, r.amount_off, r.currency, r.redeemed_at FROM billing_coupon_redemptions r
            JOIN billing_coupons co ON co.id = r.coupon_id WHERE r.customer_id = ?]], id),
    }
end

function Privacy.erase(namespace_id, uuid)
    local c = customer(namespace_id, uuid)
    if not c then return nil, "Customer not found" end
    -- Stop Stripe charging them first; if Stripe can't be reached, erase nothing.
    for _, s in ipairs(db.query([[SELECT stripe_subscription_id FROM billing_subscriptions WHERE customer_id = ?
            AND namespace_id = ? AND source = 'stripe' AND stripe_subscription_id IS NOT NULL
            AND status IN ('active', 'trialing', 'past_due', 'incomplete', 'unpaid', 'paused')]], c.id, namespace_id)) do
        local ok, perr = require("lib.billing-stripe").cancelNow(s.stripe_subscription_id)
        if not ok then return nil, perr.message, perr.status or 502 end
    end
    return Common.transaction(function()
        local id = c.id
        db.query([[UPDATE billing_licenses SET status = 'revoked', revoked_at = NOW(), updated_at = NOW()
            WHERE customer_id = ? AND status <> 'revoked']], id)
        db.query([[DELETE FROM billing_license_activations x USING billing_licenses l
            WHERE l.id = x.license_id AND l.customer_id = ?]], id)
        -- (Stripe subscriptions were cancelled at Stripe above.)
        db.query([[UPDATE billing_subscriptions SET status = 'canceled', canceled_at = NOW(), updated_at = NOW()
            WHERE customer_id = ? AND status IN ('active', 'trialing', 'past_due', 'incomplete', 'unpaid', 'paused')]], id)
        db.query("DELETE FROM billing_grants WHERE customer_id = ?", id)
        db.query([[DELETE FROM billing_key_deliveries d USING billing_licenses l
            WHERE l.id = d.license_id AND l.customer_id = ?]], id)
        -- No way back to the person through Stripe or a login (the Stripe customer
        -- itself is deleted from the seller's Stripe dashboard if wanted: docs §16).
        db.query("UPDATE billing_subscriptions SET stripe_customer_id = NULL WHERE customer_id = ?", id)
        db.query("DELETE FROM billing_access_links WHERE customer_id = ?", id)
        db.query("DELETE FROM billing_access_links WHERE namespace_id = ? AND email_norm = lower(?)", namespace_id,
            c.email or "")
        db.query("DELETE FROM billing_customer_sessions WHERE customer_id = ?", id)
        db.query([[UPDATE customers SET email = ?, first_name = NULL, last_name = NULL, phone = NULL,
            date_of_birth = NULL, addresses = '[]', notes = NULL, tags = NULL, external_id = NULL, state = 'disabled',
            accepts_marketing = FALSE, updated_at = NOW() WHERE id = ?]], "deleted+" .. c.uuid .. "@invalid.example", id)
        -- Links some deployments' customers table has (ecommerce): cleared too.
        for _, r in ipairs(db.query([[SELECT column_name FROM information_schema.columns
            WHERE table_name = 'customers' AND column_name IN ('stripe_customer_id', 'user_id')]])) do
            db.query("UPDATE customers SET " .. db.escape_identifier(r.column_name) .. " = NULL WHERE id = ?", id)
        end
        for _, a in ipairs(db.query([[SELECT DISTINCT a.id, a.cache_generation FROM billing_apps a
            WHERE a.namespace_id = ?]], namespace_id)) do
            EntitlementService.bust(a, id)
        end
        return { erased = true, kept = { "purchases", "payments", "plan_changes", "coupon_redemptions" } }
    end)
end

return Privacy
