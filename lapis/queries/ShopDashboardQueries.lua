-- luacheck: max line length 140
--[[
    Shop back-office KPIs (GET /api/v2/shop/admin/dashboard)
]]

local db = require("lapis.db")
local U = require("lib.shop-util")
local Stock = require("queries.ShopStockQueries")
local Orders = require("queries.ShopOrderQueries")
local Quote = require("queries.ShopQuoteQueries")

local ShopDashboardQueries = {}

local PAID = "('paid','processing','shipped','delivered')"

function ShopDashboardQueries.kpis(ns_id)
    local o = db.query([[
        SELECT COUNT(*) FILTER (WHERE created_at >= date_trunc('day', NOW()))::int AS orders_today,
               COUNT(*) FILTER (WHERE created_at >= NOW() - interval '7 days')::int AS orders_7d,
               COUNT(*) FILTER (WHERE created_at >= NOW() - interval '30 days')::int AS orders_30d,
               COUNT(*) FILTER (WHERE status IN ]] .. PAID .. [[ AND paid_at >= NOW() - interval '30 days')::int
                   AS paid_orders_30d,
               COALESCE(SUM(total_minor) FILTER (WHERE status IN ]] .. PAID .. [[
                   AND paid_at >= NOW() - interval '30 days'), 0)::bigint AS revenue_paid_30d_minor,
               COALESCE(SUM(subtotal_minor) FILTER (WHERE status IN ]] .. PAID .. [[
                   AND paid_at >= NOW() - interval '30 days'), 0)::bigint AS revenue_paid_30d_ex_vat_minor,
               COUNT(*) FILTER (WHERE status = 'pending_payment')::int AS pending_payment,
               COUNT(*) FILTER (WHERE status = 'paid')::int AS awaiting_fulfilment
          FROM shop_orders WHERE namespace_id = ?
    ]], ns_id)[1]
    local q = db.query([[
        SELECT COUNT(*) FILTER (WHERE status IN ('draft','sent','accepted') AND valid_until > NOW())::int AS open_quotes,
               COALESCE(SUM(total_minor) FILTER (WHERE status IN ('draft','sent','accepted') AND valid_until > NOW()), 0)::bigint
                   AS open_quotes_value_minor,
               COUNT(*) FILTER (WHERE created_at >= NOW() - interval '30 days')::int AS quotes_30d,
               COUNT(*) FILTER (WHERE created_at >= NOW() - interval '30 days' AND status = 'converted')::int
                   AS quotes_converted_30d
          FROM shop_quotes WHERE namespace_id = ?
    ]], ns_id)[1]
    local c = db.query([[
        SELECT COUNT(*) FILTER (WHERE created_at >= NOW() - interval '7 days' AND message_count > 0)::int AS chats_7d
          FROM shop_chat_sessions WHERE namespace_id = ?
    ]], ns_id)[1]
    local p = db.query([[
        SELECT COUNT(*) FILTER (WHERE status = 'active')::int AS active_products,
               COUNT(*) FILTER (WHERE status = 'active' AND NOT price_verified)::int AS unverified_prices
          FROM shop_products WHERE namespace_id = ?
    ]], ns_id)[1]
    local quotes_30d = tonumber(q.quotes_30d) or 0
    local conv = quotes_30d > 0 and (tonumber(q.quotes_converted_30d) / quotes_30d) or 0
    local low = Stock.sheet(ns_id, { low_only = true })
    return {
        orders_today = o.orders_today,
        orders_7d = o.orders_7d,
        orders_30d = o.orders_30d,
        paid_orders_30d = o.paid_orders_30d,
        revenue_paid_30d_minor = tonumber(o.revenue_paid_30d_minor),
        revenue_paid_30d_ex_vat_minor = tonumber(o.revenue_paid_30d_ex_vat_minor),
        pending_payment = o.pending_payment,
        awaiting_fulfilment = o.awaiting_fulfilment,
        open_quotes = q.open_quotes,
        open_quotes_value_minor = tonumber(q.open_quotes_value_minor),
        quotes_30d = quotes_30d,
        quotes_converted_30d = q.quotes_converted_30d,
        quote_conversion_rate = math.floor(conv * 10000 + 0.5) / 10000,
        quote_conversion_rate_30d = math.floor(conv * 10000 + 0.5) / 10000,
        latest_orders = (Orders.adminList(ns_id, { limit = 5 })),
        latest_quotes = (Quote.adminList(ns_id, { limit = 5 })),
        low_stock_count = #low,
        low_stock = low,
        chats_7d = c.chats_7d,
        active_products = p.active_products,
        unverified_prices = p.unverified_prices,
        currency = "GBP",
        payments_enabled = U.env("STRIPE_SECRET_KEY") ~= nil,
        webhook_configured = U.env("STRIPE_SHOP_WEBHOOK_SECRET") ~= nil,
    }
end

return ShopDashboardQueries
