-- luacheck: max line length 140
--[[
    Delivery change requests (shop_delivery_change_requests)
    ========================================================
    A signed-in customer asks to change where and when their order is delivered; staff approve or
    decline it in the dashboard. Nothing on the order changes until staff approve. Rules (validation,
    dates, postcodes) live in lib/shop-delivery-change.lua.

    Customer (public shop API, X-Member-Token; the signed-in email must be the order's email):
      forCustomer(ns_id, order_uuid, email, token)          the order's requests + what may be asked
      createForCustomer(ns_id, order_uuid, email, token, body, meta)
      cancelForCustomer(ns_id, order_uuid, request_uuid, email, token)
      ordersForCustomer(ns_id, email, params)               the customer's orders (account page)
    Staff (shop admin API):
      forOrder(order_id, { admin = true })                  on adminGet
      adminList(ns_id, order_uuid)
      approve(ns_id, order_uuid, request_uuid, body, actor) applies the address / date / window to the order
      decline(ns_id, order_uuid, request_uuid, body, actor) body.staff_note = the reason (shown to the customer)

    Every new request alerts staff (Shop settings → order alert email + Telegram, as the new-order alert)
    and adds a line to the order's internal notes. Customers are only emailed about a decision while
    Shop settings → customer_delivery_notifications is on (off by default).
]]

local db = require("lapis.db")
local Global = require("helper.global")
local U = require("lib.shop-util")
local R = require("lib.shop-delivery-change")
local Orders = require("queries.ShopOrderQueries")

local Q = {}

local COLS = [[
    r.id, r.uuid, r.namespace_id, r.order_id, r.status, r.requested_address::text AS requested_address,
    r.requested_date::text AS requested_date, r.requested_window, r.customer_note, r.requested_by_email,
    r.previous_delivery_address::text AS previous_delivery_address, r.previous_delivery_date::text AS previous_delivery_date,
    r.previous_delivery_window, r.staff_note, r.decided_by, r.decided_at, r.cancelled_at, r.customer_notified_at,
    r.created_at, r.updated_at
]]

local CUSTOMER_MESSAGE = "Thanks — we've received your delivery change request. We'll confirm it soon; "
    .. "watch out for our email or SMS."

local function nn(v) return U.nz(v) or U.null end

function Q.shape(r, opts)
    opts = opts or {}
    local out = {
        uuid = r.uuid,
        status = r.status,
        requested_address = U.dec(r.requested_address, {}),
        requested_date = nn(r.requested_date),
        requested_window = nn(r.requested_window),
        customer_note = nn(r.customer_note),
        previous_delivery_address = U.dec(r.previous_delivery_address, U.null),
        previous_delivery_date = nn(r.previous_delivery_date),
        previous_delivery_window = nn(r.previous_delivery_window),
        -- Written by staff for the customer (e.g. why it was declined).
        staff_note = nn(r.staff_note),
        decided_at = nn(r.decided_at),
        cancelled_at = nn(r.cancelled_at),
        created_at = r.created_at,
    }
    if opts.admin then
        out.requested_by_email = r.requested_by_email
        out.decided_by = nn(r.decided_by)
        out.customer_notified_at = nn(r.customer_notified_at)
        out.updated_at = r.updated_at
    end
    return out
end

function Q.forOrder(order_id, opts)
    local ok, rows = pcall(db.query, "SELECT " .. COLS .. [[ FROM shop_delivery_change_requests r
        WHERE r.order_id = ? ORDER BY r.created_at DESC, r.id DESC LIMIT 50]], order_id)
    local out = {}
    for _, r in ipairs(ok and rows or {}) do out[#out + 1] = Q.shape(r, opts) end -- empty before migration zzs51
    return U.arr(out)
end

--- The pending request of an order (customer shape), or JSON null.
function Q.pendingFor(order_id)
    local ok, rows = pcall(db.query, "SELECT " .. COLS .. [[ FROM shop_delivery_change_requests r
        WHERE r.order_id = ? AND r.status = 'pending' LIMIT 1]], order_id)
    local r = ok and rows[1] or nil
    return r and Q.shape(r) or U.null
end

-- ---------------------------------------------------------------------------
-- the order as it stands
-- ---------------------------------------------------------------------------

local function order_email(o)
    local customer = U.dec(o.customer, {})
    return U.nz(o.email) or U.nz(customer.email)
end

--- Is this signed-in email the order's customer? (case-insensitive)
function Q.ownsOrder(o, email)
    local owner = order_email(o)
    return owner ~= nil and type(email) == "string" and owner:lower() == email:lower()
end

--- Where and when the order is delivered now: the agreed delivery address, else the customer's
-- shipping address (only the keys a request can change), plus the agreed date and window.
local function current_delivery(o)
    local ship = Orders.shipTo(o) or {}
    local a = {}
    for _, k in ipairs(R.ADDRESS_KEYS) do
        local v = ship[k]
        if type(v) == "string" and v:match("%S") then a[k] = v end
    end
    return { address = next(a) and a or nil, date = U.nz(o.delivery_date), window = U.nz(o.delivery_window) }
end

local function today_london()
    return db.query("SELECT (NOW() AT TIME ZONE 'Europe/London')::date::text AS d")[1].d
end

local function append_note(order_id, line)
    db.query([[UPDATE shop_orders SET internal_notes = COALESCE(internal_notes || E'\n', '') || ?, updated_at = NOW()
               WHERE id = ?]], line, order_id)
end

local function stamp()
    return db.query("SELECT to_char(NOW() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI') AS t")[1].t
end

local function change_summary(addr, date, window)
    local parts = { R.describe_address(addr) }
    if date then parts[#parts + 1] = "date " .. R.date_label(date) end
    if window then parts[#parts + 1] = "time " .. R.window_label(window) end
    return table.concat(parts, "; ")
end

--- The order for a signed-in customer: their email must be the order's. A token (from the order link)
-- is optional; when given it must match. Never the token alone: the caller must have resolved `email`
-- from a member session.
local function owned_order(ns_id, uuid, email, token, lock)
    if not U.nz(uuid) or #tostring(uuid) > 64 or not U.nz(email) then
        return nil, U.err(404, "ORDER_NOT_FOUND", "Order not found")
    end
    local o
    if lock then
        o = db.query("SELECT " .. Orders.ORDER_COLS .. " FROM shop_orders o WHERE o.namespace_id = ? AND o.uuid = ? FOR UPDATE",
            ns_id, uuid)[1]
    else
        o = Orders.getByUuid(ns_id, uuid)
    end
    if not o then return nil, U.err(404, "ORDER_NOT_FOUND", "Order not found") end
    local token_ok = U.nz(token) and U.secure_equals(o.access_token, token)
    if U.nz(token) and not token_ok then return nil, U.err(404, "ORDER_NOT_FOUND", "Order not found") end
    if not Q.ownsOrder(o, email) then
        -- With the order link we can say why; without it, don't confirm the order exists.
        if token_ok then
            return nil, U.err(403, "ORDER_EMAIL_MISMATCH",
                "You're signed in with a different email address from the one on this order. "
                .. "Sign in with the order's email to request a delivery change.")
        end
        return nil, U.err(404, "ORDER_NOT_FOUND", "Order not found")
    end
    return o
end

local function recent_count(order_id)
    return tonumber(db.query([[SELECT COUNT(*)::int AS n FROM shop_delivery_change_requests
        WHERE order_id = ? AND created_at > NOW() - INTERVAL '24 hours']], order_id)[1].n) or 0
end

--- What the customer may do now: (can_request, reason_code|nil)
local function eligibility(o, has_pending)
    if not R.order_open(o.status) then return false, "ORDER_NOT_CHANGEABLE" end
    if has_pending then return false, "DELIVERY_CHANGE_PENDING" end
    if recent_count(o.id) >= R.MAX_PER_DAY then return false, "RATE_LIMITED" end
    return true, nil
end

local function customer_view(o)
    local requests = Q.forOrder(o.id)
    local pending = false
    for _, r in ipairs(requests) do
        if r.status == "pending" then pending = true end
    end
    local can, reason = eligibility(o, pending)
    local earliest, latest = R.date_range(today_london())
    local cur = current_delivery(o)
    local windows = {}
    for _, w in ipairs(R.WINDOW_ORDER) do windows[#windows + 1] = w end
    return {
        order = { uuid = o.uuid, order_number = o.order_number, status = o.status },
        current = { address = cur.address or U.null, date = cur.date or U.null, window = cur.window or U.null },
        requests = requests,
        can_request = can,
        blocked_reason = reason or U.null,
        earliest_date = earliest,
        latest_date = latest,
        windows = U.arr(windows),
    }
end

function Q.forCustomer(ns_id, order_uuid, email, token)
    local o, err = owned_order(ns_id, order_uuid, email, token)
    if not o then return nil, err end
    return customer_view(o)
end

-- ---------------------------------------------------------------------------
-- staff alert for a new request
-- ---------------------------------------------------------------------------

local function staff_alert(o, req, cur)
    local ok, err = pcall(function()
        local ns = db.query("SELECT id, name FROM namespaces WHERE id = ?", o.namespace_id)[1]
        if not ns then return end
        local customer = U.dec(o.customer, {})
        local name = U.nz(customer.name) or U.nz(req.address.name) or U.nz(o.email) or "Customer"
        local first, last = tostring(name):match("^(%S+)%s*(.*)$")
        local base = (U.env("FRONTEND_URL") or ""):gsub("/+$", "")
        local notes = U.join("\n",
            "Order " .. o.order_number .. " (" .. o.status .. "): the customer has asked to change the delivery.",
            "Nothing changes on the order until you approve it.",
            "Requested by: " .. req.email,
            "",
            "Delivery address",
            "  Now: " .. R.describe_address(cur.address),
            "  Requested: " .. R.describe_address(req.address),
            "Delivery date",
            "  Now: " .. R.date_label(cur.date),
            "  Requested: " .. (req.date and R.date_label(req.date) or "no change"),
            "Time",
            "  Now: " .. R.window_label(cur.window),
            "  Requested: " .. (req.window and R.window_label(req.window) or "no change"),
            req.note and ("\nCustomer note:\n" .. req.note) or nil,
            base ~= "" and ("\nApprove or decline it: " .. base .. "/dashboard/shop/orders/" .. o.uuid) or nil)
        require("queries.CrmLeadNotificationQueries").notify(ns, {
            first_name = first or name, last_name = last ~= "" and last or nil,
            email = req.email, phone = U.nz(customer.phone) or req.address.phone,
            company_name = U.nz(customer.company) or req.address.company, source = "shop_delivery_change", notes = notes,
        }, {
            to = require("queries.ShopSettingsQueries").orderAlertEmail(o.namespace_id),
            purpose = "shop_alerts",
            staff = {
                subject = "Delivery change request: " .. o.order_number .. " (" .. tostring(name) .. ")",
                headline = "Delivery change requested",
                intro = "The customer on order " .. o.order_number .. " has asked to change where or when it is "
                    .. "delivered. Approve or decline it on the order in Shop → Orders. The customer has not been "
                    .. "emailed; their order page shows the request as pending confirmation.",
                telegram_title = "🚚 <b>Delivery change requested</b> " .. o.order_number,
            },
        })
    end)
    if not ok then
        ngx.log(ngx.WARN, "[shop-delivery-change] staff alert for order ", tostring(o.id), " failed: ", tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- customer actions
-- ---------------------------------------------------------------------------

--- Salted hash so a request can be tied to a visitor without keeping their IP or browser.
local function hash(v)
    if not U.nz(v) then return nil end
    local salt = U.env("SHOP_BFF_KEY") or U.env("JWT_SECRET_KEY") or ""
    return U.sha256_hex(salt .. "|delivery-change|" .. tostring(v))
end

--- body: { address, date?, window?, note? }; meta: { ip?, user_agent? }
function Q.createForCustomer(ns_id, order_uuid, email, token, body, meta)
    meta = meta or {}
    local today = today_london()
    local req, verr = R.validate(body, today)
    if not req then
        return nil, U.err(400, "VALIDATION_ERROR", verr.message, { field = verr.field })
    end
    req.email = tostring(email):lower()
    local order, cur
    local created, err = U.tx(function()
        local o, oerr = owned_order(ns_id, order_uuid, email, token, true) -- locks the order: one request at a time
        if not o then return nil, oerr end
        if not R.order_open(o.status) then
            local dispatched = o.status == "shipped" or o.status == "delivered"
            return nil, U.err(409, "ORDER_NOT_CHANGEABLE", dispatched
                and "This order has already been dispatched, so the delivery can't be changed online. Please contact us."
                or "The delivery of this order can't be changed online. Please contact us.")
        end
        local pending = db.query([[SELECT 1 FROM shop_delivery_change_requests WHERE order_id = ? AND status = 'pending']],
            o.id)[1]
        if pending then
            return nil, U.err(409, "DELIVERY_CHANGE_PENDING",
                "You already have a delivery change request waiting for confirmation. Cancel it to send a new one.")
        end
        if recent_count(o.id) >= R.MAX_PER_DAY then
            return nil, U.err(429, "RATE_LIMITED", "You've sent several requests for this order today. "
                .. "Please try again tomorrow or contact us.")
        end
        cur = current_delivery(o)
        if not R.changes_anything(req, cur) then
            return nil, U.err(400, "NO_CHANGE", "That's the delivery we already have. Change the address, date or time "
                .. "to send a request.")
        end
        local uuid = Global.generateUUID()
        db.query([[
            INSERT INTO shop_delivery_change_requests
                (uuid, namespace_id, order_id, status, requested_address, requested_date, requested_window, customer_note,
                 requested_by_email, requester_ip_hash, requester_ua_hash, previous_delivery_address,
                 previous_delivery_date, previous_delivery_window, created_at, updated_at)
            VALUES (?, ?, ?, 'pending', ?::jsonb, ?::date, ?, ?, ?, ?, ?, ?::jsonb, ?::date, ?, NOW(), NOW())
        ]], uuid, ns_id, o.id, U.enc(req.address), req.date or db.NULL, req.window or db.NULL, req.note or db.NULL,
            req.email, hash(meta.ip) or db.NULL, hash(meta.user_agent) or db.NULL,
            cur.address and U.enc(cur.address) or db.NULL, cur.date or db.NULL, cur.window or db.NULL)
        append_note(o.id, stamp() .. " Delivery change requested by " .. req.email .. " (pending): "
            .. change_summary(req.address, req.date, req.window) .. (req.note and (". Note: " .. req.note:gsub("\n", " ")) or ""))
        order = o
        return uuid
    end)
    if not created then return nil, err end
    staff_alert(order, req, cur)
    local view = customer_view(Orders.getByUuid(ns_id, order_uuid))
    for _, r in ipairs(view.requests) do
        if r.uuid == created then view.request = r end
    end
    view.message = CUSTOMER_MESSAGE
    return view
end

function Q.cancelForCustomer(ns_id, order_uuid, request_uuid, email, token)
    local _, err = U.tx(function()
        local o, oerr = owned_order(ns_id, order_uuid, email, token, true)
        if not o then return nil, oerr end
        local r = db.query([[SELECT id, status FROM shop_delivery_change_requests WHERE order_id = ? AND uuid = ? FOR UPDATE]],
            o.id, tostring(request_uuid or ""))[1]
        if not r then return nil, U.err(404, "NOT_FOUND", "Request not found") end
        if r.status == "cancelled" then return true end -- already done
        if r.status ~= "pending" then
            return nil, U.err(409, "DELIVERY_CHANGE_CLOSED", "This request has already been " .. r.status .. ".")
        end
        db.query([[UPDATE shop_delivery_change_requests SET status = 'cancelled', cancelled_at = NOW(), updated_at = NOW()
                   WHERE id = ?]], r.id)
        append_note(o.id, stamp() .. " Delivery change request cancelled by the customer (" .. tostring(email):lower() .. ").")
        return true
    end)
    if err then return nil, err end
    return customer_view(Orders.getByUuid(ns_id, order_uuid))
end

--- The signed-in customer's orders, newest first (abandoned card checkouts and failed payments left out).
function Q.ordersForCustomer(ns_id, email, params)
    params = params or {}
    if not U.nz(email) then return U.arr({}), { total = 0, limit = 0, offset = 0 } end
    local limit = U.clamp(U.int(params.limit, 50), 1, 100)
    local offset = math.max(0, U.int(params.offset, 0))
    local rows = db.query([[
        SELECT o.uuid, o.order_number, o.access_token, o.status, o.total_minor, o.currency, o.created_at, o.paid_at,
               o.payment_method, jsonb_array_length(COALESCE(o.lines, '[]'::jsonb)) AS line_count,
               EXISTS (SELECT 1 FROM shop_delivery_change_requests dcr
                        WHERE dcr.order_id = o.id AND dcr.status = 'pending') AS delivery_change_pending,
               COUNT(*) OVER() AS total
          FROM shop_orders o
         WHERE o.namespace_id = ? AND lower(COALESCE(o.email, o.customer->>'email')) = lower(?)
           AND o.status <> 'payment_failed'
           AND NOT (o.status IN ('pending_payment', 'cancelled') AND COALESCE(o.payment_method, 'card') = 'card'
                    AND o.paid_at IS NULL)
         ORDER BY o.created_at DESC, o.id DESC LIMIT ? OFFSET ?]], ns_id, email, limit, offset)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            uuid = r.uuid, order_number = r.order_number, status = r.status,
            total_minor = tonumber(r.total_minor) or 0, currency = r.currency, created_at = r.created_at,
            paid_at = nn(r.paid_at), line_count = tonumber(r.line_count) or 0,
            url_path = "/orders/" .. r.uuid .. "?t=" .. r.access_token,
            delivery_change_pending = r.delivery_change_pending == true,
            can_change_delivery = R.order_open(r.status),
        }
    end
    local total = rows[1] and tonumber(rows[1].total) or 0
    return U.arr(out), { total = total, limit = limit, offset = offset }
end

-- ---------------------------------------------------------------------------
-- staff decisions
-- ---------------------------------------------------------------------------

function Q.adminList(ns_id, order_uuid)
    local o = Orders.getByUuid(ns_id, order_uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    return Q.forOrder(o.id, { admin = true })
end

local function esc(s)
    return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;",
                                                 ["'"] = "&#39;" }))
end

--- Email the customer the decision, only while Shop settings → customer_delivery_notifications is on.
-- Returns true when an email was queued.
local function notify_customer(o, r, decision)
    local Settings = require("queries.ShopSettingsQueries")
    if not Settings.customerDeliveryNotifications(o.namespace_id) then return false end
    local ok, sent = pcall(function()
        local to = U.nz(r.requested_by_email) or order_email(o)
        if not to then return false end
        local Mail = require("helper.mail")
        local NamespaceMail = require("helper.namespace-mail")
        local smtp = NamespaceMail.smtp(o.namespace_id, "shop_orders")
        if smtp and not NamespaceMail.hostOk(smtp.host) then smtp = nil end
        if not smtp and not Mail.isConfigured() then return false end
        local addr = U.dec(r.requested_address, {})
        local approved = decision == "approved"
        local rows = {
            "<p><strong>Order " .. esc(o.order_number) .. "</strong></p>",
            approved and ("<p>Delivery address: " .. esc(R.describe_address(addr)) .. "</p>") or nil,
            approved and U.nz(r.requested_date) and ("<p>Delivery date: " .. esc(R.date_label(r.requested_date)) .. "</p>") or nil,
            approved and U.nz(r.requested_window) and ("<p>Time: " .. esc(R.window_label(r.requested_window)) .. "</p>") or nil,
            U.nz(r.staff_note) and ("<p>" .. esc(r.staff_note):gsub("\n", "<br>") .. "</p>") or nil,
        }
        local details = {}
        for i = 1, 5 do if rows[i] then details[#details + 1] = rows[i] end end
        local base = (U.env("SHOP_PUBLIC_URL") or ""):gsub("/+$", "")
        local brand = Settings.brandName(o.namespace_id)
        local queued = Mail.send({
            to = to,
            subject = (approved and "Delivery change confirmed: order " or "Delivery change not possible: order ") .. o.order_number,
            template = "notification",
            smtp = smtp,
            from_email = smtp and smtp.from_email or nil,
            from_name = smtp and smtp.from_name or brand,
            reply_to = smtp and smtp.reply_to or nil,
            data = {
                app_name = brand,
                title = approved and "Your delivery change is confirmed" or "We couldn't make your delivery change",
                message = approved and "We've updated the delivery for your order as you asked."
                    or "Sorry, we weren't able to change the delivery for your order as requested. Your original delivery "
                    .. "details still apply. Please contact us if you'd like to discuss it.",
                details = table.concat(details, ""),
                action_url = base ~= "" and (base .. "/orders/" .. o.uuid .. "?t=" .. o.access_token) or nil,
                action_label = "View your order",
            },
        })
        -- TODO(sms): OpsAPI has no SMS sender yet. When one is added, text the customer here too (same switch).
        return queued == true
    end)
    if not ok then
        ngx.log(ngx.WARN, "[shop-delivery-change] customer email for order ", tostring(o.id), " failed: ", tostring(sent))
        return false
    end
    if sent then
        db.query("UPDATE shop_delivery_change_requests SET customer_notified_at = NOW() WHERE id = ?", r.id)
    end
    return sent == true
end

local function decide(ns_id, order_uuid, request_uuid, body, actor, decision)
    body = body or {}
    local staff_note = R.clean_note(body.staff_note, R.NOTE_MAX)
    local who = U.nz(actor) and tostring(actor):sub(1, 254) or "staff"
    local order, row, already
    local _, err = U.tx(function()
        local o = db.query("SELECT " .. Orders.ORDER_COLS .. " FROM shop_orders o WHERE o.namespace_id = ? AND o.uuid = ? FOR UPDATE",
            ns_id, tostring(order_uuid or ""))[1]
        if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
        local r = db.query("SELECT " .. COLS .. [[ FROM shop_delivery_change_requests r
            WHERE r.order_id = ? AND r.uuid = ? FOR UPDATE]], o.id, tostring(request_uuid or ""))[1]
        if not r then return nil, U.err(404, "NOT_FOUND", "Delivery change request not found") end
        order = o
        if r.status == decision then -- clicked twice: nothing more to do
            already, row = true, r
            return true
        end
        if r.status ~= "pending" then
            return nil, U.err(409, "DELIVERY_CHANGE_CLOSED", "This request has already been " .. r.status .. ".")
        end
        if decision == "declined" and (not staff_note or #staff_note < 3) then
            return nil, U.err(400, "VALIDATION_ERROR", "Give the customer a reason for declining")
        end
        if decision == "approved" then
            if not R.order_open(o.status) then
                return nil, U.err(409, "ORDER_NOT_CHANGEABLE", "The order is " .. o.status
                    .. ", so the delivery can't be changed. Decline the request instead.")
            end
            local cur = current_delivery(o)
            -- Keep what the request doesn't cover (email, VAT number on an agreed delivery address).
            local agreed = U.nz(o.delivery_address) and U.dec(o.delivery_address, {}) or {}
            local new_addr = U.dec(r.requested_address, {})
            new_addr.email = new_addr.email or agreed.email
            new_addr.vat_number = agreed.vat_number
            local new_date = U.nz(r.requested_date) or cur.date
            local new_window = U.nz(r.requested_window) or cur.window
            db.query([[UPDATE shop_orders SET delivery_address = ?::jsonb, delivery_date = ?::date, delivery_window = ?,
                       updated_at = NOW() WHERE id = ?]], U.enc(new_addr), new_date or db.NULL, new_window or db.NULL, o.id)
            db.query([[UPDATE shop_delivery_change_requests SET status = 'approved', staff_note = ?, decided_by = ?,
                       decided_at = NOW(), previous_delivery_address = ?::jsonb, previous_delivery_date = ?::date,
                       previous_delivery_window = ?, updated_at = NOW() WHERE id = ?]],
                staff_note or db.NULL, who, cur.address and U.enc(cur.address) or db.NULL, cur.date or db.NULL,
                cur.window or db.NULL, r.id)
            append_note(o.id, stamp() .. " Delivery change approved by " .. who .. ": "
                .. change_summary(new_addr, U.nz(r.requested_date), U.nz(r.requested_window))
                .. ". Was: " .. change_summary(cur.address, cur.date, cur.window))
        else
            db.query([[UPDATE shop_delivery_change_requests SET status = 'declined', staff_note = ?, decided_by = ?,
                       decided_at = NOW(), updated_at = NOW() WHERE id = ?]], staff_note, who, r.id)
            append_note(o.id, stamp() .. " Delivery change declined by " .. who .. ": " .. staff_note:gsub("\n", " "))
        end
        row = db.query("SELECT " .. COLS .. " FROM shop_delivery_change_requests r WHERE r.id = ?", r.id)[1]
        return true
    end)
    if err then return nil, err end
    local notified = false
    if not already then notified = notify_customer(order, row, decision) end
    local Settings = require("queries.ShopSettingsQueries")
    return {
        request = Q.shape(row, { admin = true }),
        already = already == true,
        customer_notified = notified,
        customer_notifications_enabled = Settings.customerDeliveryNotifications(ns_id),
        order = Orders.adminGet(ns_id, order_uuid),
    }
end

--- Drop-ship supplier POs of an order that still go out (not received, billed or cancelled). POs raised before
-- deal codes have no drop_ship flag; they were all drop-ships.
local function open_drop_ship_pos(ns_id, order_uuid)
    local ok, rows = pcall(db.query, [[
        SELECT id, po_number, status, supplier_name, sent_at
          FROM purchase_orders
         WHERE namespace_id = ? AND metadata->>'shop_order_uuid' = ? AND deleted_at IS NULL
           AND COALESCE((metadata->>'drop_ship')::boolean, true)
           AND status NOT IN ('received', 'billed', 'cancelled')
         ORDER BY id FOR UPDATE]], ns_id, order_uuid)
    return ok and rows or {}
end

--- Staff change the order's delivery address in the back office (no customer request needed).
-- body: { address = {name, company?, line1, line2?, city, county?, postcode, phone?, email?}, staff_note?,
--         update_purchase_orders? (default true) }. The old address goes into the internal notes. With
-- update_purchase_orders, open drop-ship supplier POs get the new "Deliver directly to" as well; POs already
-- sent come back in purchase_orders[].already_sent so staff know to tell the supplier.
function Q.adminSetAddress(ns_id, order_uuid, body, actor)
    body = type(body) == "table" and body or {}
    local addr, verr = R.clean_address(body.address)
    if not addr then return nil, U.err(400, "VALIDATION_ERROR", verr.message, { field = verr.field }) end
    local staff_note = R.clean_note(body.staff_note, R.NOTE_MAX)
    local update_pos = body.update_purchase_orders ~= false
    local who = U.nz(actor) and tostring(actor):sub(1, 254) or "staff"
    local pos_out = {}
    local _, err = U.tx(function()
        local o = db.query("SELECT " .. Orders.ORDER_COLS .. " FROM shop_orders o WHERE o.namespace_id = ? AND o.uuid = ? FOR UPDATE",
            ns_id, tostring(order_uuid or ""))[1]
        if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
        if not R.order_open(o.status) then
            return nil, U.err(409, "ORDER_NOT_CHANGEABLE", "The order is " .. o.status
                .. ", so the delivery address can't be changed.")
        end
        local cur = current_delivery(o)
        -- Keep what the form doesn't cover (email if left blank, VAT number on an agreed delivery address).
        local agreed = U.nz(o.delivery_address) and U.dec(o.delivery_address, {}) or {}
        addr.email = addr.email or agreed.email
        addr.vat_number = agreed.vat_number
        if cur.address and R.same_address(cur.address, addr) and (cur.address.phone or "") == (addr.phone or "")
            and (cur.address.email or "") == (addr.email or "") then
            return nil, U.err(400, "NO_CHANGE", "That is already the delivery address")
        end
        -- Blank company stays blank: a home address mustn't pick up the customer's company on the supplier PO.
        addr.company = addr.company or ""
        db.query("UPDATE shop_orders SET delivery_address = ?::jsonb, updated_at = NOW() WHERE id = ?", U.enc(addr), o.id)
        local line = stamp() .. " Delivery address changed by " .. who .. ": " .. R.describe_address(addr)
            .. ". Was: " .. R.describe_address(cur.address)
        if staff_note then line = line .. ". Note: " .. staff_note:gsub("\n", " ") end
        if update_pos then
            o.delivery_address = U.enc(addr)
            local ship_to = Orders.shipTo(o)
            local text = Orders.addressText(ship_to)
            for _, po in ipairs(open_drop_ship_pos(ns_id, o.uuid)) do
                db.query([[UPDATE purchase_orders SET delivery_address = ?,
                           metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{ship_to}', ?::jsonb), updated_at = NOW()
                           WHERE id = ?]], text or db.NULL, U.enc(ship_to), po.id)
                pos_out[#pos_out + 1] = { po_number = po.po_number, supplier_name = po.supplier_name, status = po.status,
                                          already_sent = U.nz(po.sent_at) ~= nil }
                line = line .. ". Supplier PO " .. tostring(po.po_number) .. " updated"
                    .. (U.nz(po.sent_at) and (" (already sent to " .. tostring(po.supplier_name or "the supplier")
                        .. ": tell them)") or "")
            end
        end
        append_note(o.id, line)
        return true
    end)
    if err then return nil, err end
    return { order = Orders.adminGet(ns_id, order_uuid), purchase_orders = U.arr(pos_out) }
end

function Q.approve(ns_id, order_uuid, request_uuid, body, actor)
    return decide(ns_id, order_uuid, request_uuid, body, actor, "approved")
end

function Q.decline(ns_id, order_uuid, request_uuid, body, actor)
    return decide(ns_id, order_uuid, request_uuid, body, actor, "declined")
end

Q.CUSTOMER_MESSAGE = CUSTOMER_MESSAGE

return Q
