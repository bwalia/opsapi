-- luacheck: max line length 140
--[[
    Sales orders: every order of the workspace in one list, whatever it came through
    =================================================================================
    GET /api/v2/sales-orders (routes/sales-orders.lua) — the dashboard's Sales Orders page. Each source of orders
    is one entry in SOURCES (add one to bring another module's orders in); a source is used when its tables
    exist and the person has its permission:

      shop    shop_orders (RBAC shop.read): online checkout, orders built by staff (an Order Authorisation, e.g.
              taken on the phone) and accepted quotes. Opens /dashboard/shop/orders/:uuid.
      store   orders of the Stores & Products module (RBAC orders.read), in this workspace (the order's
              workspace, or its store's for older checkout orders): online store checkout, or created by staff
              (orders.source = phone | in_person | email; a point-of-sale screen would write 'pos'). Opened in the
              Sales Orders page.

    Every order gets one common shape and stage:
      stage    awaiting_payment | confirmed | processing | shipped | delivered | cancelled | refunded | failed
      payment  pending | paid | refunded | failed
      channel  online | phone | in_person | email | pos | staff (a shop order built by staff) | quote

    list(self, ns_id, params)   params { q?, stage?, source?, channel?, from?, to? (YYYY-MM-DD), page?, per_page? (≤ 100) }
      → rows, { total, page, per_page, sources = [keys used], stats = { total, awaiting_payment, in_progress,
                delivered, revenue = { currency → paid total } } }   (stats: same filters except stage)

    Specced by spec/sales-orders_spec.lua and the SQL check in spec/shop-ops-pack-e2e.
]]

local db = require("lapis.db")

local Q = {}

Q.STAGES = { awaiting_payment = true, confirmed = true, processing = true, shipped = true, delivered = true,
    cancelled = true, refunded = true, failed = true }
Q.CHANNELS = { online = true, phone = true, in_person = true, email = true, pos = true, staff = true, quote = true }

local function exists(t, c) return require("helper.table-exists")(t, c) end

-- Each source: one SELECT with the common columns, all named (any source can come first in the union), filtered
-- to the workspace (the only placeholder is the workspace id; the rest is filtered outside, on the union).
Q.SOURCES = {
    {
        key = "shop", permission = { "shop", "read" },
        ready = function() return exists("shop_orders") and exists("shop_quotes") end,
        sql = [[
            SELECT 'shop'::text AS source, o.uuid::text AS uuid, o.order_number::text AS order_number,
                   (o.created_at AT TIME ZONE 'UTC') AS placed_at,
                   CASE o.status WHEN 'pending_payment' THEN 'awaiting_payment' WHEN 'payment_failed' THEN 'failed'
                                 WHEN 'paid' THEN 'confirmed' ELSE o.status END::text AS stage,
                   CASE WHEN o.status IN ('paid','processing','shipped','delivered') THEN 'paid'
                        WHEN o.status = 'refunded' THEN 'refunded' WHEN o.status = 'payment_failed' THEN 'failed'
                        ELSE 'pending' END::text AS payment,
                   ROUND(o.total_minor / 100.0, 2)::numeric AS total, COALESCE(o.currency, 'GBP')::text AS currency,
                   COALESCE(NULLIF(o.customer->>'name', ''), o.email)::text AS customer_name, o.email::text AS customer_email,
                   NULLIF(o.customer->>'company', '')::text AS company,
                   CASE WHEN q.kind = 'order' THEN 'staff' WHEN o.quote_id IS NOT NULL THEN 'quote' ELSE 'online' END::text AS channel
              FROM shop_orders o LEFT JOIN shop_quotes q ON q.id = o.quote_id
             WHERE o.namespace_id = ?]],
    },
    {
        key = "store", permission = { "orders", "read" },
        ready = function() return exists("orders", "namespace_id") and exists("stores", "namespace_id") and exists("customers") end,
        sql = function()
            local src = exists("orders", "source") and "COALESCE(o.source, 'online')" or "'online'"
            return [[
            SELECT 'store'::text AS source, o.uuid::text AS uuid, o.order_number::text AS order_number,
                   (o.created_at AT TIME ZONE 'UTC') AS placed_at,
                   CASE WHEN o.status = 'pending' AND o.financial_status = 'paid' THEN 'confirmed'
                        WHEN o.status = 'pending' THEN 'awaiting_payment'
                        WHEN o.status IN ('ready_for_pickup', 'out_for_delivery') THEN 'shipped'
                        WHEN o.status IN ('confirmed','processing','shipped','delivered','cancelled','refunded') THEN o.status
                        ELSE 'processing' END::text AS stage,
                   CASE o.financial_status WHEN 'paid' THEN 'paid' WHEN 'refunded' THEN 'refunded' WHEN 'failed' THEN 'failed'
                        ELSE 'pending' END::text AS payment,
                   ROUND(o.total_amount, 2)::numeric AS total, COALESCE(o.currency, 'GBP')::text AS currency,
                   COALESCE(NULLIF(concat_ws(' ', c.first_name, c.last_name), ''), c.email)::text AS customer_name,
                   c.email::text AS customer_email, NULL::text AS company, ]] .. src .. [[::text AS channel
              FROM orders o JOIN stores s ON s.id = o.store_id LEFT JOIN customers c ON c.id = o.customer_id
             WHERE COALESCE(o.namespace_id, s.namespace_id) = ?]]
        end,
    },
}

local function valid_date(s) return type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil end

--- The sources this person may see in this deployment. → { def, ... }
function Q.sources_for(self)
    local NS = require("middleware.namespace")
    local out = {}
    for _, s in ipairs(Q.SOURCES) do
        if s.ready() and NS.hasPermission(self, s.permission[1], s.permission[2]) then out[#out + 1] = s end
    end
    return out
end

--- WHERE on the union for the filters (stage separately: the stats ignore it). → sql, vals | nil, err
function Q.filters(params, with_stage)
    local where, vals = {}, {}
    if with_stage and params.stage and params.stage ~= "" then
        if params.stage == "in_progress" then
            where[#where + 1] = "stage IN ('confirmed', 'processing', 'shipped')"
        elseif Q.STAGES[params.stage] then
            where[#where + 1] = "stage = ?"
            vals[#vals + 1] = params.stage
        else
            return nil, { status = 400, message = "stage must be in_progress or one of awaiting_payment, confirmed, processing, "
                .. "shipped, delivered, cancelled, refunded, failed" }
        end
    end
    if params.channel and params.channel ~= "" then
        if not Q.CHANNELS[params.channel] then
            return nil, { status = 400, message = "channel must be online, phone, in_person, email, pos, staff or quote" }
        end
        where[#where + 1] = "channel = ?"
        vals[#vals + 1] = params.channel
    end
    for key, op in pairs({ from = ">=", to = "<" }) do
        local v = params[key]
        if v and v ~= "" then
            if not valid_date(v) then return nil, { status = 400, message = key .. " must be a date (YYYY-MM-DD)" } end
            -- "to" includes that whole day
            where[#where + 1] = "placed_at " .. op .. " (?::date" .. (key == "to" and " + 1" or "") .. ")::timestamp AT TIME ZONE 'UTC'"
            vals[#vals + 1] = v
        end
    end
    if params.q and params.q ~= "" then
        local like = "%" .. tostring(params.q):sub(1, 100):gsub("[%%_\\]", "\\%0") .. "%"
        where[#where + 1] = "(order_number ILIKE ? OR customer_name ILIKE ? OR customer_email ILIKE ? OR company ILIKE ?)"
        for _ = 1, 4 do vals[#vals + 1] = like end
    end
    return (#where > 0 and (" WHERE " .. table.concat(where, " AND ")) or ""), vals
end

local unpack_ = table.unpack or unpack -- luacheck: ignore 113 143

function Q.list(self, ns_id, params)
    params = params or {}
    local sources = Q.sources_for(self)
    if params.source and params.source ~= "" then
        local only = {}
        for _, s in ipairs(sources) do if s.key == params.source then only[#only + 1] = s end end
        sources = only
    end
    local page = math.max(1, math.floor(tonumber(params.page) or 1))
    local per_page = math.min(100, math.max(1, math.floor(tonumber(params.per_page) or 25)))
    local used = {}
    for _, s in ipairs(sources) do used[#used + 1] = s.key end
    local empty = { total = 0, page = page, per_page = per_page, sources = used,
                    stats = { total = 0, awaiting_payment = 0, in_progress = 0, delivered = 0, revenue = {} } }
    if #sources == 0 then return {}, empty end

    local parts, base_vals = {}, {}
    for _, s in ipairs(sources) do
        parts[#parts + 1] = type(s.sql) == "function" and s.sql() or s.sql
        base_vals[#base_vals + 1] = ns_id
    end
    local union = "(" .. table.concat(parts, "\nUNION ALL\n") .. ") x"

    local where, vals = Q.filters(params, true)
    if not where then return nil, vals end
    local args = {}
    for _, v in ipairs(base_vals) do args[#args + 1] = v end
    for _, v in ipairs(vals) do args[#args + 1] = v end
    args[#args + 1] = per_page
    args[#args + 1] = (page - 1) * per_page
    local rows = db.query("SELECT x.*, to_char(placed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS placed, "
        .. "COUNT(*) OVER () AS total_count FROM " .. union .. where
        .. " ORDER BY placed_at DESC, order_number DESC LIMIT ? OFFSET ?", unpack_(args))

    local swhere, svals = Q.filters(params, false)
    local sargs = {}
    for _, v in ipairs(base_vals) do sargs[#sargs + 1] = v end
    for _, v in ipairs(svals) do sargs[#sargs + 1] = v end
    local st = db.query([[SELECT COUNT(*) AS total,
            COUNT(*) FILTER (WHERE stage = 'awaiting_payment') AS awaiting_payment,
            COUNT(*) FILTER (WHERE stage IN ('confirmed', 'processing', 'shipped')) AS in_progress,
            COUNT(*) FILTER (WHERE stage = 'delivered') AS delivered
        FROM ]] .. union .. swhere, unpack_(sargs))[1] or {}
    local rev = db.query("SELECT currency, SUM(total) AS paid FROM " .. union .. swhere
        .. (swhere == "" and " WHERE " or " AND ") .. "payment = 'paid' GROUP BY currency", unpack_(sargs))
    local revenue = {}
    for _, r in ipairs(rev) do revenue[r.currency] = string.format("%.2f", tonumber(r.paid) or 0) end

    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            source = r.source, uuid = r.uuid, order_number = r.order_number, placed_at = r.placed, stage = r.stage,
            payment = r.payment, total = string.format("%.2f", tonumber(r.total) or 0), currency = r.currency,
            customer_name = r.customer_name, customer_email = r.customer_email, company = r.company, channel = r.channel,
            path = r.source == "shop" and ("/dashboard/shop/orders/" .. r.uuid) or nil,
        }
    end
    return out, {
        total = rows[1] and tonumber(rows[1].total_count) or 0, page = page, per_page = per_page, sources = used,
        stats = { total = tonumber(st.total) or 0, awaiting_payment = tonumber(st.awaiting_payment) or 0,
                  in_progress = tonumber(st.in_progress) or 0, delivered = tonumber(st.delivered) or 0, revenue = revenue },
    }
end

return Q
