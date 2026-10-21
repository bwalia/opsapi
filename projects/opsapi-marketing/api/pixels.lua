-- Website pixels: create/manage, install snippet, live event debugger, stats, test events.
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local cjson = require("cjson")
local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("opsapi_marketing.util")
local Pixel = require("opsapi_marketing.pixel")

local READ = "opsapi_marketing_analytics.read"
local WRITE = "opsapi_marketing_settings.update"

local function window_days(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.floor(n)
    if n < 1 or n > 90 then return nil, "attribution_window_days must be 1–90" end
    return n
end

local function with_status(row)
    local s = U.one([[
        SELECT COUNT(*) FILTER (WHERE created_at > NOW() - interval '24 hours')::int AS events_24h,
               COUNT(*) FILTER (WHERE is_conversion AND created_at > NOW() - interval '30 days')::int AS conversions_30d
        FROM mkt_web_events WHERE pixel_id = ? AND NOT is_test
    ]], row.id) or {}
    row.events_24h = s.events_24h or 0
    row.conversions_30d = s.conversions_30d or 0
    local seen = row.last_event_at and U.one("SELECT ?::timestamptz > NOW() - interval '24 hours' AS fresh",
        row.last_event_at)
    row.install_status = not row.last_event_at and "waiting" or (seen and seen.fresh and "active" or "stale")
    row.allowed_domains = U.array(U.json(row.allowed_domains) or {})
    return row
end

return function(app)
    app:get("/pixels", sdk.handler({ permission = READ }, function(self)
        local ns = sdk.namespace_id(self)
        local rows = db.query("SELECT * FROM mkt_pixels WHERE namespace_id = ? ORDER BY created_at DESC", ns)
        for i, r in ipairs(rows) do rows[i] = with_status(r) end
        return sdk.ok(sdk.array(rows))
    end))

    app:post("/pixels", sdk.handler({ permission = WRITE }, function(self)
        local ns = sdk.namespace_id(self)
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local name = type(body.name) == "string" and body.name:match("^%s*(.-)%s*$") or ""
        if name == "" then return sdk.error(400, "name is required") end
        local win, werr = window_days(body.attribution_window_days)
        if werr then return sdk.error(400, werr) end
        local row = db.query([[
            INSERT INTO mkt_pixels (namespace_id, name, public_key, allowed_domains, attribution_window_days)
            VALUES (?, ?, ?, ?::jsonb, ?)
            RETURNING *
        ]], ns, name:sub(1, 255), Pixel.new_key(), cjson.encode(Pixel.normalize_domains(body.allowed_domains)),
            win or 7)[1]
        return sdk.created(with_status(row))
    end))

    app:get("/pixels/:id", sdk.handler({ permission = READ }, function(self)
        local pixel = Pixel.find(sdk.namespace_id(self), self.params.id)
        if not pixel then return sdk.not_found("pixel") end
        return sdk.ok(with_status(pixel))
    end))

    app:put("/pixels/:id", sdk.handler({ permission = WRITE }, function(self)
        local ns = sdk.namespace_id(self)
        local pixel = Pixel.find(ns, self.params.id)
        if not pixel then return sdk.not_found("pixel") end
        local body, berr = sdk.body(self)
        if not body then return sdk.error(400, berr) end
        local win, werr = window_days(body.attribution_window_days)
        if werr then return sdk.error(400, werr) end
        local name = type(body.name) == "string" and body.name:match("^%s*(.-)%s*$") or nil
        db.query([[
            UPDATE mkt_pixels SET
                name = COALESCE(?, name),
                allowed_domains = COALESCE(?::jsonb, allowed_domains),
                attribution_window_days = COALESCE(?, attribution_window_days),
                is_active = COALESCE(?::boolean, is_active),
                updated_at = NOW()
            WHERE id = ?
        ]], name ~= "" and name or db.NULL,
            body.allowed_domains ~= nil and cjson.encode(Pixel.normalize_domains(body.allowed_domains)) or db.NULL,
            win or db.NULL, type(body.is_active) == "boolean" and tostring(body.is_active) or db.NULL, pixel.id)
        return sdk.ok(with_status(Pixel.find(ns, pixel.id)))
    end))

    app:delete("/pixels/:id", sdk.handler({ permission = WRITE }, function(self)
        local ns = sdk.namespace_id(self)
        local pixel = Pixel.find(ns, self.params.id)
        if not pixel then return sdk.not_found("pixel") end
        db.query("DELETE FROM mkt_pixels WHERE id = ?", pixel.id)
        return sdk.ok({ deleted = true })
    end))

    -- New key; the old snippet stops working immediately.
    app:post("/pixels/:id/rotate-key", sdk.handler({ permission = WRITE }, function(self)
        local ns = sdk.namespace_id(self)
        local pixel = Pixel.find(ns, self.params.id)
        if not pixel then return sdk.not_found("pixel") end
        db.query("UPDATE mkt_pixels SET public_key = ?, updated_at = NOW() WHERE id = ?", Pixel.new_key(), pixel.id)
        return sdk.ok(with_status(Pixel.find(ns, pixel.id)))
    end))

    app:get("/pixels/:id/snippet", sdk.handler({ permission = READ }, function(self)
        local ns = sdk.namespace_id(self)
        local pixel = Pixel.find(ns, self.params.id)
        if not pixel then return sdk.not_found("pixel") end
        return sdk.ok(Pixel.snippet(pixel, Pixel.public_base(ns, self)))
    end))

    -- Live debugger: newest events first; poll with after_id for new ones.
    app:get("/pixels/:id/events", sdk.handler({ permission = READ }, function(self)
        local ns = sdk.namespace_id(self)
        local pixel = Pixel.find(ns, self.params.id)
        if not pixel then return sdk.not_found("pixel") end
        local limit = math.min(tonumber(self.params.limit) or 50, 200)
        local after = tonumber(self.params.after_id) or 0
        local rows = db.query([[
            SELECT e.id, e.uuid, e.event_name, e.url, e.referrer, e.value, e.currency, e.order_id,
                   e.utm_source, e.utm_medium, e.utm_campaign, e.properties, e.is_bot, e.is_test,
                   e.is_conversion, e.contact_uuid, e.created_at,
                   c.name AS campaign_name, c.uuid AS campaign_uuid,
                   v.visitor_key,
                   NULLIF(TRIM(COALESCE(ct.first_name, '') || ' ' || COALESCE(ct.last_name, '')), '') AS contact_name
            FROM mkt_web_events e
            LEFT JOIN mkt_campaigns c ON c.id = e.campaign_id
            LEFT JOIN mkt_visitors v ON v.id = e.visitor_id
            LEFT JOIN crm_contacts ct ON ct.uuid = e.contact_uuid AND ct.namespace_id = e.namespace_id
            WHERE e.pixel_id = ? AND e.id > ?
            ORDER BY e.id DESC LIMIT ?
        ]], pixel.id, after, limit)
        return sdk.ok(sdk.array(rows))
    end))

    app:post("/pixels/:id/test-event", sdk.handler({ permission = WRITE }, function(self)
        local ns = sdk.namespace_id(self)
        local pixel = Pixel.find(ns, self.params.id)
        if not pixel then return sdk.not_found("pixel") end
        local body = sdk.body(self) or {}
        local list = U.json(pixel.allowed_domains) or {}
        local url = type(body.url) == "string" and body.url
            or ("https://" .. (list[1] or "example.com") .. "/opsapi-pixel-test")
        local out, err = Pixel.ingest(pixel, {
            e = type(body.event) == "string" and body.event or "test_event",
            u = url,
            p = { source = "dashboard_test" },
        }, { ua = "OpsAPI dashboard test", test = true })
        if not out then return sdk.error(400, err) end
        return sdk.ok(out)
    end))

    app:get("/pixels/:id/stats", sdk.handler({ permission = READ }, function(self)
        local ns = sdk.namespace_id(self)
        local pixel = Pixel.find(ns, self.params.id)
        if not pixel then return sdk.not_found("pixel") end
        local days = math.min(math.max(tonumber(self.params.days) or 7, 1), 90)
        local totals = U.one([[
            SELECT COUNT(*)::int AS events,
                   COUNT(DISTINCT visitor_id)::int AS visitors,
                   COUNT(DISTINCT contact_uuid)::int AS identified,
                   COUNT(*) FILTER (WHERE campaign_id IS NOT NULL)::int AS attributed_events,
                   COUNT(*) FILTER (WHERE is_conversion)::int AS conversions,
                   COALESCE(SUM(value) FILTER (WHERE is_conversion), 0)::float AS revenue,
                   COUNT(*) FILTER (WHERE is_bot)::int AS bot_events
            FROM mkt_web_events
            WHERE pixel_id = ? AND NOT is_test AND created_at > NOW() - make_interval(days => ?)
        ]], pixel.id, days)
        local daily = db.query([[
            SELECT to_char(date_trunc('day', created_at), 'YYYY-MM-DD') AS day,
                   COUNT(*) FILTER (WHERE event_name = 'page_view' AND NOT is_bot)::int AS page_views,
                   COUNT(*) FILTER (WHERE is_conversion)::int AS conversions,
                   COUNT(DISTINCT visitor_id)::int AS visitors
            FROM mkt_web_events
            WHERE pixel_id = ? AND NOT is_test AND created_at > NOW() - make_interval(days => ?)
            GROUP BY 1 ORDER BY 1
        ]], pixel.id, days)
        local top_events = db.query([[
            SELECT event_name, COUNT(*)::int AS n FROM mkt_web_events
            WHERE pixel_id = ? AND NOT is_test AND NOT is_bot AND created_at > NOW() - make_interval(days => ?)
            GROUP BY 1 ORDER BY n DESC LIMIT 10
        ]], pixel.id, days)
        local top_pages = db.query([[
            SELECT split_part(url, chr(63), 1) AS page, COUNT(*)::int AS n FROM mkt_web_events
            WHERE pixel_id = ? AND event_name = 'page_view' AND NOT is_test AND NOT is_bot
              AND created_at > NOW() - make_interval(days => ?)
            GROUP BY 1 ORDER BY n DESC LIMIT 10
        ]], pixel.id, days)
        local forwards = db.query([[
            SELECT f.destination, f.status, COUNT(*)::int AS n FROM mkt_pixel_forwards f
            JOIN mkt_web_events e ON e.id = f.web_event_id
            WHERE e.pixel_id = ? AND f.created_at > NOW() - make_interval(days => ?)
            GROUP BY 1, 2
        ]], pixel.id, days)
        return sdk.ok({
            days = days, totals = totals, daily = sdk.array(daily), top_events = sdk.array(top_events),
            top_pages = sdk.array(top_pages), forwards = sdk.array(forwards),
        })
    end))

    app:get("/pixel-forwards", sdk.handler({ permission = READ }, function(self)
        local ns = sdk.namespace_id(self)
        local rows = db.query([[
            SELECT f.id, f.destination, f.status, f.http_status, f.response, f.created_at, e.event_name
            FROM mkt_pixel_forwards f LEFT JOIN mkt_web_events e ON e.id = f.web_event_id
            WHERE f.namespace_id = ? ORDER BY f.id DESC LIMIT ?
        ]], ns, math.min(tonumber(self.params.limit) or 50, 200))
        return sdk.ok(sdk.array(rows))
    end))
end
