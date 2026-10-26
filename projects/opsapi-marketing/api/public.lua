-- Public endpoints (signed token auth, no login): unsubscribe, preferences, view in browser,
-- open pixel, click.
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
local Pages = require("opsapi_marketing.pages")
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

-- Only the SMS webhook and the website pixel check the plugin switch. The links in an
-- email (unsubscribe, preferences, view, open, click, images) are signed proof it was sent, and keep working after
-- the plugin is turned off: platform admins send with it off (the switch doesn't bind
-- them), and a person must always be able to unsubscribe or follow a link they got.
local function require_plugin(ns)
    if not U.plugin_on(ns) then
        return nil, "plugin disabled"
    end
    return true
end

-- A tracked link must not bounce recipients to their own machine or a private network. (Lua patterns have no
-- `|`: the old `(localhost|127%.|…)` check never matched anything.)
local function private_host(url)
    local host = (url:match("^https?://([^/?#]*)") or ""):gsub("^.*@", ""):gsub(":%d*$", ""):lower()
    local b = tonumber(host:match("^172%.(%d+)%."))
    return host == "localhost" or host:find("%.localhost$") ~= nil or host == "0.0.0.0" or host:find("^%[") ~= nil
        or host:find("^127%.") ~= nil or host:find("^10%.") ~= nil or host:find("^192%.168%.") ~= nil
        or host:find("^169%.254%.") ~= nil or (b ~= nil and b >= 16 and b <= 31)
end

local function safe_redirect(url)
    if type(url) ~= "string" then return nil end
    if not url:match("^https?://") then return nil end
    if private_host(url) then return nil end
    return url
end

return function(app)
    -- Unsubscribe / preferences: the link in an email opens a page; nothing changes until the
    -- person presses a button there (mail scanners open links, they don't press buttons).
    -- Mail apps' own one-click button (RFC 8058) POSTs "List-Unsubscribe=One-Click" and counts.

    local function word(channel)
        return channel == "sms" and "text messages" or "emails"
    end

    local function bad_link(sender, body)
        return Pages.page({ status = 400, sender = sender, title = "This link isn’t working",
            body = body or ("<p>It may have been cut short when it was copied. To stop getting messages, open the "
                .. "unsubscribe link in the latest one again, or reply to it and ask to be removed.</p>") })
    end

    local function too_many()
        return Pages.page({ status = 429, title = "Please wait a moment",
            body = "<p>There were too many tries in a short time. Please try again in a minute.</p>" })
    end

    --- The person behind a link: their address on this channel and whether they're unsubscribed.
    local function person(ns, contact_uuid, channel)
        local c = U.one("SELECT uuid, email, phone, mobile FROM crm_contacts WHERE namespace_id = ? AND uuid = ?",
            ns, contact_uuid)
        local function nz(v)
            if v == nil or v == db.NULL or v == "" then return nil end
            return v
        end
        local address = c and (channel == "sms" and (nz(c.phone) or nz(c.mobile)) or nz(c.email)) or nil
        local off = U.one([[
            SELECT 1 AS x FROM mkt_subscriptions
            WHERE namespace_id = ? AND contact_uuid = ? AND channel = ? AND status = 'unsubscribed' LIMIT 1
        ]], ns, contact_uuid, channel) ~= nil
        if not off and address then
            off = U.one([[
                SELECT 1 AS x FROM mkt_suppressions
                WHERE namespace_id = ? AND (channel IS NULL OR channel = ?) AND lower(address) = lower(?) LIMIT 1
            ]], ns, channel, address) ~= nil
        end
        return { contact = c, address = address, unsubscribed = off }
    end

    local function to_whom(address)
        return address and (" at <b>" .. Pages.esc(address) .. "</b>") or ""
    end

    local function unsubscribed_page(sender, token, channel, address)
        return Pages.page({ sender = sender, title = "You’re unsubscribed",
            body = '<p class="done">Done.</p><p>You won’t get any more marketing ' .. word(channel) .. " from <b>"
                .. Pages.esc(sender.name) .. "</b>" .. to_whom(address) .. ".</p>"
                .. "<p>Unsubscribed by mistake?</p>"
                .. Pages.form("unsubscribe", { token = token, action = "resubscribe" }, "Subscribe again", true) })
    end

    local function confirm_page(sender, token, channel, address, again)
        return Pages.page({ sender = sender, title = again and "You’re subscribed again"
                or ("Unsubscribe from " .. sender.name .. "?"),
            body = (again and ('<p class="done">Welcome back.</p><p>You’ll get marketing ' .. word(channel)
                    .. " from <b>" .. Pages.esc(sender.name) .. "</b>" .. to_whom(address) .. " again.</p>")
                or ("<p>You’ll stop getting marketing " .. word(channel) .. " from <b>" .. Pages.esc(sender.name)
                    .. "</b>" .. to_whom(address) .. ".</p>"))
                .. Pages.form("unsubscribe", { token = token, action = "unsubscribe" }, "Unsubscribe", again) })
    end

    app:get("/public/unsubscribe", sdk.handler({ namespace = false }, function(self)
        if not rate_public("unsub") then return too_many() end
        local token = self.params.token
        local claims = T.verify(token, "unsubscribe")
        if not claims then return bad_link() end
        local ns = claims.namespace_id
        local sender = Pages.sender(ns)
        local channel = claims.channel or "email"
        local p = person(ns, claims.contact_uuid, channel)
        if p.unsubscribed then return unsubscribed_page(sender, token, channel, p.address) end
        return confirm_page(sender, token, channel, p.address, false)
    end))

    app:post("/public/unsubscribe", sdk.handler({ namespace = false }, function(self)
        if not rate_public("unsub") then return too_many() end
        local token = self.params.token
        if not token and (ngx.var.content_type or ""):find("json", 1, true) then
            local body = sdk.body(self)
            token = type(body) == "table" and body.token or nil
        end
        local claims = T.verify(token, "unsubscribe")
        local page = self.params.action == "unsubscribe" or self.params.action == "resubscribe"
        if not claims then
            if page then return bad_link() end
            return sdk.error(400, "invalid token")
        end
        local ns = claims.namespace_id
        local sender = Pages.sender(ns)
        local channel = claims.channel or "email"
        local p = person(ns, claims.contact_uuid, channel)

        if self.params.action == "resubscribe" then
            E.resubscribe(ns, claims.contact_uuid, channel, claims.list_id, p.address, "unsubscribe_page")
            return confirm_page(sender, token, channel, p.address, true)
        end

        E.opt_out(ns, claims.contact_uuid, channel, {
            list_id = claims.list_id,
            address = p.address,
            source = page and "unsubscribe_page" or "list_unsubscribe_post",
            reason = "unsubscribe",
        })
        if page then return unsubscribed_page(sender, token, channel, p.address) end
        return { status = 200, json = { success = true } } -- a mail app's one-click button (RFC 8058)
    end))

    --- The preferences page: each channel the person can get, on or off, with a button.
    local function preferences_page(ns, token, contact_uuid, notice)
        local sender = Pages.sender(ns)
        local rows = {}
        for _, channel in ipairs({ "email", "sms" }) do
            local p = person(ns, contact_uuid, channel)
            if p.address then
                rows[#rows + 1] = '<div class="row"><div><b>Marketing ' .. word(channel) .. "</b><br>"
                    .. (p.unsubscribed and "Off" or "On") .. " — " .. Pages.esc(p.address) .. "</div>"
                    .. Pages.form("preferences", { token = token, channel = channel,
                        action = p.unsubscribed and "start" or "stop" },
                        p.unsubscribed and "Turn on" or "Turn off", not p.unsubscribed)
                    .. "</div>"
            end
        end
        if #rows == 0 then
            rows[1] = "<p>We don’t have an address for you any more, so you won’t get marketing messages.</p>"
        end
        return Pages.page({ sender = sender, title = "Your preferences",
            body = (notice and ('<p class="done">' .. Pages.esc(notice) .. "</p>") or "")
                .. "<p>Choose what <b>" .. Pages.esc(sender.name) .. "</b> may send you.</p>"
                .. table.concat(rows) })
    end

    app:get("/public/preferences", sdk.handler({ namespace = false }, function(self)
        if not rate_public("prefs") then return too_many() end
        local claims = T.verify(self.params.token, "preferences")
        if not claims then return bad_link() end
        return preferences_page(claims.namespace_id, self.params.token, claims.contact_uuid)
    end))

    app:post("/public/preferences", sdk.handler({ namespace = false }, function(self)
        if not rate_public("prefs") then return too_many() end
        local token = self.params.token
        local claims = T.verify(token, "preferences")
        if not claims then return bad_link() end
        local ns = claims.namespace_id
        local channel = self.params.channel == "sms" and "sms" or "email"
        local p = person(ns, claims.contact_uuid, channel)
        local notice
        if self.params.action == "stop" then
            E.opt_out(ns, claims.contact_uuid, channel, { address = p.address, source = "preferences_page",
                reason = "unsubscribe" })
            notice = "Saved — you won’t get marketing " .. word(channel) .. " any more."
        elseif self.params.action == "start" then
            E.resubscribe(ns, claims.contact_uuid, channel, nil, p.address, "preferences_page")
            notice = "Saved — you’ll get marketing " .. word(channel) .. " again."
        end
        return preferences_page(ns, token, claims.contact_uuid, notice)
    end))

    -- "View this email in your browser": the delivery re-rendered exactly as the recipient got it
    -- (their name, working unsubscribe / preferences links, click tracking) but with no open pixel —
    -- a view is not an open. Only emails that were actually sent; nothing is recorded here.
    local function gone(sender)
        return Pages.page({ status = 404, sender = sender, title = "This email is no longer available",
            body = "<p>It may have been removed by the sender. The copy in your inbox is unchanged.</p>" })
    end

    local function email_page(subject, html)
        -- Belt and braces: never show the open pixel even if a stored copy carried one.
        html = html:gsub("<[Ii][Mm][Gg][^>]-/public/o%.gif[^>]*>", "")
        if not html:find("<[Hh][Tt][Mm][Ll][%s>]") then
            html = '<!doctype html><html lang="en"><head><meta charset="utf-8">'
                .. '<meta name="viewport" content="width=device-width,initial-scale=1">'
                .. '<meta name="robots" content="noindex"><title>' .. Pages.esc(subject) .. "</title>"
                .. "<style>body{margin:0;padding:24px 12px;background:#f4f5f7}</style></head><body>"
                .. html .. "</body></html>"
        end
        return {
            status = 200,
            layout = false,
            headers = {
                ["Content-Type"] = "text/html; charset=utf-8",
                ["Cache-Control"] = "private, no-store",
                ["X-Robots-Tag"] = "noindex, nofollow",
                ["Referrer-Policy"] = "no-referrer",
                ["X-Content-Type-Options"] = "nosniff",
                ["Content-Security-Policy"] = "default-src 'none'; img-src https: data:; "
                    .. "style-src 'unsafe-inline' https://fonts.googleapis.com; "
                    .. "font-src https: data:; form-action 'none'; base-uri 'none'; frame-ancestors 'none'",
            },
            html,
        }
    end

    app:get("/public/view", sdk.handler({ namespace = false }, function(self)
        if not rate_public("view", 120) then return too_many() end
        local claims = T.verify(self.params.token, "view_online")
        if not claims or not U.is_uuid(claims.delivery_uuid) then
            return bad_link(nil, "<p>It may have been cut short when it was copied. "
                .. "Open the link in the email again, or read the email in your inbox.</p>")
        end
        local ns = claims.namespace_id
        local sender = Pages.sender(ns)

        local Send = require("opsapi_marketing.send")
        local d = U.one([[
            SELECT * FROM mkt_deliveries
            WHERE uuid = ? AND namespace_id = ? AND channel = 'email' AND accepted_at IS NOT NULL
        ]], claims.delivery_uuid, ns)
        local campaign = d and U.one("SELECT * FROM mkt_campaigns WHERE id = ? AND namespace_id = ?",
            d.campaign_id, ns)
        local contact = campaign and Send.load_contact(ns, d.contact_uuid)
        if not contact then return gone(sender) end
        contact.namespace_id = ns
        contact.address = d.address
        local settings = U.settings(ns)
        local base = Send.public_base(settings)
        local self_url = base ~= "" and (base .. "/api/v2/opsapi-marketing/public/view?token="
            .. ngx.escape_uri(self.params.token)) or nil
        local ok, payload = pcall(Send.render_delivery, d, campaign, contact, settings,
            { browser = true, view_online_url = self_url })
        if not ok or not payload or not payload.html or payload.html == "" then return gone(sender) end
        return email_page(payload.subject, payload.html)
    end))

    -- Images uploaded for emails. The address never changes, so mail clients may cache it for good.
    app:get("/public/img/:file", sdk.handler({ namespace = false }, function(self)
        if not rate_public("img", 600) then return sdk.error(429, "Too many requests") end
        local uuid = tostring(self.params.file or ""):match("^([%x%-]+)%.%a+$")
        local bytes, content_type
        if uuid and U.is_uuid(uuid) then bytes, content_type = require("opsapi_marketing.images").read(uuid) end
        if not bytes then return { status = 404, layout = false, "Not found" } end
        return {
            status = 200,
            headers = {
                ["Content-Type"] = content_type,
                ["Cache-Control"] = "public, max-age=31536000, immutable",
                ["X-Content-Type-Options"] = "nosniff",
            },
            layout = false,
            bytes,
        }
    end))

    -- Open tracking pixel (opens are estimated — scanners/proxies inflate counts; known
    -- scanners are recorded but never set opened_at)
    app:get("/public/o.gif", sdk.handler({ namespace = false }, function(self)
        if not rate_public("open", 120) then return gif_response() end
        local claims = T.verify(self.params.t, "open")
        if claims then
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
