-- Public endpoints (signed token auth, no login): unsubscribe, preferences, open pixel, click.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local sdk = require("helper.plugin-sdk")
local RateLimit = require("middleware.rate-limit")
local U = require("opsapi_marketing.util")
local E = require("opsapi_marketing.eligibility")
local T = require("opsapi_marketing.tokens")
local Sms = require("opsapi_marketing.channels.sms")
local Bots = require("opsapi_marketing.bots")
local Pixel = require("opsapi_marketing.pixel")
local Links = require("opsapi_marketing.links")
local cjson = require("cjson.safe")
local db = require("lapis.db")

local TRANSPARENT_GIF = ngx.decode_base64("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

local function rate_public(key, per_min)
    local n = RateLimit.incr("mkt:pub:" .. key .. ":" .. RateLimit.getClientIP(), 60)
    return not n or n <= (per_min or 60)
end

local function user_agent()
    return ngx.req.get_headers()["user-agent"]
end

local function raw_body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then raw = f:read("*a"); f:close() end
        end
    end
    return raw
end

local function gif_response()
    return {
        status = 200,
        headers = {
            ["Content-Type"] = "image/gif",
            ["Cache-Control"] = "no-store, no-cache, must-revalidate, private",
        },
        layout = false,
        TRANSPARENT_GIF,
    }
end

local function require_plugin(ns)
    if not U.plugin_on(ns) then
        return nil, "plugin disabled"
    end
    return true
end

local function safe_redirect(url)
    if type(url) ~= "string" then return nil end
    if not url:match("^https?://") then return nil end
    if url:match("^https?://(localhost|127%.|10%.|192%.168%.|169%.254%.)") then return nil end
    return url
end

return function(app)
    app:get("/public/unsubscribe", sdk.handler({ namespace = false }, function(self)
        if not rate_public("unsub") then return sdk.error(429, "Too many requests") end
        local claims, err = T.verify(self.params.token, "unsubscribe")
        if not claims then return sdk.error(400, err or "invalid token") end
        local ns = claims.namespace_id
        local okp, perr = require_plugin(ns)
        if not okp then return sdk.error(404, perr) end

        local contact = U.one("SELECT uuid, email, phone, mobile FROM crm_contacts WHERE namespace_id = ? AND uuid = ?",
            ns, claims.contact_uuid)
        local channel = claims.channel or "email"
        local address = channel == "sms"
            and (contact and (contact.phone or contact.mobile))
            or (contact and contact.email)

        E.opt_out(ns, claims.contact_uuid, channel, {
            list_id = claims.list_id,
            address = address,
            source = "one_click_unsubscribe",
            reason = "unsubscribe",
        })

        return {
            status = 200,
            headers = { ["Content-Type"] = "text/html; charset=utf-8" },
            layout = false,
            "<!doctype html><html><body><h1>You have been unsubscribed</h1>"
                .. "<p>You will no longer receive marketing messages on this channel.</p></body></html>",
        }
    end))

    -- RFC 8058 one-click POST
    app:post("/public/unsubscribe", sdk.handler({ namespace = false }, function(self)
        if not rate_public("unsub") then return sdk.error(429, "Too many requests") end
        local token = self.params.token
        local body = sdk.body(self)
        if type(body) == "table" and body.token then token = body.token end
        local claims, err = T.verify(token, "unsubscribe")
        if not claims then return sdk.error(400, err or "invalid token") end
        local ns = claims.namespace_id
        if not require_plugin(ns) then return sdk.error(404, "plugin disabled") end
        local contact = U.one("SELECT email, phone, mobile FROM crm_contacts WHERE namespace_id = ? AND uuid = ?",
            ns, claims.contact_uuid)
        local channel = claims.channel or "email"
        E.opt_out(ns, claims.contact_uuid, channel, {
            list_id = claims.list_id,
            address = channel == "sms" and (contact and (contact.phone or contact.mobile)) or (contact and contact.email),
            source = "list_unsubscribe_post",
            reason = "unsubscribe",
        })
        return { status = 200, json = { success = true } }
    end))

    app:get("/public/preferences", sdk.handler({ namespace = false }, function(self)
        if not rate_public("prefs") then return sdk.error(429, "Too many requests") end
        local claims, err = T.verify(self.params.token, "preferences")
        if not claims then return sdk.error(400, err or "invalid token") end
        if not require_plugin(claims.namespace_id) then return sdk.error(404, "plugin disabled") end
        local subs = db.query([[
            SELECT channel, list_id, status, changed_at FROM mkt_subscriptions
            WHERE namespace_id = ? AND contact_uuid = ? ORDER BY channel
        ]], claims.namespace_id, claims.contact_uuid)
        return sdk.ok({ contact_uuid = claims.contact_uuid, subscriptions = sdk.array(subs) })
    end))

    -- Open tracking pixel (opens are estimated — scanners/proxies inflate counts; known
    -- scanners are recorded but never set opened_at)
    app:get("/public/o.gif", sdk.handler({ namespace = false }, function(self)
        if not rate_public("open", 120) then return gif_response() end
        local claims = T.verify(self.params.t, "open")
        if claims and require_plugin(claims.namespace_id) then
            local d = U.one("SELECT id, campaign_id, contact_uuid, opened_at FROM mkt_deliveries WHERE uuid = ? AND namespace_id = ?",
                claims.delivery_uuid, claims.namespace_id)
            if d then
                local ua = user_agent()
                local is_bot, reason = Bots.classify(ua, { method = ngx.req.get_method() })
                db.query([[
                    INSERT INTO mkt_tracking_events
                        (namespace_id, delivery_id, campaign_id, contact_uuid, event_type, is_estimated,
                         user_agent, ip_hash, is_bot, bot_reason)
                    VALUES (?, ?, ?, ?, 'open', true, ?, ?, ?, ?)
                ]], claims.namespace_id, d.id, d.campaign_id, d.contact_uuid,
                    ua and ua:sub(1, 512) or db.NULL, Pixel.ip_hash(RateLimit.getClientIP()) or db.NULL,
                    is_bot, reason or db.NULL)
                if not d.opened_at and not is_bot then
                    db.query("UPDATE mkt_deliveries SET opened_at = NOW(), updated_at = NOW() WHERE id = ?", d.id)
                end
            end
        end
        return gif_response()
    end))

    app:get("/public/c", sdk.handler({ namespace = false }, function(self)
        if not rate_public("click", 120) then return sdk.error(429, "Too many requests") end
        local claims, err = T.verify(self.params.t, "click")
        if not claims then return sdk.error(400, err or "invalid token") end
        if not require_plugin(claims.namespace_id) then return sdk.error(404, "plugin disabled") end
        local dest = safe_redirect(claims.dest)
        if not dest then return sdk.error(400, "invalid destination") end

        local d = U.one([[
            SELECT id, uuid, campaign_id, contact_uuid,
                   EXTRACT(EPOCH FROM (NOW() - accepted_at))::float AS since_send
            FROM mkt_deliveries WHERE uuid = ? AND namespace_id = ?
        ]], claims.delivery_uuid, claims.namespace_id)
        if d then
            local ua = user_agent()
            local is_bot, reason = Bots.classify(ua, {
                method = ngx.req.get_method(), seconds_since_send = tonumber(d.since_send),
            })
            db.query([[
                INSERT INTO mkt_tracking_events
                    (namespace_id, delivery_id, campaign_id, contact_uuid, event_type, url,
                     user_agent, ip_hash, is_bot, bot_reason)
                VALUES (?, ?, ?, ?, 'click', ?, ?, ?, ?, ?)
            ]], claims.namespace_id, d.id, d.campaign_id, d.contact_uuid, dest,
                ua and ua:sub(1, 512) or db.NULL, Pixel.ip_hash(RateLimit.getClientIP()) or db.NULL,
                is_bot, reason or db.NULL)
            if not is_bot then
                -- A click proves the open even when images were blocked.
                db.query([[
                    UPDATE mkt_deliveries SET clicked_at = COALESCE(clicked_at, NOW()),
                        opened_at = COALESCE(opened_at, NOW()), updated_at = NOW()
                    WHERE id = ?
                ]], d.id)
                local camp = U.one("SELECT tracking FROM mkt_campaigns WHERE id = ?", d.campaign_id)
                local tracking = camp and U.json(camp.tracking) or {}
                if type(tracking) ~= "table" or tracking.attribution ~= false then
                    local tok = T.attribution_token(claims.namespace_id, d.uuid)
                    if tok then dest = Links.add_params(dest, { { "_mkt", tok } }) end
                end
            end
        end
        return { status = 302, redirect_to = dest }
    end))

    -- -----------------------------------------------------------------------
    -- Website pixel (public key auth; called cross-origin from customer sites)
    -- -----------------------------------------------------------------------

    app:get("/public/px.js", sdk.handler({ namespace = false }, function(self)
        local pixel = Pixel.find_by_key(self.params.k)
        local js
        if pixel and U.plugin_on(pixel.namespace_id) then
            js = Pixel.script(pixel.public_key, Pixel.endpoints(Pixel.public_base(pixel.namespace_id, self)).events)
        else
            js = "/* OpsAPI pixel: unknown or inactive key */ window.mkt = window.mkt || function () {};"
        end
        return {
            status = 200,
            headers = {
                ["Content-Type"] = "application/javascript; charset=utf-8",
                ["Cache-Control"] = "public, max-age=300",
                ["X-Content-Type-Options"] = "nosniff",
            },
            layout = false,
            js,
        }
    end))

    -- Beacon: text/plain JSON (no CORS preflight). One event, or { events = [...] } (max 25).
    app:post("/public/px/e", sdk.handler({ namespace = false }, function(self)
        if not rate_public("px", 600) then return sdk.error(429, "Too many requests") end
        local raw = raw_body()
        if raw and #raw > 65536 then return sdk.error(413, "payload too large") end
        local body = raw and raw ~= "" and cjson.decode(raw) or nil
        if type(body) ~= "table" then return sdk.error(400, "JSON body required") end
        local pixel = Pixel.find_by_key(self.params.k or body.k)
        if not pixel or not U.plugin_on(pixel.namespace_id) then return sdk.error(404, "unknown pixel") end

        local events = type(body.events) == "table" and body.events or { body }
        if #events > 25 then return sdk.error(400, "max 25 events per batch") end
        local h = ngx.req.get_headers()
        local req = { ua = h["user-agent"], ip = RateLimit.getClientIP(), referer = h["referer"], method = "POST" }
        local results, rejected = {}, nil
        for _, ev in ipairs(events) do
            if type(ev) == "table" then
                local out, err = Pixel.ingest(pixel, ev, req)
                if out then results[#results + 1] = out else rejected = err end
            end
        end
        if #results == 0 and rejected == "domain_not_allowed" then
            return sdk.error(403, "domain not allowed for this pixel")
        end
        if #results == 0 then return sdk.error(400, rejected or "no valid events") end
        return { status = 202, json = { success = true, accepted = #results } }
    end))

    -- <noscript> / email-safe fallback: GET with e (event), u (url), v, cur, oid.
    app:get("/public/px.gif", sdk.handler({ namespace = false }, function(self)
        if not rate_public("px", 600) then return gif_response() end
        local pixel = Pixel.find_by_key(self.params.k)
        if pixel and U.plugin_on(pixel.namespace_id) then
            local h = ngx.req.get_headers()
            pcall(Pixel.ingest, pixel, {
                e = self.params.e or "page_view", u = self.params.u, v = self.params.v,
                cur = self.params.cur, oid = self.params.oid, id = self.params.id,
            }, { ua = h["user-agent"], ip = RateLimit.getClientIP(), referer = h["referer"],
                 method = ngx.req.get_method() })
        end
        return gif_response()
    end))

    -- SMS inbound / STOP webhook (provider posts here)
    app:post("/public/sms/inbound", sdk.handler({ namespace = false }, function(self)
        if not rate_public("sms_in") then return sdk.error(429, "Too many requests") end
        local body = sdk.body(self) or {}
        local token = self.params.token or body.token or ngx.req.get_headers()["x-mkt-token"]
        local claims, err = T.verify(token, "sms_inbound")
        if not claims then return sdk.error(401, err or "unauthorized") end
        local ns = claims.namespace_id
        if not require_plugin(ns) then return sdk.error(404, "plugin disabled") end

        local Replies = require("opsapi_marketing.replies")
        local parsed = Sms.parse_webhook({ body = body })
        if parsed.state == "opt_out" and parsed.address then
            local phone = U.e164(parsed.address)
            local contact = phone and U.one([[
                SELECT uuid, phone, mobile FROM crm_contacts
                WHERE namespace_id = ?
                  AND (phone = ? OR mobile = ? OR regexp_replace(COALESCE(phone, ''), '[^0-9+]', '', 'g') = ?
                       OR regexp_replace(COALESCE(mobile, ''), '[^0-9+]', '', 'g') = ?)
                LIMIT 1
            ]], ns, phone, phone, phone, phone)
            if contact then
                E.opt_out(ns, contact.uuid, "sms", {
                    address = phone,
                    source = "sms_stop",
                    reason = "stop_keyword",
                    evidence = parsed.keyword,
                })
            else
                -- Suppress the number even without a contact match
                local s = U.one([[
                    SELECT id FROM mkt_suppressions
                    WHERE namespace_id = ? AND lower(address) = lower(?) AND channel = 'sms'
                ]], ns, phone or parsed.address)
                if not s then
                    db.query([[
                        INSERT INTO mkt_suppressions (namespace_id, channel, address, reason, source)
                        VALUES (?, 'sms', ?, 'stop_keyword', 'sms_stop')
                    ]], ns, phone or parsed.address)
                end
            end
            Replies.ingest(ns, {
                provider = "sms_gateway",
                external_id = body.messageId or body.id or ("stop:" .. tostring(phone or parsed.address) .. ":" .. tostring(ngx.time())),
                channel = "sms",
                address = phone or parsed.address,
                contact_uuid = contact and contact.uuid,
                classification = "unsubscribe",
                confidence = 0.99,
                body_text = parsed.keyword or "STOP",
                classified_by = "sms_stop",
            })
            return sdk.ok({ opted_out = true, auto_send = false })
        end

        -- Non-STOP inbound → classify + store; never auto-reply
        local out = Replies.ingest(ns, {
            provider = "sms_gateway",
            external_id = body.messageId or body.id,
            channel = "sms",
            address = parsed.address,
            body_text = parsed.text,
            raw = body,
        })
        return sdk.ok({
            received = true,
            state = parsed.state,
            reply = out.reply,
            auto_send = false,
        })
    end))
end
