-- luacheck: max line length 140
--[[
    Shop Analytics (GET /api/v2/shop/admin/analytics, RBAC module "shop_analytics")
    ================================================================================
    Server-derived metrics, computed only from rows the shop already stores:
    shop_orders, shop_carts (+ lines), shop_quotes, shop_chat_sessions,
    shop_cart_events and (when membership is deployed) shop_memberships.

    No visitor tracking: nothing here reads or needs a cookie, a visitor id, an
    IP address or a page view. Visitor analytics are switched off until the
    privacy/cookie review is signed off (docs/SHOP_ANALYTICS.md).

    Definitions (also shown in the dashboard's "How these are measured" panel):
      Revenue           total_minor (inc VAT + shipping) of orders PAID in the window
                        (by paid_at), including orders since fully refunded.
      Refunds           money returned on those same orders (refunded_minor; a full
                        refund recorded only as status 'refunded' counts total_minor).
      Net revenue       revenue - refunds.
      AOV               revenue / paid orders.
      New customer      first paid order (by email) falls inside the window.
      Checkout started  an order created in the window (status pending_payment at
                        first). Repeat attempts on the same cart/quote count once.
      Cart              created in the window (carts are created on first add).
      Abandoned cart    has items, never paid, untouched for 24 hours.
      Chat              session created in the window with at least one visitor message.
      AI replied        at least one assistant message that is not "(no reply)".
      Completed chat    AI replied AND (contact saved OR quote OR add_to_cart OR order).
    Windows are UK calendar days (Europe/London), inclusive.
]]

local db = require("lapis.db")
local A = require("lib.shop-analytics")

local Q = {}

local PAID = A.sql_list(A.PAID_STATUSES)
local PAID_OR_REFUNDED = A.sql_list({ "paid", "processing", "shipped", "delivered", A.REFUNDED_STATUS })
local TZ = "'" .. A.TIMEZONE .. "'"

-- Window bounds as SQL taking one "YYYY-MM-DD" parameter each.
--   *_TS: for `timestamp` (no time zone) columns, which hold the database
--         session's local time (NOW() written into a timestamp column).
--   *_TZ: for `timestamptz` columns.
local BOUND_TS = "((?::date)::timestamp AT TIME ZONE " .. TZ .. ")::timestamp"
local BOUND_TZ = "((?::date)::timestamp AT TIME ZONE " .. TZ .. ")"

local function in_window(col, tz)
    local b = tz and BOUND_TZ or BOUND_TS
    return col .. " >= " .. b .. " AND " .. col .. " < " .. b
end

local BUCKETS = { day = true, week = true, month = true }
local function bucket_of(col, bucket, tz)
    assert(BUCKETS[bucket], "bad bucket")
    local local_time = tz and ("(" .. col .. " AT TIME ZONE " .. TZ .. ")")
        or ("((" .. col .. ")::timestamptz AT TIME ZONE " .. TZ .. ")")
    return "date_trunc('" .. bucket .. "', " .. local_time .. ")::date"
end

-- ---------------------------------------------------------------------------
-- Optional schema (columns/tables added by later or feature-gated migrations).
-- Checked once per worker; analytics degrade instead of erroring.
-- ---------------------------------------------------------------------------
local schema_cache
local function schema()
    if schema_cache then return schema_cache end
    local cols = {}
    for _, r in ipairs(db.query([[
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = current_schema() AND table_name = 'shop_orders'
           AND column_name IN ('refunded_minor', 'member_discount_minor', 'credit_minor')
    ]])) do cols[r.column_name] = true end
    local t = db.query("SELECT to_regclass('shop_memberships') IS NOT NULL AS memberships")[1] or {}
    schema_cache = {
        refunded_minor = cols.refunded_minor == true,
        member_discount_minor = cols.member_discount_minor == true,
        credit_minor = cols.credit_minor == true,
        memberships = t.memberships == true,
    }
    return schema_cache
end
Q._reset_schema_cache = function() schema_cache = nil end

function Q.today()
    local r = db.query("SELECT to_char((NOW() AT TIME ZONE " .. TZ .. ")::date, 'YYYY-MM-DD') AS today")[1]
    return r.today
end

local n = A.num

-- ---------------------------------------------------------------------------
-- Sales: orders paid in the window
-- ---------------------------------------------------------------------------
function Q.sales(ns_id, from, to_excl)
    local s = schema()
    local refunds = s.refunded_minor
        and "CASE WHEN status = 'refunded' AND COALESCE(refunded_minor, 0) = 0 THEN total_minor ELSE COALESCE(refunded_minor, 0) END"
        or "CASE WHEN status = 'refunded' THEN total_minor ELSE 0 END"
    local r = db.query([[
        SELECT COUNT(*)::int AS orders,
               COALESCE(SUM(total_minor), 0)::bigint AS revenue_minor,
               COALESCE(SUM(total_minor - vat_minor), 0)::bigint AS revenue_ex_vat_minor,
               COALESCE(SUM(vat_minor), 0)::bigint AS vat_minor,
               COALESCE(SUM(shipping_minor), 0)::bigint AS shipping_minor,
               COALESCE(SUM(]] .. refunds .. [[), 0)::bigint AS refunds_minor,
               COUNT(*) FILTER (WHERE status = 'refunded')::int AS refunded_orders,
               ]] .. (s.member_discount_minor and "COALESCE(SUM(member_discount_minor), 0)::bigint" or "0::bigint")
               .. [[ AS trade_discount_minor,
               ]] .. (s.credit_minor and "COALESCE(SUM(credit_minor), 0)::bigint" or "0::bigint") .. [[ AS credit_used_minor,
               COUNT(DISTINCT lower(email))::int AS customers,
               COUNT(DISTINCT lower(email)) FILTER (WHERE NOT EXISTS (
                   SELECT 1 FROM shop_orders p
                    WHERE p.namespace_id = o.namespace_id AND lower(p.email) = lower(o.email)
                      AND p.paid_at IS NOT NULL AND p.status IN ]] .. PAID_OR_REFUNDED .. [[
                      AND p.paid_at < ]] .. BOUND_TS .. [[
               ))::int AS new_customers
          FROM shop_orders o
         WHERE o.namespace_id = ? AND o.status IN ]] .. PAID_OR_REFUNDED .. [[
           AND ]] .. in_window("o.paid_at") .. [[
    ]], from, ns_id, from, to_excl)[1] or {}
    local out = {
        orders = n(r.orders),
        revenue_minor = n(r.revenue_minor),
        revenue_ex_vat_minor = n(r.revenue_ex_vat_minor),
        vat_minor = n(r.vat_minor),
        shipping_minor = n(r.shipping_minor),
        refunds_minor = n(r.refunds_minor),
        refunded_orders = n(r.refunded_orders),
        trade_discount_minor = n(r.trade_discount_minor),
        credit_used_minor = n(r.credit_used_minor),
        customers = n(r.customers),
        new_customers = n(r.new_customers),
    }
    out.returning_customers = math.max(out.customers - out.new_customers, 0)
    out.net_revenue_minor = out.revenue_minor - out.refunds_minor
    out.aov_minor = A.average_minor(out.revenue_minor, out.orders)
    return out
end

-- ---------------------------------------------------------------------------
-- Checkout: orders created in the window (a checkout creates the order)
-- ---------------------------------------------------------------------------
local ATTEMPT_KEY = "COALESCE('c' || cart_id::text, 'q' || quote_id::text, 'o' || id::text)"

function Q.checkout(ns_id, from, to_excl)
    local r = db.query([[
        SELECT COUNT(*)::int AS sessions,
               COUNT(DISTINCT ]] .. ATTEMPT_KEY .. [[)::int AS started,
               COUNT(DISTINCT ]] .. ATTEMPT_KEY .. [[) FILTER (WHERE paid_at IS NOT NULL)::int AS paid,
               COUNT(*) FILTER (WHERE status = 'payment_failed')::int AS payment_failed,
               COUNT(*) FILTER (WHERE status = 'pending_payment')::int AS pending,
               COUNT(*) FILTER (WHERE status = 'cancelled')::int AS cancelled,
               COUNT(DISTINCT ]] .. ATTEMPT_KEY .. [[) FILTER (WHERE quote_id IS NOT NULL)::int AS from_quote
          FROM shop_orders
         WHERE namespace_id = ? AND ]] .. in_window("created_at") .. [[
    ]], ns_id, from, to_excl)[1] or {}
    local out = {
        sessions = n(r.sessions), started = n(r.started), paid = n(r.paid),
        payment_failed = n(r.payment_failed), pending = n(r.pending), cancelled = n(r.cancelled),
        from_quote = n(r.from_quote),
    }
    out.paid_rate = A.ratio(out.paid, out.started)
    return out
end

-- ---------------------------------------------------------------------------
-- Carts created in the window
-- ---------------------------------------------------------------------------
function Q.carts(ns_id, from, to_excl)
    local r = db.query([[
        WITH c AS (
            SELECT c.id, c.status, COALESCE(c.last_seen_at, c.updated_at, c.created_at) AS seen,
                   COALESCE(l.items, 0) AS items, COALESCE(l.value_minor, 0) AS value_minor,
                   EXISTS (SELECT 1 FROM shop_orders o WHERE o.cart_id = c.id) AS checked_out,
                   (c.status = 'converted' OR EXISTS (
                       SELECT 1 FROM shop_orders o WHERE o.cart_id = c.id AND o.paid_at IS NOT NULL)) AS paid
              FROM shop_carts c
              LEFT JOIN LATERAL (
                  SELECT SUM(qty)::bigint AS items, SUM(qty::bigint * COALESCE(unit_price_minor, 0))::bigint AS value_minor
                    FROM shop_cart_lines WHERE cart_id = c.id
              ) l ON true
             WHERE c.namespace_id = ? AND ]] .. in_window("c.created_at") .. [[
        )
        SELECT COUNT(*)::int AS created,
               COUNT(*) FILTER (WHERE items > 0 OR paid)::int AS with_items,
               COUNT(*) FILTER (WHERE checked_out)::int AS reached_checkout,
               COUNT(*) FILTER (WHERE paid)::int AS converted,
               COUNT(*) FILTER (WHERE items > 0 AND NOT paid
                                AND seen < NOW() - make_interval(hours => ]] .. A.ABANDON_HOURS .. [[))::int AS abandoned,
               COALESCE(SUM(value_minor) FILTER (WHERE items > 0 AND NOT paid
                                AND seen < NOW() - make_interval(hours => ]] .. A.ABANDON_HOURS .. [[)), 0)::bigint
                   AS abandoned_value_minor,
               COUNT(*) FILTER (WHERE items > 0 AND NOT paid
                                AND seen >= NOW() - make_interval(hours => ]] .. A.ABANDON_HOURS .. [[))::int AS open
          FROM c
    ]], ns_id, from, to_excl)[1] or {}
    local out = {
        created = n(r.created), with_items = n(r.with_items), reached_checkout = n(r.reached_checkout),
        converted = n(r.converted), abandoned = n(r.abandoned), abandoned_value_minor = n(r.abandoned_value_minor),
        open = n(r.open), abandon_after_hours = A.ABANDON_HOURS,
    }
    out.conversion_rate = A.ratio(out.converted, out.with_items)
    -- Abandonment among carts whose outcome is known (open carts may still buy).
    out.abandonment_rate = A.ratio(out.abandoned, out.abandoned + out.converted)
    return out
end

-- ---------------------------------------------------------------------------
-- Quotes created in the window
-- ---------------------------------------------------------------------------
function Q.quotes(ns_id, from, to_excl)
    local r = db.query([[
        SELECT COUNT(*)::int AS created,
               COALESCE(SUM(total_minor), 0)::bigint AS value_minor,
               COUNT(*) FILTER (WHERE source = 'cart')::int AS from_cart,
               COUNT(*) FILTER (WHERE source = 'chat')::int AS from_chat,
               COUNT(*) FILTER (WHERE source = 'admin')::int AS from_admin,
               COUNT(*) FILTER (WHERE viewed_at IS NOT NULL)::int AS viewed,
               COUNT(*) FILTER (WHERE status = 'accepted')::int AS accepted,
               COUNT(*) FILTER (WHERE status = 'converted')::int AS converted,
               COALESCE(SUM(total_minor) FILTER (WHERE status = 'converted'), 0)::bigint AS converted_value_minor,
               COUNT(*) FILTER (WHERE status = 'expired' OR (status IN ('draft','sent','accepted') AND valid_until <= NOW()))::int
                   AS expired
          FROM shop_quotes
         WHERE namespace_id = ? AND ]] .. in_window("created_at") .. [[
    ]], ns_id, from, to_excl)[1] or {}
    local out = {
        created = n(r.created), value_minor = n(r.value_minor),
        by_source = { cart = n(r.from_cart), chat = n(r.from_chat), admin = n(r.from_admin) },
        viewed = n(r.viewed), accepted = n(r.accepted), converted = n(r.converted),
        converted_value_minor = n(r.converted_value_minor), expired = n(r.expired),
    }
    out.conversion_rate = A.ratio(out.converted, out.created)
    out.average_value_minor = A.average_minor(out.value_minor, out.created)
    return out
end

-- ---------------------------------------------------------------------------
-- AI chat sessions created in the window
-- ---------------------------------------------------------------------------
-- Per-session facts. The jsonb checks mirror A.is_ai_reply / A.tools_from_content.
local CHAT_FACTS = [==[
    SELECT s.id, s.order_id, s.quote_id, s.consent_at, s.is_member, s.country,
           (SELECT COUNT(*) FROM jsonb_array_elements(s.messages) m WHERE m->>'role' = 'user') AS user_msgs,
           EXISTS (SELECT 1 FROM jsonb_array_elements(s.messages) m
                    WHERE m->>'role' = 'assistant'
                      AND btrim(regexp_replace(COALESCE(m->>'content', ''), '\[tools: [^]]*\]\s*$', '')) <> ''
                      AND btrim(COALESCE(m->>'content', '')) NOT LIKE '(no reply)%') AS ai_replied,
           EXISTS (SELECT 1 FROM jsonb_array_elements(s.messages) m
                    WHERE m->>'role' = 'assistant'
                      AND ((jsonb_typeof(m->'tools') = 'array' AND m->'tools' @> '["add_to_cart"]'::jsonb)
                           OR COALESCE(m->>'content', '') ~ '\[tools: [^]]*add_to_cart')) AS added_to_cart
      FROM shop_chat_sessions s
     WHERE s.namespace_id = ? AND jsonb_typeof(s.messages) = 'array' AND ]==] .. in_window("s.created_at")

function Q.chat(ns_id, from, to_excl)
    local r = db.query([[
        WITH f AS (]] .. CHAT_FACTS .. [[), s AS (SELECT * FROM f WHERE user_msgs > 0)
        SELECT COUNT(*)::int AS chats,
               COUNT(*) FILTER (WHERE ai_replied)::int AS ai_replied,
               COUNT(*) FILTER (WHERE consent_at IS NOT NULL)::int AS contact_saved,
               COUNT(*) FILTER (WHERE quote_id IS NOT NULL)::int AS quotes,
               COUNT(*) FILTER (WHERE added_to_cart)::int AS added_to_cart,
               COUNT(*) FILTER (WHERE order_id IS NOT NULL)::int AS orders,
               COUNT(*) FILTER (WHERE ai_replied AND (consent_at IS NOT NULL OR quote_id IS NOT NULL
                                                    OR added_to_cart OR order_id IS NOT NULL))::int AS completed,
               COUNT(*) FILTER (WHERE is_member)::int AS member_chats,
               COALESCE(SUM(user_msgs), 0)::bigint AS user_messages,
               COALESCE((SELECT SUM(o.total_minor) FROM shop_orders o
                          WHERE o.id IN (SELECT order_id FROM s WHERE order_id IS NOT NULL)
                            AND o.paid_at IS NOT NULL AND o.status IN ]] .. PAID_OR_REFUNDED .. [[), 0)::bigint AS revenue_minor
          FROM s
    ]], ns_id, from, to_excl)[1] or {}
    local out = {
        chats = n(r.chats), ai_replied = n(r.ai_replied), contact_saved = n(r.contact_saved),
        quotes = n(r.quotes), added_to_cart = n(r.added_to_cart), orders = n(r.orders),
        completed = n(r.completed), member_chats = n(r.member_chats), user_messages = n(r.user_messages),
        revenue_minor = n(r.revenue_minor),
    }
    out.no_reply = math.max(out.chats - out.ai_replied, 0)
    out.reply_rate = A.ratio(out.ai_replied, out.chats)
    out.completion_rate = A.ratio(out.completed, out.chats)
    out.order_rate = A.ratio(out.orders, out.chats)
    out.avg_user_messages = A.ratio(out.user_messages, out.chats)
    return out
end

--- Which advisor tools ran, in how many chats. Structured `tools` arrays win;
-- older transcripts only carry the "[tools: …]" suffix in the reply text.
function Q.chat_tools(ns_id, from, to_excl, limit)
    local rows = db.query([==[
        SELECT t.name, COUNT(DISTINCT s.id)::int AS chats, COUNT(*)::int AS uses
          FROM shop_chat_sessions s
          CROSS JOIN LATERAL jsonb_array_elements(s.messages) m
          CROSS JOIN LATERAL (
              SELECT jsonb_array_elements_text(m->'tools') AS name WHERE jsonb_typeof(m->'tools') = 'array'
              UNION ALL
              SELECT btrim(x) FROM regexp_split_to_table(
                  (regexp_match(COALESCE(m->>'content', ''), '\[tools: ([^]]+)\]\s*$'))[1], ',') AS x
               WHERE jsonb_typeof(m->'tools') IS DISTINCT FROM 'array'
          ) t
         WHERE s.namespace_id = ? AND jsonb_typeof(s.messages) = 'array' AND ]==] .. in_window("s.created_at") .. [[
           AND m->>'role' = 'assistant' AND t.name <> ''
         GROUP BY t.name ORDER BY uses DESC, t.name LIMIT ?
    ]], ns_id, from, to_excl, limit or 20)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = { name = r.name, chats = n(r.chats), uses = n(r.uses) } end
    return out
end

function Q.chat_countries(ns_id, from, to_excl, limit)
    local rows = db.query([[
        SELECT COALESCE(country, '') AS country, COUNT(*)::int AS chats
          FROM shop_chat_sessions s
         WHERE s.namespace_id = ? AND ]] .. in_window("s.created_at") .. [[
           AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.messages) = 'array'
                                                               THEN s.messages ELSE '[]'::jsonb END) m
                        WHERE m->>'role' = 'user')
         GROUP BY 1 ORDER BY chats DESC, country LIMIT ?
    ]], ns_id, from, to_excl, limit or 10)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { country = r.country ~= "" and r.country or nil, chats = n(r.chats) }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Trade membership (only when shop-membership is deployed: SHOP + BILLING)
-- ---------------------------------------------------------------------------
function Q.trade(ns_id, from, to_excl)
    if not schema().memberships then return nil end
    local r = db.query([[
        SELECT COUNT(*) FILTER (WHERE ]] .. in_window("joined_at", true) .. [[)::int AS joins,
               COUNT(*) FILTER (WHERE ]] .. in_window("canceled_at", true) .. [[)::int AS cancellations,
               COUNT(*) FILTER (WHERE status IN ('active', 'past_due'))::int AS active_now
          FROM shop_memberships WHERE namespace_id = ?
    ]], from, to_excl, from, to_excl, ns_id)[1] or {}
    return { joins = n(r.joins), cancellations = n(r.cancellations), active_now = n(r.active_now) }
end

-- ---------------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------------
function Q.top_products(ns_id, from, to_excl, limit)
    local rows = db.query([[
        SELECT l->>'product_uuid' AS product_uuid, MAX(l->>'product_name') AS name, MAX(l->>'sku') AS sku,
               COALESCE(SUM((l->>'qty')::numeric), 0)::bigint AS units,
               COALESCE(SUM((l->>'line_subtotal_minor')::numeric), 0)::bigint AS revenue_ex_vat_minor,
               COALESCE(SUM((l->>'line_total_minor')::numeric), 0)::bigint AS revenue_minor,
               COUNT(DISTINCT o.id)::int AS orders
          FROM shop_orders o
          CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(o.lines) = 'array'
                                                       THEN o.lines ELSE '[]'::jsonb END) l
         WHERE o.namespace_id = ? AND o.status IN ]] .. PAID .. [[ AND ]] .. in_window("o.paid_at") .. [[
         GROUP BY 1 ORDER BY revenue_ex_vat_minor DESC, units DESC LIMIT ?
    ]], ns_id, from, to_excl, limit or 10)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            product_uuid = r.product_uuid, name = r.name, sku = r.sku, units = n(r.units),
            revenue_ex_vat_minor = n(r.revenue_ex_vat_minor), revenue_minor = n(r.revenue_minor), orders = n(r.orders),
        }
    end
    return out
end

--- Most added to basket (shop_cart_events; kept for 30 days only).
function Q.basket_adds(ns_id, from, to_excl, limit)
    local rows = db.query([[
        SELECT p.uuid AS product_uuid, p.name, p.sku, COUNT(*)::int AS adds,
               COALESCE(SUM(e.qty), 0)::bigint AS units, COUNT(DISTINCT e.cart_id)::int AS carts
          FROM shop_cart_events e JOIN shop_products p ON p.id = e.product_id AND p.namespace_id = e.namespace_id
         WHERE e.namespace_id = ? AND ]] .. in_window("e.created_at", true) .. [[
         GROUP BY p.uuid, p.name, p.sku ORDER BY adds DESC, units DESC LIMIT ?
    ]], ns_id, from, to_excl, limit or 10)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { product_uuid = r.product_uuid, name = r.name, sku = r.sku, adds = n(r.adds),
            units = n(r.units), carts = n(r.carts) }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Time series (one row per bucket, gaps filled with zeros)
-- ---------------------------------------------------------------------------
function Q.series(ns_id, w)
    local b = w.bucket
    local f, t = w.from, w.to_exclusive
    local rows = db.query([[
        WITH buckets AS (
            SELECT generate_series(date_trunc(']] .. b .. [[', ?::date), ?::date, interval '1 ]] .. b .. [[')::date AS bucket
        ),
        paid AS (
            SELECT ]] .. bucket_of("paid_at", b) .. [[ AS bucket, COUNT(*)::int AS orders,
                   COALESCE(SUM(total_minor), 0)::bigint AS revenue_minor,
                   COALESCE(SUM(total_minor - vat_minor), 0)::bigint AS revenue_ex_vat_minor
              FROM shop_orders WHERE namespace_id = ? AND status IN ]] .. PAID_OR_REFUNDED .. [[
               AND ]] .. in_window("paid_at") .. [[ GROUP BY 1
        ),
        co AS (
            SELECT ]] .. bucket_of("created_at", b) .. [[ AS bucket, COUNT(DISTINCT ]] .. ATTEMPT_KEY .. [[)::int AS checkouts
              FROM shop_orders WHERE namespace_id = ? AND ]] .. in_window("created_at") .. [[ GROUP BY 1
        ),
        carts AS (
            SELECT ]] .. bucket_of("created_at", b) .. [[ AS bucket, COUNT(*)::int AS carts
              FROM shop_carts WHERE namespace_id = ? AND ]] .. in_window("created_at") .. [[ GROUP BY 1
        ),
        chats AS (
            SELECT ]] .. bucket_of("created_at", b) .. [[ AS bucket, COUNT(*)::int AS chats
              FROM shop_chat_sessions s WHERE namespace_id = ? AND jsonb_typeof(messages) = 'array'
               AND ]] .. in_window("created_at") .. [[
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(s.messages) m WHERE m->>'role' = 'user')
             GROUP BY 1
        ),
        quotes AS (
            SELECT ]] .. bucket_of("created_at", b) .. [[ AS bucket, COUNT(*)::int AS quotes
              FROM shop_quotes WHERE namespace_id = ? AND ]] .. in_window("created_at") .. [[ GROUP BY 1
        )
        SELECT to_char(k.bucket, 'YYYY-MM-DD') AS bucket,
               COALESCE(p.orders, 0) AS orders, COALESCE(p.revenue_minor, 0) AS revenue_minor,
               COALESCE(p.revenue_ex_vat_minor, 0) AS revenue_ex_vat_minor,
               COALESCE(co.checkouts, 0) AS checkouts, COALESCE(c.carts, 0) AS carts,
               COALESCE(ch.chats, 0) AS chats, COALESCE(q.quotes, 0) AS quotes
          FROM buckets k
          LEFT JOIN paid p ON p.bucket = k.bucket
          LEFT JOIN co ON co.bucket = k.bucket
          LEFT JOIN carts c ON c.bucket = k.bucket
          LEFT JOIN chats ch ON ch.bucket = k.bucket
          LEFT JOIN quotes q ON q.bucket = k.bucket
         ORDER BY k.bucket
    ]], f, w.to, ns_id, f, t, ns_id, f, t, ns_id, f, t, ns_id, f, t, ns_id, f, t)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            bucket = r.bucket, orders = n(r.orders), revenue_minor = n(r.revenue_minor),
            revenue_ex_vat_minor = n(r.revenue_ex_vat_minor), checkouts = n(r.checkouts), carts = n(r.carts),
            chats = n(r.chats), quotes = n(r.quotes),
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The whole report
-- ---------------------------------------------------------------------------
local function period(ns_id, from, to_excl)
    return {
        sales = Q.sales(ns_id, from, to_excl),
        checkout = Q.checkout(ns_id, from, to_excl),
        carts = Q.carts(ns_id, from, to_excl),
        quotes = Q.quotes(ns_id, from, to_excl),
        chat = Q.chat(ns_id, from, to_excl),
        trade = Q.trade(ns_id, from, to_excl),
    }
end

--- Headline changes vs the previous period, for the KPI cards.
function Q.changes(cur, prev)
    local c = A.change
    return {
        revenue_minor = c(cur.sales.revenue_minor, prev.sales.revenue_minor),
        net_revenue_minor = c(cur.sales.net_revenue_minor, prev.sales.net_revenue_minor),
        orders = c(cur.sales.orders, prev.sales.orders),
        aov_minor = c(cur.sales.aov_minor, prev.sales.aov_minor),
        customers = c(cur.sales.customers, prev.sales.customers),
        checkouts = c(cur.checkout.started, prev.checkout.started),
        carts = c(cur.carts.created, prev.carts.created),
        abandoned = c(cur.carts.abandoned, prev.carts.abandoned),
        quotes = c(cur.quotes.created, prev.quotes.created),
        chats = c(cur.chat.chats, prev.chat.chats),
        chat_completed = c(cur.chat.completed, prev.chat.completed),
    }
end

--- params: { from?, to?, days?, bucket?, compare? ("false" to skip the previous period) }
-- Returns report or nil, error message (a 400).
function Q.report(ns_id, params)
    params = params or {}
    local w, err = A.window(params, Q.today())
    if not w then return nil, err end
    local cur = period(ns_id, w.from, w.to_exclusive)
    local out = {
        window = w,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        currency = "GBP",
        sales = cur.sales, checkout = cur.checkout, carts = cur.carts, quotes = cur.quotes,
        chat = cur.chat, trade = cur.trade,
        series = Q.series(ns_id, w),
        top_products = Q.top_products(ns_id, w.from, w.to_exclusive, 10),
        basket_adds = Q.basket_adds(ns_id, w.from, w.to_exclusive, 10),
        -- Add-to-basket events older than the retention window are gone, so a
        -- longer window only covers its last 30 days.
        basket_adds_complete = w.days <= A.CART_EVENT_RETENTION_DAYS and w.includes_today,
        chat_tools = Q.chat_tools(ns_id, w.from, w.to_exclusive, 20),
        chat_countries = Q.chat_countries(ns_id, w.from, w.to_exclusive, 10),
        -- Visitor analytics (unique/returning visitors, page views, traffic
        -- sources) need a privacy/cookie decision first. Nothing is collected.
        visitor_tracking = { enabled = false, status = "awaiting_privacy_signoff" },
    }
    if params.compare ~= "false" then
        local prev = period(ns_id, w.previous.from, w.previous.to_exclusive)
        out.previous = prev
        out.changes = Q.changes(cur, prev)
    end
    return out
end

-- ---------------------------------------------------------------------------
-- CSV exports (helper/report-csv.lua envelopes)
-- ---------------------------------------------------------------------------
local EXPORTS = {
    daily = {
        title = "Shop analytics by period",
        columns = {
            { key = "bucket", label = "Period start", type = "date" },
            { key = "orders", label = "Paid orders", type = "number" },
            { key = "revenue", label = "Revenue inc VAT (GBP)", type = "money" },
            { key = "revenue_ex_vat", label = "Revenue ex VAT (GBP)", type = "money" },
            { key = "checkouts", label = "Checkouts started", type = "number" },
            { key = "carts", label = "Carts created", type = "number" },
            { key = "chats", label = "AI chats", type = "number" },
            { key = "quotes", label = "Quotes", type = "number" },
        },
        rows = function(ns_id, w)
            local rows = {}
            for _, r in ipairs(Q.series(ns_id, w)) do
                rows[#rows + 1] = {
                    bucket = r.bucket, orders = r.orders, checkouts = r.checkouts, carts = r.carts,
                    chats = r.chats, quotes = r.quotes,
                    revenue = string.format("%.2f", r.revenue_minor / 100),
                    revenue_ex_vat = string.format("%.2f", r.revenue_ex_vat_minor / 100),
                }
            end
            return rows
        end,
    },
    products = {
        title = "Top products by revenue",
        columns = {
            { key = "name", label = "Product", type = "text" },
            { key = "sku", label = "SKU", type = "text" },
            { key = "units", label = "Units sold", type = "number" },
            { key = "orders", label = "Orders", type = "number" },
            { key = "revenue_ex_vat", label = "Revenue ex VAT (GBP)", type = "money" },
            { key = "revenue", label = "Revenue inc VAT (GBP)", type = "money" },
        },
        rows = function(ns_id, w)
            local rows = {}
            for _, r in ipairs(Q.top_products(ns_id, w.from, w.to_exclusive, 500)) do
                rows[#rows + 1] = {
                    name = r.name, sku = r.sku, units = r.units, orders = r.orders,
                    revenue_ex_vat = string.format("%.2f", r.revenue_ex_vat_minor / 100),
                    revenue = string.format("%.2f", r.revenue_minor / 100),
                }
            end
            return rows
        end,
    },
    chat_tools = {
        title = "AI advisor tool use",
        columns = {
            { key = "name", label = "Tool", type = "text" },
            { key = "chats", label = "Chats", type = "number" },
            { key = "uses", label = "Replies using it", type = "number" },
        },
        rows = function(ns_id, w) return Q.chat_tools(ns_id, w.from, w.to_exclusive, 100) end,
    },
    survey = {
        title = "Survey funnel and drop-off",
        columns = function() return require("queries.ShopSurveyQueries").EXPORT_COLUMNS end,
        rows = function(ns_id, w, params)
            local survey = require("lib.shop-survey").survey_param(params.survey)
            if not survey then return nil, "survey must be a lower-case slug" end
            return require("queries.ShopSurveyQueries").export_rows(ns_id, w, survey)
        end,
    },
}
Q.EXPORT_KEYS = { "daily", "products", "chat_tools", "survey" }

--- Returns a report envelope for ReportCsv.render, or nil, status, message.
function Q.export(ns_id, key, params)
    local spec = EXPORTS[key or ""]
    if not spec then return nil, 404, "Unknown export (use one of: " .. table.concat(Q.EXPORT_KEYS, ", ") .. ")" end
    local w, err = A.window(params or {}, Q.today())
    if not w then return nil, 400, err end
    local rows, rows_err = spec.rows(ns_id, w, params or {})
    if not rows then return nil, 400, rows_err end
    local columns = type(spec.columns) == "function" and spec.columns() or spec.columns
    return {
        key = "shop-" .. key:gsub("_", "-") .. "-" .. w.from .. "-to-" .. w.to,
        title = spec.title, columns = columns, rows = rows, row_count = #rows,
        filters = { from = w.from, to = w.to, bucket = w.bucket },
    }
end

return Q
