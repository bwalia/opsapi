-- Server-side forwarding of pixel events to ad platforms: Meta Conversions API and
-- GA4 Measurement Protocol. Runs from the pixel_forwarder job (outbox: web events with
-- forward_pending). Identifiers are SHA-256 hashed; raw IPs are never stored or sent.
local cjson = require("cjson.safe")
local db = require("lapis.db")
local U = require("opsapi_marketing.util")
local P = require("opsapi_marketing.pixel")

local F = {}

local META_EVENTS = {
    page_view = "PageView", purchase = "Purchase", lead = "Lead", sign_up = "CompleteRegistration",
    signup = "CompleteRegistration", complete_registration = "CompleteRegistration",
    subscribe = "Subscribe", start_trial = "StartTrial", add_to_cart = "AddToCart",
    initiate_checkout = "InitiateCheckout", view_content = "ViewContent", contact = "Contact",
    search = "Search", submit_application = "SubmitApplication", book_demo = "Schedule",
}

local GA4_EVENTS = {
    page_view = "page_view", purchase = "purchase", lead = "generate_lead", sign_up = "sign_up",
    signup = "sign_up", complete_registration = "sign_up", add_to_cart = "add_to_cart",
    initiate_checkout = "begin_checkout", view_content = "view_item", search = "search",
}

local function ts(created_at)
    local r = U.one("SELECT EXTRACT(EPOCH FROM ?::timestamptz)::bigint AS t", created_at)
    return r and tonumber(r.t) or ngx.time()
end

local function contact_email(ns, contact_uuid)
    if not contact_uuid then return nil end
    local c = U.one("SELECT email FROM crm_contacts WHERE namespace_id = ? AND uuid = ?", ns, contact_uuid)
    return c and U.norm_email(c.email)
end

function F.meta_payload(ev, settings, email)
    local user = { client_user_agent = ev.user_agent }
    if email then user.em = { P.sha256_hex(email) } end
    if ev.contact_uuid then user.external_id = { P.sha256_hex(ev.contact_uuid) } end
    local custom = {}
    if ev.value then custom.value = tonumber(ev.value) end
    if ev.currency then custom.currency = ev.currency end
    if ev.order_id then custom.order_id = ev.order_id end
    local body = {
        data = { {
            event_name = META_EVENTS[ev.event_name] or ev.event_name,
            event_time = ts(ev.created_at),
            event_id = ev.event_id or ev.uuid, -- matches the browser pixel's eventID for dedupe
            action_source = "website",
            event_source_url = ev.url,
            user_data = user,
            custom_data = next(custom) and custom or nil,
        } },
    }
    if (settings.meta_test_event_code or "") ~= "" then body.test_event_code = settings.meta_test_event_code end
    return body
end

function F.ga4_payload(ev, visitor_key)
    local params = { engagement_time_msec = 1, page_location = ev.url }
    if ev.value then params.value = tonumber(ev.value) end
    if ev.currency then params.currency = ev.currency end
    if ev.order_id then params.transaction_id = ev.order_id end
    if ev.utm_campaign then params.campaign = ev.utm_campaign end
    return {
        client_id = visitor_key or ("opsapi." .. tostring(ev.id)),
        user_id = ev.contact_uuid,
        events = { { name = GA4_EVENTS[ev.event_name] or ev.event_name:gsub("[^%w_]", "_"):sub(1, 40), params = params } },
    }
end

local function post(url, body)
    local httpc = require("resty.http").new()
    httpc:set_timeouts(3000, 5000, 5000)
    local res, err = httpc:request_uri(url, {
        method = "POST",
        body = cjson.encode(body),
        headers = { ["Content-Type"] = "application/json" },
        ssl_verify = true,
    })
    if not res then return nil, tostring(err) end
    return res.status, (res.body or ""):sub(1, 500)
end

-- Dry runs log the whole payload: JSON key order isn't stable, so a short cut could drop
-- event_name, the very thing a dry run is there to check.
local DRY_RUN_LOG = 4000

local function log(ns, ev_id, dest, status, http_status, response)
    db.query([[
        INSERT INTO mkt_pixel_forwards (namespace_id, web_event_id, destination, status, http_status, response)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], ns, ev_id, dest, status, http_status or db.NULL, response or db.NULL)
end

--- Forward one event to each configured destination. dry_run logs without calling out.
function F.forward(ns, ev, settings)
    local dry = settings.dry_run == true
    local email = contact_email(ns, ev.contact_uuid)
    local visitor = ev.visitor_id and U.one("SELECT visitor_key FROM mkt_visitors WHERE id = ?", ev.visitor_id)
    local out = {}
    if (settings.meta_pixel_id or "") ~= "" and (settings.meta_capi_access_token or "") ~= "" then
        local body = F.meta_payload(ev, settings, email)
        if dry then
            log(ns, ev.id, "meta", "dry_run", nil, cjson.encode(body):sub(1, DRY_RUN_LOG))
        else
            local url = "https://graph.facebook.com/v21.0/" .. ngx.escape_uri(settings.meta_pixel_id)
                .. "/events?access_token=" .. ngx.escape_uri(settings.meta_capi_access_token)
            local status, resp = post(url, body)
            log(ns, ev.id, "meta", status and status < 300 and "sent" or "failed", status, resp)
        end
        out.meta = true
    end
    if (settings.ga4_measurement_id or "") ~= "" and (settings.ga4_api_secret or "") ~= "" then
        local body = F.ga4_payload(ev, visitor and visitor.visitor_key)
        if dry then
            log(ns, ev.id, "ga4", "dry_run", nil, cjson.encode(body):sub(1, DRY_RUN_LOG))
        else
            local url = "https://www.google-analytics.com/mp/collect?measurement_id="
                .. ngx.escape_uri(settings.ga4_measurement_id) .. "&api_secret=" .. ngx.escape_uri(settings.ga4_api_secret)
            local status, resp = post(url, body)
            log(ns, ev.id, "ga4", status and status < 300 and "sent" or "failed", status, resp)
        end
        out.ga4 = true
    end
    return out
end

--- Drain pending events for a namespace (called by the job). Claims atomically, then
-- calls out with no transaction or row lock held.
function F.process(ns, settings, limit)
    local rows = db.query([[
        UPDATE mkt_web_events SET forward_pending = false
        WHERE id IN (
            SELECT id FROM mkt_web_events
            WHERE namespace_id = ? AND forward_pending
            ORDER BY id ASC LIMIT ?
            FOR UPDATE SKIP LOCKED
        )
        RETURNING *
    ]], ns, tonumber(limit) or 100)
    for _, ev in ipairs(rows) do
        local ok, err = pcall(F.forward, ns, ev, settings)
        if not ok then
            ngx.log(ngx.ERR, "[opsapi_marketing] forward event ", ev.id, ": ", tostring(err))
            log(ns, ev.id, "error", "failed", nil, tostring(err):sub(1, 500))
        end
    end
    return #rows
end

return F
