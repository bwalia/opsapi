-- luacheck: max line length 140
--[[
    Order update emails ("Email the customer" on the dashboard order page)
    =======================================================================
    Staff pick a preset (lib/shop-order-updates.lua), edit the headline and message, preview and send.
    The email is the workspace-overridable template shop.order_update (helper/namespace-mail.lua), sent
    through the workspace's SMTP when it has one. A transactional message: no unsubscribe, no pixel.

      presets(ns_id, uuid, user_id)        the presets filled in for this order, the recipient, whether
                                           customer emails are on, and the history of sent updates
      preview(ns_id, uuid, body, user_id)  { subject, html, to, warnings, customised }
      send(ns_id, uuid, body, user_id)     body { preset?, headline, message, test? }

    Rules
      - test = true sends a "[TEST]" copy to the signed-in staff member only (always allowed).
      - A real send needs Shop settings → customer_delivery_notifications ("Customer emails from the shop")
        on (409 CUSTOMER_EMAILS_OFF otherwise), an order email (409 NO_CUSTOMER_EMAIL), no "[NEW DATE]"
        marker left in the text (400), and at most MAX_PER_DAY real sends per order in 24 hours (429).
      - A real send appends a line to the order's internal notes; every send (tests too) is logged in
        shop_order_emails (migration zzs53). The log row is written first, under the order's lock, so the daily
        limits hold when two sends race; a send that fails removes its row again.
      - The email goes out under the workspace's name (Settings.brandName); the phone line only when
        SHOP_CALL_PHONE is set.
]]

local db = require("lapis.db")
local Global = require("helper.global")
local U = require("lib.shop-util")
local Upd = require("lib.shop-order-updates")
local Orders = require("queries.ShopOrderQueries")
local Settings = require("queries.ShopSettingsQueries")

local Q = {}

local EMAIL = "^[^@%s]+@[^@%s]+%.[^@%s]+$"

local function valid_email(e)
    return type(e) == "string" and #e <= 254 and e:match(EMAIL) ~= nil
end

--- The customer's email: the order's, else the one on the customer block.
local function recipient(o)
    local customer = U.dec(o.customer, {})
    local to = U.nz(o.email) or U.nz(customer.email)
    if to then to = tostring(to):gsub("^%s+", ""):gsub("%s+$", "") end
    return valid_email(to) and to or nil
end

local function customer_name(o)
    local customer = U.dec(o.customer, {})
    local ship = U.nz(o.shipping_address) and U.dec(o.shipping_address, {}) or {}
    local name = U.nz(customer.name) or (type(ship) == "table" and U.nz(ship.name)) or nil
    return type(name) == "string" and name or nil
end

--- The signed-in staff member: { name?, email? }.
local function staff(user_id)
    if not user_id then return {} end
    local u = db.query("SELECT first_name, last_name, email FROM users WHERE id = ?", user_id)[1]
    if not u then return {} end
    local name = table.concat({ U.nz(u.first_name) or "", U.nz(u.last_name) or "" }, " "):gsub("^%s+", ""):gsub("%s+$", "")
    return { name = name ~= "" and name or nil, email = U.nz(u.email) }
end

local function order_link(o)
    local base = U.env("SHOP_PUBLIC_URL")
    if not base then return nil end
    return base:gsub("/+$", "") .. "/orders/" .. o.uuid .. "?t=" .. o.access_token
end

local function delivery_summary(o)
    return Upd.delivery_summary({
        delivery_date = U.nz(o.delivery_date), delivery_window = U.nz(o.delivery_window),
        delivery_address = U.nz(o.delivery_address) and U.dec(o.delivery_address, nil) or nil,
    })
end

--- Values for the preset placeholders.
local function preset_vars(o)
    local name = customer_name(o)
    return {
        first_name = Upd.first_name(name) or "there",
        order_number = o.order_number,
        tracking_line = Upd.tracking_line(U.dec(o.tracking, nil)),
    }
end

--- Template data for the email.
local function template_data(o, upd, me, brand, opts)
    local name = customer_name(o)
    return {
        app_name = brand,
        customer_name = name,
        first_name = Upd.first_name(name),
        order_number = o.order_number,
        headline = upd.headline,
        message = upd.message,
        order_link = order_link(o),
        delivery_summary = delivery_summary(o),
        signature = me.name or Upd.team_signature(brand),
        signature_is_person = me.name ~= nil,
        call_phone = U.env("SHOP_CALL_PHONE"),
        test = opts and opts.test == true or nil,
        test_customer = opts and opts.test and recipient(o) or nil,
    }
end

local function load(ns_id, uuid)
    local o = Orders.getByUuid(ns_id, uuid)
    if not o then return nil, U.err(404, "NOT_FOUND", "Order not found") end
    return o
end

--- The update emails sent for an order, newest first ([] before migration zzs53).
function Q.history(order_id)
    local ok, rows = pcall(db.query, [[
        SELECT uuid, kind, headline, body, subject, to_email, sent_by, test, created_at
          FROM shop_order_emails WHERE order_id = ? ORDER BY created_at DESC, id DESC LIMIT 50]], order_id)
    return U.arr(ok and rows or {})
end

local function recent_count(order_id, test)
    local ok, rows = pcall(db.query, [[SELECT COUNT(*)::int AS n FROM shop_order_emails
        WHERE order_id = ? AND test = ? AND created_at > NOW() - INTERVAL '24 hours']], order_id, test)
    return ok and tonumber(rows[1].n) or 0
end

--- The same update sent to the customer in the last 10 minutes (a double click)?
local function duplicate(order_id, upd)
    local ok, rows = pcall(db.query, [[SELECT 1 FROM shop_order_emails
        WHERE order_id = ? AND test = false AND headline = ? AND body = ? AND created_at > NOW() - INTERVAL '10 minutes'
        LIMIT 1]], order_id, upd.headline, upd.message)
    return ok and rows[1] ~= nil
end

--- headline + message from the body, falling back to the chosen preset filled in for this order.
local function resolve(o, body)
    body = type(body) == "table" and body or {}
    local p = Upd.preset(body.preset)
    local filled = p and Upd.render(p, preset_vars(o)) or nil
    local input = {
        headline = body.headline ~= nil and body.headline or (filled and filled.headline),
        message = body.message ~= nil and body.message or (filled and filled.message),
    }
    local upd, verr = Upd.validate(input)
    if not upd then
        return nil, U.err(400, "VALIDATION_ERROR", verr.message, { field = verr.field })
    end
    upd.kind = p and p.key or "custom"
    return upd
end

local function warnings_for(o, upd)
    local out = {}
    local marker = Upd.unfilled(upd.headline) or Upd.unfilled(upd.message)
    if marker then out[#out + 1] = "Replace " .. marker .. " before sending to the customer" end
    if not order_link(o) then out[#out + 1] = "SHOP_PUBLIC_URL is not set, so the email has no link to the order" end
    return out
end

local function email_configured(ns_id)
    local Mail = require("helper.mail")
    local NamespaceMail = require("helper.namespace-mail")
    return NamespaceMail.smtp(ns_id, "shop_orders") ~= nil or Mail.isConfigured()
end

function Q.presets(ns_id, uuid, user_id)
    local o, err = load(ns_id, uuid)
    if not o then return nil, err end
    local vars = preset_vars(o)
    local list = {}
    for _, p in ipairs(Upd.PRESETS) do list[#list + 1] = Upd.render(p, vars) end
    local me = staff(user_id)
    return {
        presets = list,
        to = recipient(o) or U.null,
        customer_name = customer_name(o) or U.null,
        customer_emails_enabled = Settings.customerDeliveryNotifications(ns_id),
        email_configured = email_configured(ns_id),
        test_to = me.email or U.null,
        signature = me.name or Upd.team_signature(Settings.brandName(ns_id)),
        limits = { headline_max = Upd.HEADLINE_MAX, message_max = Upd.MESSAGE_MAX, per_day = Upd.MAX_PER_DAY,
                   sent_last_24h = recent_count(o.id, false) },
        history = Q.history(o.id),
    }
end

function Q.preview(ns_id, uuid, body, user_id)
    local o, err = load(ns_id, uuid)
    if not o then return nil, err end
    local upd, verr = resolve(o, body)
    if not upd then return nil, verr end
    local NamespaceMail = require("helper.namespace-mail")
    local brand = Settings.brandName(ns_id)
    local r, rerr = NamespaceMail.render(ns_id, Upd.TEMPLATE_KEY, template_data(o, upd, staff(user_id), brand), { app_name = brand })
    if not r then
        ngx.log(ngx.ERR, "[shop-order-update] preview for ", o.order_number, " failed: ", tostring(rerr))
        return nil, U.err(500, "PREVIEW_FAILED", "Could not show the email. Check the workspace's email template")
    end
    return { subject = r.subject, html = r.html, customised = r.customised, to = recipient(o) or U.null,
             headline = upd.headline, message = upd.message, kind = upd.kind, warnings = U.arr(warnings_for(o, upd)) }
end

function Q.send(ns_id, uuid, body, user_id)
    body = type(body) == "table" and body or {}
    local test = body.test == true
    local o, err = load(ns_id, uuid)
    if not o then return nil, err end
    local upd, verr = resolve(o, body)
    if not upd then return nil, verr end
    local me = staff(user_id)

    local to
    if test then
        to = valid_email(me.email) and me.email or nil
        if not to then return nil, U.err(400, "VALIDATION_ERROR", "Your account has no email address to send the test to") end
    else
        if not Settings.customerDeliveryNotifications(ns_id) then
            return nil, U.err(409, "CUSTOMER_EMAILS_OFF", "Customer emails from the shop are turned off. Turn on "
                .. "\"Customer emails from the shop\" in Shop → Settings once the sending address is right, or send a test to yourself.")
        end
        to = recipient(o)
        if not to then return nil, U.err(409, "NO_CUSTOMER_EMAIL", "This order has no customer email address") end
        local marker = Upd.unfilled(upd.headline) or Upd.unfilled(upd.message)
        if marker then
            return nil, U.err(400, "VALIDATION_ERROR", "Replace " .. marker .. " in the message before sending it", { field = "message" })
        end
    end

    if not email_configured(ns_id) then
        return nil, U.err(503, "EMAIL_NOT_CONFIGURED", "No email server is set up for this workspace")
    end
    local NamespaceMail = require("helper.namespace-mail")
    local brand = Settings.brandName(ns_id)
    local data = template_data(o, upd, me, brand, { test = test })
    local rendered = NamespaceMail.render(ns_id, Upd.TEMPLATE_KEY, data, { app_name = brand })
    local subject = (test and "[TEST] " or "") .. (rendered and rendered.subject or upd.headline)
    local by = me.name or me.email or "staff"

    -- Log the send first, under the order's lock: the limits are checked and the row written in one step, so
    -- two sends at once can't both pass the check.
    local log_uuid = Global.generateUUID()
    local reserved, rerr = U.tx(function()
        db.query("SELECT 1 FROM shop_orders WHERE id = ? FOR UPDATE", o.id)
        if test and recent_count(o.id, true) >= Upd.TEST_MAX_PER_DAY then
            return nil, U.err(429, "RATE_LIMITED", "Too many test emails for this order today. Try again tomorrow.")
        end
        if not test and recent_count(o.id, false) >= Upd.MAX_PER_DAY then
            return nil, U.err(429, "RATE_LIMITED", "This order has had " .. Upd.MAX_PER_DAY
                .. " update emails in the last 24 hours. Call the customer, or try again later.")
        end
        if not test and duplicate(o.id, upd) then
            return nil, U.err(409, "DUPLICATE_SEND", "This update was already emailed to the customer a few minutes ago")
        end
        db.query([[INSERT INTO shop_order_emails (uuid, namespace_id, order_id, kind, headline, body, subject, to_email,
                                                  sent_by, sent_by_user_id, test)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
            log_uuid, ns_id, o.id, upd.kind, upd.headline, upd.message, U.cut(subject, 255), to,
            U.cut(by, 254), user_id or db.NULL, test)
        return true
    end)
    if not reserved then return nil, rerr end

    local sent, merr = NamespaceMail.send(ns_id, Upd.TEMPLATE_KEY, to, data, { app_name = brand },
        { subject_prefix = test and "[TEST] " or nil })
    if not sent then
        ngx.log(ngx.ERR, "[shop-order-update] email for ", o.order_number, " failed: ", tostring(merr))
        pcall(db.query, "DELETE FROM shop_order_emails WHERE uuid = ?", log_uuid)
        return nil, U.err(502, "EMAIL_FAILED", "The email could not be sent. Check the workspace's email settings "
            .. "(Workspace → Email) and try again")
    end

    if not test then
        local ok, nerr = pcall(function()
            local stamp = db.query("SELECT to_char(NOW() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI') AS t")[1].t
            db.query([[UPDATE shop_orders SET internal_notes = COALESCE(internal_notes || E'\n', '') || ?, updated_at = NOW()
                       WHERE id = ?]], Upd.note_line(stamp, to, by, upd.headline), o.id)
        end)
        if not ok then ngx.log(ngx.ERR, "[shop-order-update] sent but no order note for ", o.order_number, ": ", tostring(nerr)) end
    end
    return { sent = true, test = test, to = to, subject = subject, logged = true,
             history = Q.history(o.id), order = Orders.adminGet(ns_id, uuid) }
end

return Q
