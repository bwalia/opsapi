--[[
    Website pixel: first-party visitor tracking, identity stitching and conversion
    attribution back to the campaign/delivery that drove the visit.

      email click  → /public/c appends _mkt=<signed attr token> to the destination
      pixel        → reads _mkt, sends it with events; the visitor is stitched to the
                     delivery's contact and remembers the touch
      conversion   → attributed last-click to the newest touch inside the pixel's
                     attribution window (visitor touch, else the contact's newest
                     human email click, else utm_id = campaign uuid)

    Bots never stitch or attribute. Test events are stored but never convert.
]]
local cjson = require("cjson.safe")
local db = require("lapis.db")
local U = require("opsapi_marketing.util")
local T = require("opsapi_marketing.tokens")
local Bots = require("opsapi_marketing.bots")

local P = {}

P.CONVERSION_EVENTS = {
    purchase = true, lead = true, sign_up = true, signup = true, subscribe = true,
    start_trial = true, complete_registration = true, conversion = true, book_demo = true,
    contact = true, submit_application = true,
}

local EVENT_ALIASES = { page = "page_view", pageview = "page_view", ["$pageview"] = "page_view" }

function P.sha256_hex(s)
    local sha = require("resty.sha256"):new()
    sha:update(s)
    return require("resty.string").to_hex(sha:final())
end

function P.new_key()
    return U.one("SELECT 'px_' || replace(gen_random_uuid()::text, '-', '') AS k").k
end

function P.find_by_key(key)
    if type(key) ~= "string" or not key:match("^px_%x+$") or #key > 64 then return nil end
    return U.one("SELECT * FROM mkt_pixels WHERE public_key = ? AND is_active = true", key)
end

function P.find(ns, id)
    if U.is_uuid(id) then
        return U.one("SELECT * FROM mkt_pixels WHERE namespace_id = ? AND uuid = ?", ns, id)
    end
    return U.one("SELECT * FROM mkt_pixels WHERE namespace_id = ? AND id = ?", ns, tonumber(id))
end

--- Clean an allowed-domains list: bare lower-case hostnames, wildcards and schemes dropped.
function P.normalize_domains(list)
    local out = {}
    if type(list) ~= "table" then return U.array(out) end
    for _, d in ipairs(list) do
        if type(d) == "string" then
            d = d:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("^https?://", "")
                :gsub("^%*%.", ""):gsub("[/:].*$", "")
            if d:match("^[%w%-%.]+$") and d:find(".", 1, true) or d == "localhost" then
                out[#out + 1] = d
            end
        end
    end
    return U.array(out)
end

local function host_of(url)
    return type(url) == "string" and url:match("^https?://([^/:?#]+)") or nil
end

--- Empty list = any site may send events with this key.
function P.domain_allowed(pixel, url)
    local list = U.json(pixel.allowed_domains)
    if type(list) ~= "table" or #list == 0 then return true end
    local host = host_of(url)
    if not host then return false end
    host = host:lower()
    for _, d in ipairs(list) do
        d = tostring(d):lower()
        if host == d or host:sub(-(#d + 1)) == "." .. d then return true end
    end
    return false
end

function P.query_params(url)
    local out = {}
    local q = type(url) == "string" and url:match("%?([^#]*)")
    if q then
        for k, v in q:gmatch("([^&=]+)=([^&]*)") do
            out[ngx.unescape_uri(k)] = ngx.unescape_uri(v)
        end
    end
    return out
end

local function clip(s, n)
    if type(s) ~= "string" or s == "" then return nil end
    return s:sub(1, n)
end

local function nvl(v)
    if v == nil then return db.NULL end
    return v
end

function P.ip_hash(ip)
    if type(ip) ~= "string" or ip == "" then return nil end
    return P.sha256_hex(ip .. "|" .. (os.getenv("JWT_SECRET_KEY") or "")):sub(1, 32)
end

--- Where the browser should reach the public pixel endpoints.
function P.public_base(ns, self)
    local base = require("opsapi_marketing.send").public_base(U.settings(ns))
    if base ~= "" then return base end
    local h = self and self.req and self.req.headers or {}
    local proto = h["x-forwarded-proto"] or ngx.var.scheme or "https"
    local host = h["x-forwarded-host"] or h["host"] or ngx.var.http_host or ""
    return proto:match("^[%a]+") .. "://" .. host
end

function P.endpoints(base)
    local root = base .. "/api/v2/opsapi-marketing/public"
    return { script = root .. "/px.js", events = root .. "/px/e", gif = root .. "/px.gif" }
end

--- Newest touch that may claim an event for this visitor/contact.
function P.resolve_touch(pixel, visitor, contact_uuid, qp)
    local ns = pixel.namespace_id
    local window = tonumber(pixel.attribution_window_days) or 7
    if visitor and visitor.last_delivery_id then
        local fresh = U.one([[
            SELECT last_campaign_id, last_delivery_id, contact_uuid, last_touch_at FROM mkt_visitors
            WHERE id = ? AND last_touch_at > NOW() - make_interval(days => ?)
        ]], visitor.id, window)
        if fresh then
            return {
                campaign_id = fresh.last_campaign_id, delivery_id = fresh.last_delivery_id,
                contact_uuid = fresh.contact_uuid, at = fresh.last_touch_at,
            }
        end
    end
    if contact_uuid then
        local d = U.one([[
            SELECT id, campaign_id, clicked_at FROM mkt_deliveries
            WHERE namespace_id = ? AND contact_uuid = ? AND clicked_at > NOW() - make_interval(days => ?)
            ORDER BY clicked_at DESC LIMIT 1
        ]], ns, contact_uuid, window)
        if d then
            return { campaign_id = d.campaign_id, delivery_id = d.id, contact_uuid = contact_uuid, at = d.clicked_at }
        end
    end
    if U.is_uuid(qp.utm_id) then
        local c = U.one("SELECT id FROM mkt_campaigns WHERE namespace_id = ? AND uuid = ?", ns, qp.utm_id)
        if c then return { campaign_id = c.id, contact_uuid = contact_uuid } end
    end
    return nil
end

local function forwarding_on(settings)
    return (settings.meta_pixel_id or "") ~= "" and (settings.meta_capi_access_token or "") ~= ""
        or (settings.ga4_measurement_id or "") ~= "" and (settings.ga4_api_secret or "") ~= ""
end

local function goal_matches(campaign_id, name)
    if not campaign_id then return false end
    local c = U.one("SELECT tracking FROM mkt_campaigns WHERE id = ?", campaign_id)
    local tr = c and U.json(c.tracking)
    return type(tr) == "table" and tr.goal_event == name
end

--- Record one browser event. ev = decoded beacon:
--   e name, id event_id, u url, r referrer, vid visitor key, mkt attr token,
--   v value, cur currency, oid order id, p properties, em email (identify only)
-- req = { ua, ip, referer, method, test }
-- @return result table | nil, err
function P.ingest(pixel, ev, req)
    req = req or {}
    local ns = pixel.namespace_id
    local name = type(ev.e) == "string" and ev.e:lower() or nil
    name = name and (EVENT_ALIASES[name] or name)
    if not name or #name > 64 or not name:match("^[%w_%.%-]+$") then return nil, "invalid_event" end

    local url = clip(ev.u, 2000) or clip(req.referer, 2000)
    if not P.domain_allowed(pixel, url) then return nil, "domain_not_allowed" end

    local is_bot, bot_reason = Bots.classify(req.ua, { method = req.method })
    local is_test = req.test == true
    local qp = P.query_params(url)
    local props = type(ev.p) == "table" and ev.p or {}
    props.email = nil -- never persist raw PII from the browser
    if bot_reason then props._bot = bot_reason end
    local props_json = cjson.encode(props) or "{}"
    if #props_json > 8000 then props_json = "{}" end

    local visitor
    local vkey = type(ev.vid) == "string" and #ev.vid >= 8 and #ev.vid <= 64
        and ev.vid:match("^[%w%-_]+$") and ev.vid or nil
    if vkey and not is_bot then
        visitor = db.query([[
            INSERT INTO mkt_visitors (namespace_id, pixel_id, visitor_key, first_touch, event_count)
            VALUES (?, ?, ?, ?::jsonb, 1)
            ON CONFLICT (namespace_id, visitor_key)
            DO UPDATE SET last_seen_at = NOW(), event_count = mkt_visitors.event_count + 1
            RETURNING *
        ]], ns, pixel.id, vkey, cjson.encode({
            url = url, referrer = clip(ev.r, 500),
            utm_source = qp.utm_source, utm_medium = qp.utm_medium, utm_campaign = qp.utm_campaign,
        }) or "{}")[1]
    end

    -- Click-through from one of our emails: stitch visitor ↔ contact and remember the touch.
    local touch
    local tok = ev.mkt or qp._mkt
    if type(tok) == "string" and not is_bot and not is_test then
        local claims = T.verify(tok, "attr")
        if claims and tonumber(claims.namespace_id) == tonumber(ns) then
            local d = U.one([[
                SELECT id, campaign_id, contact_uuid FROM mkt_deliveries WHERE uuid = ? AND namespace_id = ?
            ]], claims.delivery_uuid, ns)
            if d then
                touch = { campaign_id = d.campaign_id, delivery_id = d.id, contact_uuid = d.contact_uuid }
                if visitor and visitor.last_delivery_id ~= d.id then
                    db.query([[
                        UPDATE mkt_visitors SET contact_uuid = ?, last_campaign_id = ?, last_delivery_id = ?,
                            last_touch_at = NOW()
                        WHERE id = ?
                    ]], d.contact_uuid, d.campaign_id, d.id, visitor.id)
                    visitor.contact_uuid = d.contact_uuid
                    visitor.last_delivery_id = d.id
                end
            end
        end
    end

    local contact_uuid = touch and touch.contact_uuid or (visitor and visitor.contact_uuid) or nil
    local identified = false
    if name == "identify" and not is_bot and not is_test then
        local email = U.norm_email(ev.em)
        local c = email and U.one([[
            SELECT uuid FROM crm_contacts WHERE namespace_id = ? AND lower(email) = ? AND deleted_at IS NULL
            ORDER BY created_at ASC LIMIT 1
        ]], ns, email)
        if c then
            contact_uuid = c.uuid
            identified = true
            if visitor then
                db.query("UPDATE mkt_visitors SET contact_uuid = ? WHERE id = ?", c.uuid, visitor.id)
            end
        end
    end

    if not touch and not is_bot and not is_test then
        touch = P.resolve_touch(pixel, visitor, contact_uuid, qp)
    end

    local value = tonumber(ev.v or props.value)
    if value and (value ~= value or math.abs(value) > 1e10) then value = nil end
    local currency = type(ev.cur or props.currency) == "string" and (ev.cur or props.currency):upper() or nil
    if currency and not currency:match("^%u%u%u$") then currency = nil end
    local order_id = clip(ev.oid and tostring(ev.oid) or nil, 128)

    local is_conversion = not is_bot and not is_test and (P.CONVERSION_EVENTS[name] == true
        or props.conversion == true or goal_matches(touch and touch.campaign_id, name))
    local settings = U.settings(ns)
    local forward = not is_bot and not is_test and forwarding_on(settings)
        and (is_conversion or name == "page_view" and settings.forward_page_views == true
             or name ~= "page_view" and name ~= "identify")

    local row = db.query([[
        INSERT INTO mkt_web_events
            (namespace_id, pixel_id, visitor_id, contact_uuid, event_name, event_id, url, referrer,
             utm_source, utm_medium, utm_campaign, utm_content, utm_term, campaign_id, delivery_id,
             value, currency, order_id, properties, ip_hash, user_agent, is_bot, is_test,
             is_conversion, forward_pending)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (pixel_id, event_id) WHERE event_id IS NOT NULL DO NOTHING
        RETURNING id, uuid
    ]], ns, pixel.id, nvl(visitor and visitor.id), nvl(contact_uuid), name, nvl(clip(ev.id, 128)),
        nvl(url), nvl(clip(ev.r, 2000)),
        nvl(clip(qp.utm_source, 255)), nvl(clip(qp.utm_medium, 255)), nvl(clip(qp.utm_campaign, 255)),
        nvl(clip(qp.utm_content, 255)), nvl(clip(qp.utm_term, 255)),
        nvl(touch and touch.campaign_id), nvl(touch and touch.delivery_id),
        nvl(value), nvl(currency), nvl(order_id), props_json, nvl(P.ip_hash(req.ip)),
        nvl(clip(req.ua, 512)), is_bot, is_test, is_conversion == true, forward == true)[1]

    db.query([[
        UPDATE mkt_pixels SET last_event_at = NOW()
        WHERE id = ? AND (last_event_at IS NULL OR last_event_at < NOW() - interval '30 seconds')
    ]], pixel.id)

    if not row then return { duplicate = true } end

    local conversion
    if is_conversion then
        conversion = db.query([[
            INSERT INTO mkt_conversions
                (namespace_id, web_event_id, campaign_id, delivery_id, contact_uuid, visitor_id,
                 event_name, value, currency, order_id, touch_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT DO NOTHING
            RETURNING uuid, campaign_id, delivery_id, value
        ]], ns, row.id, nvl(touch and touch.campaign_id), nvl(touch and touch.delivery_id), nvl(contact_uuid),
            nvl(visitor and visitor.id), name, value or 0, nvl(currency), nvl(order_id),
            nvl(touch and touch.at))[1]
        if not conversion then
            -- Same order already converted: keep the event, but don't count or forward it twice.
            db.query("UPDATE mkt_web_events SET is_conversion = false, forward_pending = false WHERE id = ?", row.id)
        end
        if conversion and touch and touch.delivery_id then
            db.query([[
                UPDATE mkt_deliveries SET converted_at = COALESCE(converted_at, NOW()),
                    conversion_value = conversion_value + ?, updated_at = NOW()
                WHERE id = ?
            ]], value or 0, touch.delivery_id)
            db.query([[
                INSERT INTO mkt_tracking_events
                    (namespace_id, delivery_id, campaign_id, contact_uuid, event_type, url)
                VALUES (?, ?, ?, ?, 'conversion', ?)
            ]], ns, touch.delivery_id, nvl(touch.campaign_id), nvl(contact_uuid), nvl(url))
        end
        if conversion then
            pcall(function()
                require("helper.plugin-sdk").emit(ns, "opsapi_marketing.conversion.recorded", {
                    conversion_uuid = conversion.uuid, event_name = name, value = value,
                    currency = currency, attributed = touch ~= nil,
                })
            end)
        end
    end

    return {
        event_uuid = row.uuid,
        duplicate = false,
        bot = is_bot,
        attributed = touch ~= nil and touch.campaign_id ~= nil,
        conversion = conversion ~= nil,
        identified = identified,
    }
end

-- ---------------------------------------------------------------------------
-- Browser script
-- ---------------------------------------------------------------------------

local SCRIPT = [==[
/* OpsAPI Marketing pixel */
(function (w, d) {
  "use strict";
  var KEY = __KEY__, EP = __EP__;
  if (w.mkt && w.mkt.loaded) return;
  var queue = (w.mkt && w.mkt.q) || [];
  var cfg = { autoPageview: true, spa: true, consent: true };
  var privacy = navigator.globalPrivacyControl === true || navigator.doNotTrack === "1";
  var consent = true, vid = null, attr = null, dom, lastUrl = null;

  function rid() {
    try { return crypto.randomUUID(); } catch (e) {}
    return "e" + Date.now().toString(36) + Math.random().toString(36).slice(2, 12);
  }
  function getCookie(n) {
    var m = d.cookie.match(new RegExp("(?:^|; )" + n + "=([^;]*)"));
    return m ? decodeURIComponent(m[1]) : null;
  }
  function rootDomain() {
    var h = location.hostname.split(".");
    for (var i = h.length - 2; i >= 0; i--) {
      var c = h.slice(i).join(".");
      d.cookie = "_mkt_t=1;domain=" + c + ";path=/;SameSite=Lax";
      if (getCookie("_mkt_t")) { d.cookie = "_mkt_t=;domain=" + c + ";path=/;max-age=0"; return c; }
    }
    return null;
  }
  function store(n, v, days) {
    if (!consent || privacy) return;
    try {
      if (dom === undefined) dom = rootDomain();
      d.cookie = n + "=" + encodeURIComponent(v) + ";path=/;max-age=" + days * 86400 + ";SameSite=Lax" +
        (dom ? ";domain=" + dom : "") + (location.protocol === "https:" ? ";Secure" : "");
    } catch (e) {}
    try { localStorage.setItem(n, v); } catch (e) {}
  }
  function load(n) {
    var v = null;
    try { v = getCookie(n); } catch (e) {}
    if (!v) { try { v = localStorage.getItem(n); } catch (e) {} }
    return v;
  }
  function forget(n) {
    try { d.cookie = n + "=;path=/;max-age=0" + (dom ? ";domain=" + dom : ""); } catch (e) {}
    try { localStorage.removeItem(n); } catch (e) {}
  }
  function initIds() {
    if (privacy || !consent) { vid = null; return; }
    vid = load("_mkt_vid") || rid().replace(/-/g, "");
    store("_mkt_vid", vid, 395);
    attr = attr || load("_mkt_at");
  }
  function captureAttribution() {
    try {
      var u = new URL(location.href), t = u.searchParams.get("_mkt");
      if (!t) return;
      attr = t;
      store("_mkt_at", t, 30);
      u.searchParams.delete("_mkt");
      history.replaceState(history.state, "", u.pathname + u.search + u.hash);
    } catch (e) {}
  }
  function send(ev) {
    ev.id = ev.id || rid();
    ev.u = ev.u || location.href;
    if (d.referrer) ev.r = d.referrer;
    if (vid) ev.vid = vid;
    if (attr) ev.mkt = attr;
    var body = JSON.stringify(ev), url = EP + "?k=" + encodeURIComponent(KEY);
    try {
      if (navigator.sendBeacon && navigator.sendBeacon(url, new Blob([body], { type: "text/plain" }))) return ev.id;
    } catch (e) {}
    try { fetch(url, { method: "POST", body: body, keepalive: true, mode: "no-cors" }); } catch (e) {}
    return ev.id;
  }
  function page(props) {
    if (lastUrl === location.href && !props) return;
    lastUrl = location.href;
    return send({ e: "page_view", p: props || { title: d.title } });
  }
  function track(name, props) {
    props = props || {};
    var ev = { e: String(name), p: props };
    if (props.value != null) ev.v = props.value;
    if (props.currency) ev.cur = props.currency;
    if (props.order_id || props.transaction_id) ev.oid = String(props.order_id || props.transaction_id);
    if (props.event_id) ev.id = String(props.event_id);
    return send(ev);
  }
  function identify(t) {
    if (privacy || !consent || !t) return;
    var em = typeof t === "string" ? t : t.email;
    if (em) return send({ e: "identify", em: String(em).trim().toLowerCase() });
  }
  var api = {
    init: function (k, o) {
      if (o) for (var x in o) cfg[x] = o[x];
      if (cfg.consent === false) consent = false;
      initIds();
      captureAttribution();
      if (cfg.autoPageview) page();
    },
    page: page,
    track: track,
    identify: identify,
    consent: function (v) {
      consent = !!v;
      if (consent) { initIds(); if (attr) store("_mkt_at", attr, 30); return; }
      forget("_mkt_vid"); forget("_mkt_at"); vid = null; attr = null;
    }
  };
  function call(args) {
    var m = api[args[0]];
    return m ? m.apply(null, [].slice.call(args, 1)) : undefined;
  }
  w.mkt = function () { return call(arguments); };
  w.mkt.loaded = true;

  var ps = history.pushState;
  history.pushState = function () {
    var r = ps.apply(this, arguments);
    if (cfg.spa && cfg.autoPageview) setTimeout(function () { page(); }, 0);
    return r;
  };
  w.addEventListener("popstate", function () { if (cfg.spa && cfg.autoPageview) page(); });
  d.addEventListener("click", function (e) {
    var el = e.target && e.target.closest && e.target.closest("[data-mkt-event]");
    if (!el) return;
    var p = {};
    try { p = JSON.parse(el.getAttribute("data-mkt-props") || "{}"); } catch (x) {}
    track(el.getAttribute("data-mkt-event"), p);
  }, true);

  var hasInit = false;
  for (var i = 0; i < queue.length; i++) if (queue[i][0] === "init") hasInit = true;
  if (!hasInit) api.init(KEY);
  for (var j = 0; j < queue.length; j++) call(queue[j]);
})(window, document);
]==]

function P.script(key, events_url)
    local js = SCRIPT:gsub("__KEY__", function() return cjson.encode(key) end)
    js = js:gsub("__EP__", function() return cjson.encode(events_url) end)
    return js
end

--- Install snippet (async loader + queue stub + noscript fallback).
function P.snippet(pixel, base)
    local ep = P.endpoints(base)
    local key = pixel.public_key
    local script_url = ep.script .. "?k=" .. key
    local html = table.concat({
        "<!-- OpsAPI Marketing pixel -->",
        "<script>",
        "!function(w,d,s,u){w.mkt=w.mkt||function(){(w.mkt.q=w.mkt.q||[]).push(arguments)};"
            .. "var j=d.createElement(s);j.async=1;j.src=u;d.head.appendChild(j)}"
            .. "(window,document,'script','" .. script_url .. "');",
        "mkt('init','" .. key .. "');",
        "</script>",
        '<noscript><img height="1" width="1" style="display:none" alt="" src="'
            .. ep.gif .. "?k=" .. key .. '&e=page_view"/></noscript>',
    }, "\n")
    return {
        public_key = key,
        html = html,
        script_url = script_url,
        events_url = ep.events,
        gif_url = ep.gif .. "?k=" .. key,
        examples = {
            purchase = "mkt('track', 'purchase', { value: 49.99, currency: 'GBP', order_id: 'ORDER-123' });",
            lead = "mkt('track', 'lead', { form: 'contact' });",
            identify = "mkt('identify', { email: 'customer@example.com' });",
            consent = "mkt('consent', false); // stop cookies until the visitor agrees",
            declarative = '<button data-mkt-event="sign_up" data-mkt-props=\'{"plan":"pro"}\'>Sign up</button>',
        },
    }
end

return P
