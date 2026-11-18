-- luacheck: max line length 140
--[[
    Ask a supplier for a price from a quote (shop)
    ==============================================
    The quote page's "Ask a supplier": pick a supplier and the message is ready ("Hello Sam", the quote's
    lines with each configured line's parts, then: available? price ex VAT? when could you deliver? how long
    is the price valid?), subject "Price request: <deal code>". Staff can edit it, then
      email     sent from here, through the workspace's "Price requests to suppliers" email account, with
                replies going to the person who sent it;
      whatsapp  / sms   opens WhatsApp or the phone's text messages with the message ready (nothing here
                sends those: the person presses send on their own phone).
    Every request is recorded on the deal (shop_supplier_requests, queries/ShopDealQueries.lua), where the
    supplier's prices go when they answer.

    Suppliers never see the customer or our prices: the message is checked against the deal's customer
    details (name, email, phone, company, our quote numbers) when it is drafted and again before it goes.

      draft(ns_id, quote_uuid, supplier_uuid, user)  → { deal_code, supplier, subject, body, customer_details }
      send(ns_id, quote_uuid, body, user)            body { supplier_uuid, channel, subject?, message }
                                                     → { channel, request, sent_to?, link? }
    user: { id, first_name, last_name, email }. Errors are (nil, { status, code, message }).
]]

local db = require("lapis.db")
local U = require("lib.shop-util")
local Codes = require("lib.deal-codes")
local Deal = require("queries.ShopDealQueries")

local R = {}

R.CHANNELS = { email = "email", whatsapp = "WhatsApp", sms = "text message" }

local function text(v, max)
    if type(v) ~= "string" then return nil end
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then return nil end
    return U.cut(v, max)
end

local function supplier_of(ns_id, supplier_uuid)
    if type(supplier_uuid) ~= "string" or supplier_uuid == "" then return nil end
    return db.query([[SELECT id, uuid, name, contact_name, COALESCE(NULLIF(po_email, ''), NULLIF(contact_email, '')) AS email,
                             NULLIF(po_phone, '') AS phone
                        FROM shop_suppliers WHERE namespace_id = ? AND uuid = ?]], ns_id, supplier_uuid)[1]
end

--- The quote and its deal code (made now if it has none).
local function quote_of(ns_id, quote_uuid, user_id)
    if type(quote_uuid) ~= "string" or quote_uuid == "" then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    local q = db.query([[SELECT id, quote_number, status, lines::text AS lines, deal_code FROM shop_quotes
                          WHERE namespace_id = ? AND uuid = ?]], ns_id, quote_uuid)[1]
    if not q then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    local code = U.nz(q.deal_code) or Deal.forQuote(ns_id, q.id, user_id)
    if not code then return nil, U.err(501, "DEAL_CODES_UNAVAILABLE", "Deal codes are not set up yet") end
    return q, code
end

--- The quote's lines as the supplier reads them: what and how many, with a configured line's parts.
function R.lines(q)
    local out = {}
    for _, l in ipairs(U.dec(q.lines, {})) do
        local parts = {}
        for _, b in ipairs(type(l.breakdown) == "table" and l.breakdown or {}) do
            local name = text(b.name, 300)
            if name then
                local n = tonumber(b.qty) or 1
                parts[#parts + 1] = (n > 1 and (n .. " x ") or "") .. name
            end
        end
        out[#out + 1] = { line_uuid = l.uuid, description = Deal.line_description(l), qty = tonumber(l.qty or l.quantity) or 1,
                          parts = parts }
    end
    return out
end

local function public_supplier(s)
    return { uuid = s.uuid, name = s.name, contact_name = s.contact_name or U.null, email = s.email or U.null,
             phone = s.phone or U.null, phone_intl = Codes.intl_phone(s.phone) or U.null }
end

local function sender_of(user)
    user = user or {}
    return U.nz(U.join(" ", U.nz(user.first_name), U.nz(user.last_name)))
end

--- template_uuid: a price_request template (lib/message-templates.lua); nil = this supplier's own, else the
-- workspace default, else the built-in wording.
function R.draft(ns_id, quote_uuid, supplier_uuid, user, template_uuid)
    user = user or {}
    local q, code = quote_of(ns_id, quote_uuid, user.id)
    if not q then return nil, code end
    local s = supplier_of(ns_id, supplier_uuid)
    if not s then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Choose a supplier") end
    local Templates = require("queries.ShopMessageTemplateQueries")
    local tpl, terr = Templates.pick(ns_id, "price_request", { template_uuid = template_uuid, supplier_id = s.id })
    if not tpl then return nil, terr end
    local T = require("lib.message-templates")
    -- "Hello Sam" (their contact), else "Hello Boston".
    local vars = {
        ["supplier.name"] = s.name, ["supplier.contact"] = U.nz(s.contact_name) or s.name,
        ["sender.name"] = sender_of(user) or "", ["sender.email"] = U.nz(user.email) or "",
        ["company"] = require("queries.ShopSettingsQueries").brandName(ns_id) or "", ["date"] = os.date("!%d %B %Y"),
        ["deal.code"] = code, ["lines"] = T.lines_text(R.lines(q)),
    }
    local mail = { subject = T.render(tpl.subject, vars), body = T.render(tpl.body, vars) }
    -- Shown either way (staff can edit it); sending refuses while it shows the customer.
    local found = Codes.leaks(mail, Deal.customerMarkers(ns_id, code))
    return { deal_code = code, supplier = public_supplier(s), subject = mail.subject, body = mail.body,
             customer_details = U.arr(found), template = { uuid = tpl.uuid, name = tpl.name, builtin = tpl.builtin },
             templates = Templates.choices(ns_id, "price_request", s.id) }
end

local function html_of(message)
    local esc = message:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return "<div style=\"font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5\">"
        .. esc:gsub("\n", "<br>\n") .. "</div>"
end

local function send_email(ns_id, s, subject, message, user, brand)
    local NamespaceMail = require("helper.namespace-mail")
    local msg, smtp_or_err = NamespaceMail.prepare(ns_id, "supplier_requests", {
        to = s.email, subject = subject, html = html_of(message), text = message, from_name = brand,
        reply_to = U.nz(user.email), sync = true,
    })
    if not msg then
        return nil, U.err(503, "EMAIL_NOT_CONFIGURED", "No email account can send this: " .. tostring(smtp_or_err))
    end
    local sent, err = require("helper.mail").send(msg)
    if not sent then
        ngx.log(ngx.ERR, "[shop-supplier-request] email to supplier ", s.uuid, " failed: ", tostring(err))
        return nil, U.err(502, "EMAIL_FAILED", "The email could not be sent. Check the workspace's email settings "
            .. "(Workspace → Email) and try again")
    end
    return true
end

function R.send(ns_id, quote_uuid, body, user)
    body, user = type(body) == "table" and body or {}, user or {}
    local channel = body.channel
    if not R.CHANNELS[channel] then
        return nil, U.err(400, "VALIDATION_ERROR", "Choose how to send it: email, WhatsApp or a text message")
    end
    local q, code = quote_of(ns_id, quote_uuid, user.id)
    if not q then return nil, code end
    local s = supplier_of(ns_id, body.supplier_uuid)
    if not s then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Choose a supplier") end
    local subject = text(body.subject, 200) or ("Price request: " .. code)
    local message = text(body.message, 8000)
    if not message then return nil, U.err(400, "VALIDATION_ERROR", "Write the message to the supplier") end

    local found = Codes.leaks({ subject, message }, Deal.customerMarkers(ns_id, code))
    if #found > 0 then
        local what = table.concat(found, ", "):gsub("_", " ")
        return nil, U.err(422, "CUSTOMER_DETAILS_FOR_SUPPLIER", "Suppliers must not see the customer's details. Remove the "
            .. "customer's " .. what .. " from the message (the deal code is the only reference they need)",
            { fields = U.arr(found) })
    end

    local out = { channel = channel }
    if channel == "email" then
        if not s.email then
            return nil, U.err(400, "SUPPLIER_NO_EMAIL", "Add an email address to " .. s.name .. " first (Shop → Suppliers)")
        end
        local ok, err = send_email(ns_id, s, subject, message, user, require("queries.ShopSettingsQueries").brandName(ns_id))
        if not ok then return nil, err end
        out.sent_to = s.email
    else
        local links = Codes.message_links(s.phone, subject .. "\n\n" .. message)
        if not links then
            return nil, U.err(400, "SUPPLIER_NO_PHONE", "Add a phone number to " .. s.name .. " first (Shop → Suppliers)")
        end
        out.link = links[channel]
    end

    -- Recorded on the deal, where their prices go when they answer.
    local lines = {}
    for _, l in ipairs(R.lines(q)) do
        lines[#lines + 1] = { line_uuid = l.line_uuid, description = l.description, qty = l.qty,
                              note = #l.parts > 0 and U.cut(table.concat(l.parts, "; "), 500) or nil }
    end
    local request, rerr = Deal.createRequest(ns_id, code, {
        supplier_uuid = s.uuid, contact_name = s.contact_name, contact_email = s.email,
        sent_at = os.date("!%Y-%m-%d"), lines = lines,
    }, user.id)
    if not request then
        -- The email has gone: say so rather than fail the whole thing.
        ngx.log(ngx.ERR, "[shop-supplier-request] not recorded on ", code, ": ", tostring(rerr and rerr.message))
        out.request, out.not_recorded = U.null, rerr and rerr.message or "not recorded"
        return out
    end
    db.query("UPDATE shop_supplier_requests SET channel = ?, message = ? WHERE uuid = ? AND namespace_id = ?",
        channel, U.cut(subject .. "\n\n" .. message, 8000), request.uuid, ns_id)
    request.channel = channel
    Deal.audit(ns_id, code, "supplier_request.sent", user.id, { supplier = s.name, request = request.uuid, channel = channel })
    out.request = request
    return out
end

return R
