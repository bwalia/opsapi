-- luacheck: max line length 140
--[[
    Supplier portal notifications
    =============================
    Two directions:
      - the supplier did something (acknowledged, uploaded a document, dispatched, delivered, wrote a message):
        an in-app notification for our staff (the PO's creator and the workspace owners). Never an email.
      - we did something the supplier should know (PO shared, payment recorded, document added, message):
        an email to the supplier's own portal users, ONLY when Shop → Settings → "Supplier portal emails"
        (shop_settings.supplier_portal_emails_enabled) is on. It is off by default; while it is off nothing is
        sent and the PO's history says so ("notification.suppressed").
    Hard guard, whatever the setting: an address is emailed only if it is one of that supplier's portal users,
    and never if it belongs to one of our customers (shop orders, quotes, CRM leads, the deal's customer)
    — lib/supplier-portal.lua safeRecipients.
    Every send is best effort: a failure is logged and never fails the action that triggered it.
]]

local db = require("lapis.db")
local Global = require("helper.global")
local Rules = require("lib.supplier-portal")
local U = require("lib.shop-util")

local N = {}

N.SUPPLIER_EVENTS = {
    po_shared = "A purchase order is ready for you",
    payment_recorded = "We have recorded a payment",
    document_uploaded = "We have added a document",
    message_posted = "New message about your purchase order",
    po_cancelled = "A purchase order was cancelled",
}

N.STAFF_EVENTS = {
    acknowledged = "Supplier acknowledged",
    document_uploaded = "Supplier uploaded a document",
    dispatched = "Supplier dispatched the goods",
    delivered = "Supplier marked it delivered",
    message_posted = "New message from the supplier",
}

local function table_exists(name)
    local ok, r = pcall(db.query, "SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return ok and r[1] and r[1].ok == true
end

local function audit(ns_id, po_uuid, action, detail)
    pcall(db.query, [[INSERT INTO namespace_audit_logs (uuid, namespace_id, user_id, action, entity_type, entity_id,
                      new_values, created_at) VALUES (?, ?, NULL, ?, 'purchase_order', ?, ?, NOW())]],
        Global.generateUUID(), ns_id, action, po_uuid, U.enc(detail))
end

local function emails_enabled(ns_id)
    local ok, rows = pcall(db.query, "SELECT supplier_portal_emails_enabled FROM shop_settings WHERE namespace_id = ?", ns_id)
    return ok and rows[1] ~= nil and rows[1].supplier_portal_emails_enabled == true
end
N.emailsEnabled = emails_enabled

--- Every email address that belongs to one of our customers in this workspace (lower case → true).
function N.customerEmails(ns_id, deal_code)
    local set = {}
    local function add(e)
        e = Rules.email(e)
        if e then set[e] = true end
    end
    local queries = {
        { "shop_orders", [[SELECT email AS e FROM shop_orders WHERE namespace_id = ? AND email IS NOT NULL
                           UNION SELECT customer->>'email' FROM shop_orders WHERE namespace_id = ?]], 2 },
        { "shop_quotes", "SELECT customer->>'email' AS e FROM shop_quotes WHERE namespace_id = ?", 1 },
        { "crm_leads", "SELECT email AS e FROM crm_leads WHERE namespace_id = ?", 1 },
        { "customers", "SELECT email AS e FROM customers WHERE namespace_id = ?", 1 },
    }
    for _, q in ipairs(queries) do
        if table_exists(q[1]) then
            local ok, rows
            if q[3] == 2 then ok, rows = pcall(db.query, q[2], ns_id, ns_id) else ok, rows = pcall(db.query, q[2], ns_id) end
            if ok then for _, r in ipairs(rows) do add(r.e) end end
        end
    end
    if deal_code and table_exists("shop_deal_codes") then
        local ok, markers = pcall(function() return require("queries.ShopDealQueries").customerMarkers(ns_id, deal_code) end)
        if ok then
            for _, m in ipairs(markers or {}) do
                if m.field == "email" then add(m.value) end
            end
        end
    end
    return set
end

local function supplier_users(ns_id, supplier_uuid)
    local rows = db.query([[
        SELECT spu.email FROM supplier_portal_users spu JOIN shop_suppliers s ON s.id = spu.supplier_id
          JOIN users u ON u.id = spu.user_id
         WHERE spu.namespace_id = ? AND s.uuid = ? AND spu.status <> 'disabled' AND u.active = true]], ns_id, supplier_uuid)
    local list, set = {}, {}
    for _, r in ipairs(rows) do
        local e = Rules.email(r.email)
        if e then list[#list + 1] = e; set[e] = true end
    end
    return list, set
end

local function html_escape(s)
    return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;",
                                                 ["'"] = "&#39;" }))
end

--- Tell the supplier (email, only when switched on). po: { uuid, po_number, metadata = { shop_supplier_uuid,
-- deal_code } }. → { sent = n, suppressed = reason | nil }
function N.toSupplier(ns_id, po, event, detail)
    local result = { sent = 0 }
    local ok, err = pcall(function()
        local m = type(po.metadata) == "table" and po.metadata or U.dec(po.metadata, {})
        local supplier_uuid = m.shop_supplier_uuid
        if not supplier_uuid or not N.SUPPLIER_EVENTS[event] then
            result.suppressed = "no_supplier"
            return
        end
        local candidates, allowed = supplier_users(ns_id, supplier_uuid)
        local enabled = emails_enabled(ns_id)
        local to, why = Rules.safeRecipients(enabled, candidates, allowed,
            enabled and N.customerEmails(ns_id, m.deal_code or po.deal_code) or {})
        if #to == 0 then
            result.suppressed = why
            audit(ns_id, po.uuid, "notification.suppressed", { event = event, reason = why, by = "system" })
            return
        end
        local Mail = require("helper.mail")
        local NamespaceMail = require("helper.namespace-mail")
        local ns = db.query("SELECT name FROM namespaces WHERE id = ?", ns_id)[1] or {}
        local base = (U.env("FRONTEND_URL") or ""):gsub("/+$", "")
        local link = base ~= "" and (base .. "/supplier/purchase-orders/" .. po.uuid) or nil
        local subject = N.SUPPLIER_EVENTS[event] .. ": " .. tostring(po.po_number)
        local html = table.concat({
            "<p>Hello,</p>",
            "<p>", html_escape(N.SUPPLIER_EVENTS[event]), " (purchase order <strong>", html_escape(po.po_number),
            "</strong>).</p>",
            detail and detail.summary and ("<p>" .. html_escape(detail.summary) .. "</p>") or "",
            link and ("<p><a href=\"" .. html_escape(link) .. "\">Open it in the supplier portal</a></p>") or
                "<p>Sign in to the supplier portal to see it.</p>",
            "<p>", html_escape(ns.name or ""), "</p>",
        })
        for _, addr in ipairs(to) do
            local msg, smtp_or_err = NamespaceMail.prepare(ns_id, "purchase_orders",
                { to = addr, subject = subject, html = html, from_name = ns.name })
            -- the workspace's own server is sent to now (the async queue only knows the platform's)
            if msg and smtp_or_err then msg.sync = true end
            local perr = not msg and smtp_or_err or nil
            if msg then
                local sent = Mail.send(msg)
                if sent then result.sent = result.sent + 1 end
            else
                ngx.log(ngx.WARN, "[supplier-portal] email not sent: ", tostring(perr))
            end
        end
        audit(ns_id, po.uuid, "notification.sent", { event = event, count = result.sent, by = "system" })
    end)
    if not ok then ngx.log(ngx.WARN, "[supplier-portal] supplier notification failed: ", tostring(err)) end
    return result
end

--- Tell our staff (in-app only): the PO's creator and the workspace owners.
function N.toStaff(ns_id, po, event, detail)
    local ok, err = pcall(function()
        if not N.STAFF_EVENTS[event] or not table_exists("notifications") then return end
        local ids, seen = {}, {}
        local function add(id)
            id = tonumber(id)
            if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
        if po.created_by_uuid then
            local r = db.query("SELECT id FROM users WHERE uuid = ?", po.created_by_uuid)[1]
            if r then add(r.id) end
        end
        for _, r in ipairs(db.query([[SELECT user_id FROM namespace_members WHERE namespace_id = ? AND is_owner = true
                                      AND status = 'active']], ns_id)) do
            add(r.user_id)
        end
        local title = N.STAFF_EVENTS[event] .. ": " .. tostring(po.po_number)
        local message = (detail and detail.summary) or title
        for _, uid in ipairs(ids) do
            -- a supplier login is never a staff recipient
            local sup = db.query("SELECT 1 AS x FROM supplier_portal_users WHERE user_id = ?", uid)[1]
            if not sup then
                db.query([[INSERT INTO notifications (uuid, user_id, type, title, message, data, related_entity_type,
                           related_entity_id, is_read, created_at) VALUES (?, ?, ?, ?, ?, ?, 'purchase_order', ?, false, NOW())]],
                    Global.generateUUID(), uid, "supplier_portal." .. event, title:sub(1, 250), message,
                    U.enc({ po_uuid = po.uuid, link = "/dashboard/purchase-orders/" .. po.uuid }), po.uuid)
            end
        end
    end)
    if not ok then ngx.log(ngx.WARN, "[supplier-portal] staff notification failed: ", tostring(err)) end
end

return N
