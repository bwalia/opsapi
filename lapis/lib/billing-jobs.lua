--[[
    Billing & Entitlements — background work (docs/BILLING_ENTITLEMENTS.md §10, §15)
    ===============================================================================
    handlers: the "core.billing" subscriber of the event outbox
    (helper/plugin-events.lua), so every email is retried with backoff and
    visible when it fails. Secrets never sit in events: the access-link token
    is generated here, at send time, and only its hash is stored.

    maintain(): every 5 minutes on worker 0, one pod at a time (advisory lock):
    expired links / sessions / idempotency rows / key deliveries, device
    auto-release + retention.
]]

local db = require("lapis.db")
local Settings = require("lib.billing-settings")

local Jobs = {}

local LINK_MINUTES = 15

local function random_token()
    local random = require("resty.random")
    local bytes = random.bytes(32, true) or random.bytes(32)
    return (ngx.encode_base64(bytes):gsub("+", "-"):gsub("/", "_"):gsub("=", ""))
end

--- Branding for emails and hosted pages.
function Jobs.brand(app)
    local s = Settings.resolve(app)
    return { app_name = s.display_name or app.name, brand_color = s.accent_color ~= "" and s.accent_color or nil,
        brand_logo_url = s.logo_url ~= "" and s.logo_url or nil, support_email = s.support_email,
        header_title = s.display_name or app.name }
end

--- Where an account link points: the client's allowed return URL, else the
-- hosted page. The token rides in the fragment (never in server logs).
function Jobs.accountUrl(app, return_url)
    local base = return_url
    if not base or base == "" then
        local hosted = os.getenv("BILLING_HOSTED_BASE_URL")
        if not hosted or hosted == "" then return nil end
        base = hosted:gsub("/+$", "") .. "/b/" .. app.uuid .. "/account"
    end
    return base
end

Jobs.handlers = {
    ["billing.access_link.requested"] = function(event)
        local ref = event.data and event.data.link or ""
        -- Requested by email: only a customer with billing records in this app gets a
        -- link; otherwise the row goes and nothing is sent (the API said the same).
        local pending = db.query([[SELECT l.id, l.app_id, l.namespace_id, l.email_norm FROM billing_access_links l
            WHERE l.uuid = ? AND l.customer_id IS NULL]], ref)[1]
        if pending then
            local c = db.query([[
                SELECT c.id FROM customers c WHERE c.namespace_id = ? AND lower(c.email) = ?
                  AND (EXISTS (SELECT 1 FROM billing_licenses WHERE customer_id = c.id AND app_id = ?)
                    OR EXISTS (SELECT 1 FROM billing_purchases WHERE customer_id = c.id AND app_id = ?)
                    OR EXISTS (SELECT 1 FROM billing_subscriptions WHERE customer_id = c.id AND app_id = ?)
                    OR EXISTS (SELECT 1 FROM billing_grants WHERE customer_id = c.id AND app_id = ?))
                LIMIT 1]], pending.namespace_id, pending.email_norm or "", pending.app_id, pending.app_id,
                pending.app_id, pending.app_id)[1]
            if not c then
                db.query("DELETE FROM billing_access_links WHERE id = ?", pending.id)
                return true
            end
            db.query("UPDATE billing_access_links SET customer_id = ?, email_norm = NULL WHERE id = ?", c.id, pending.id)
        end
        local link = db.query([[
            SELECT l.id, l.return_url, l.used_at, l.sent_at, l.expires_at > NOW() AS live, c.email AS customer_email,
                   a.id AS app_id, a.uuid, a.name, a.kind, a.settings, a.namespace_id
            FROM billing_access_links l JOIN customers c ON c.id = l.customer_id JOIN billing_apps a ON a.id = l.app_id
            WHERE l.uuid = ?]], ref)[1]
        -- Gone, used or expired: nothing to send.
        if not link or link.used_at ~= db.NULL and link.used_at or not link.live then return true end
        local app = { id = link.app_id, uuid = link.uuid, name = link.name, kind = link.kind, settings = link.settings }
        local url = Jobs.accountUrl(app, link.return_url ~= db.NULL and link.return_url or nil)
        if not url then return false, "set BILLING_HOSTED_BASE_URL to send account links" end
        -- A new token on every attempt: an earlier attempt's email may never have arrived.
        local token = random_token()
        db.query("UPDATE billing_access_links SET token_hash = ?, sent_at = NOW() WHERE id = ?",
            require("helper.api-key").hash(token), link.id)
        local brand = Jobs.brand(app)
        local ok, err = require("helper.namespace-mail").send(link.namespace_id, "billing.access_link", link.customer_email,
            { app_name = brand.app_name, customer_email = link.customer_email, link = url .. "#token=" .. token,
              expires_minutes = LINK_MINUTES, support_email = brand.support_email }, brand)
        if not ok then return false, err end
        return true
    end,

    -- A licence key bought through checkout: decrypted here, at send time (lib/billing-delivery.lua).
    ["billing.licence_key.requested"] = function(event)
        local lic = db.query([[
            SELECT l.id, l.status, p.name AS plan_name, c.email AS customer_email,
                   a.id AS app_id, a.uuid, a.name, a.kind, a.settings, a.namespace_id
            FROM billing_licenses l JOIN customers c ON c.id = l.customer_id JOIN billing_apps a ON a.id = l.app_id
            LEFT JOIN billing_plans p ON p.id = l.plan_id
            WHERE l.uuid = ?]], event.data and event.data.license or "")[1]
        if not lic or lic.status == "revoked" then return true end
        local Delivery = require("lib.billing-delivery")
        local key, derr = Delivery.forEmail(lic.id)
        if not key then
            if derr then return false, derr end
            return true -- already emailed, or expired
        end
        local app = { id = lic.app_id, uuid = lic.uuid, name = lic.name, kind = lic.kind, settings = lic.settings }
        local brand = Jobs.brand(app)
        local ok, err = require("helper.namespace-mail").send(lic.namespace_id, "billing.licence_key", lic.customer_email,
            { app_name = brand.app_name, customer_email = lic.customer_email, licence_key = key,
              plan_name = lic.plan_name ~= db.NULL and lic.plan_name or "", account_link = Jobs.accountUrl(app) or "",
              support_email = brand.support_email }, brand)
        if not ok then return false, err end
        Delivery.emailed(lic.id)
        return true
    end,
}

Jobs.LINK_MINUTES = LINK_MINUTES

--- Subscriptions OpsAPI doesn't hear about from Stripe (manual sales, stores,
-- external) end with their paid period: mark them canceled (which emits
-- subscription.canceled) and drop the cached answers. Stripe's own come from webhooks.
function Jobs.lapseSubscriptions()
    local EntitlementService = require("helper.entitlement-service")
    for _, r in ipairs(db.query([[
        UPDATE billing_subscriptions SET status = 'canceled', ended_at = current_period_end, updated_at = NOW()
        WHERE id IN (SELECT id FROM billing_subscriptions WHERE app_id IS NOT NULL AND source <> 'stripe'
            AND status IN ('active', 'trialing') AND current_period_end IS NOT NULL
            AND current_period_end < (NOW() AT TIME ZONE 'UTC') LIMIT 500)
        RETURNING app_id, customer_id]])) do
        EntitlementService.bust(r.app_id, r.customer_id)
    end
end

function Jobs.maintain(premature)
    if premature then return end
    -- One transaction (the advisory lock lives in it); cache drops run after it commits.
    local ok, err = require("queries.FieldServiceCommon").transaction(function()
        if db.query("SELECT pg_try_advisory_xact_lock(hashtext('opsapi.billing.maintain')) AS l")[1].l then
            db.query("DELETE FROM billing_access_links WHERE expires_at < NOW() - interval '1 day'")
            db.query("DELETE FROM billing_customer_sessions WHERE expires_at < NOW()")
            db.query("DELETE FROM billing_idempotency WHERE expires_at < NOW()")
            require("lib.billing-delivery").purge()
            require("queries.BillingOfferQueries").releaseExpired()
            Jobs.lapseSubscriptions()
            require("queries.BillingLicenseQueries").maintain()
        end
        return true
    end)
    if not ok then ngx.log(ngx.ERR, "[billing] maintenance failed: ", tostring(err)) end
    pcall(require("helper.plugin-events").releaseConnection)
end

return Jobs
