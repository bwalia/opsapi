-- luacheck: max line length 140
--[[
    Introduce a customer to a supplier, from a quote (shop)
    =======================================================
    The quote page's "Introduce to supplier": when a supplier can serve the customer faster (stock, lead time,
    specialist kit), we introduce them directly. Unlike "Ask a supplier" (queries/ShopSupplierRequestQueries.lua),
    which never names the customer, this message DOES share the customer's name, organisation, email and phone,
    so it needs the customer's agreement: sending is refused unless staff confirm it (`customer_agreed`).

    The message comes from a template (lib/message-templates.lua kind supplier_intro): the one picked, else the
    supplier's own (e.g. "Introduction to Boston"), else the workspace default, else the built-in.
      email     sent from here through "Price requests to suppliers", the customer copied (cc) unless staff untick
                it, replies to the person who sent it;
      whatsapp  / sms   opens on the person's own device with the message ready (nothing is sent from here).
    Every introduction is recorded on the deal (shop_supplier_requests kind 'intro', migration zzs67) and in its
    audit trail, with what was sent and to whom.

      draft(ns_id, quote_uuid, { supplier, template }, user)
            → { deal_code, supplier, customer, template, templates, subject, body }
      send(ns_id, quote_uuid, body, user)
            body { supplier_uuid, channel, subject, message, customer_agreed = true, cc_customer? (default true),
                   template_uuid? } → { channel, request, sent_to?, cc?, link? }
    Errors are (nil, { status, code, message }).
]]

local db = require("lapis.db")
local U = require("lib.shop-util")
local Codes = require("lib.deal-codes")
local T = require("lib.message-templates")
local Templates = require("queries.ShopMessageTemplateQueries")
local Deal = require("queries.ShopDealQueries")
local Ask = require("queries.ShopSupplierRequestQueries")

local I = {}

I.CHANNELS = Ask.CHANNELS

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

local function quote_of(ns_id, quote_uuid, user_id)
    if type(quote_uuid) ~= "string" or quote_uuid == "" then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    local q = db.query([[SELECT id, quote_number, status, lines::text AS lines, deal_code, customer::text AS customer
                           FROM shop_quotes WHERE namespace_id = ? AND uuid = ?]], ns_id, quote_uuid)[1]
    if not q then return nil, U.err(404, "NOT_FOUND", "Quote not found") end
    local code = U.nz(q.deal_code) or Deal.forQuote(ns_id, q.id, user_id)
    if not code then return nil, U.err(501, "DEAL_CODES_UNAVAILABLE", "Deal codes are not set up yet") end
    return q, code
end

--- The customer as the supplier will see them.
function I.customer(q)
    local c = U.dec(q.customer, {})
    local function s(v)
        if type(v) ~= "string" then return nil end
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        return v ~= "" and v or nil
    end
    return { name = s(c.name), company = s(c.company), email = s(c.email), phone = s(c.phone) }
end

function I.vars(code, s, cust, lines, user, brand)
    local who = cust.name or cust.company or "our customer"
    local contact = {}
    for _, v in ipairs({ cust.name, cust.email, cust.phone }) do if v then contact[#contact + 1] = v end end
    return {
        ["supplier.name"] = s.name, ["supplier.contact"] = U.nz(s.contact_name) or s.name,
        ["sender.name"] = U.nz(U.join(" ", U.nz(user.first_name), U.nz(user.last_name))) or "",
        ["sender.email"] = U.nz(user.email) or "",
        ["company"] = brand or "", ["date"] = os.date("!%d %B %Y"),
        ["deal.code"] = code, ["lines"] = T.lines_text(lines),
        ["customer.name"] = who, ["customer.company"] = cust.company or who, ["customer.email"] = cust.email or "",
        ["customer.phone"] = cust.phone or "", ["customer.contact"] = table.concat(contact, " · "),
    }
end

local function public_supplier(s)
    return { uuid = s.uuid, name = s.name, contact_name = s.contact_name or U.null, email = s.email or U.null,
             phone = s.phone or U.null, phone_intl = Codes.intl_phone(s.phone) or U.null }
end

function I.draft(ns_id, quote_uuid, opts, user)
    opts, user = type(opts) == "table" and opts or {}, user or {}
    local q, code = quote_of(ns_id, quote_uuid, user.id)
    if not q then return nil, code end
    local s = supplier_of(ns_id, opts.supplier)
    if not s then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Choose a supplier") end
    local tpl, terr = Templates.pick(ns_id, "supplier_intro", { template_uuid = opts.template, supplier_id = s.id })
    if not tpl then return nil, terr end
    local cust = I.customer(q)
    local vars = I.vars(code, s, cust, Ask.lines(q), user, require("queries.ShopSettingsQueries").brandName(ns_id))
    return {
        deal_code = code, supplier = public_supplier(s),
        customer = { name = cust.name or U.null, company = cust.company or U.null, email = cust.email or U.null,
                     phone = cust.phone or U.null },
        template = { uuid = tpl.uuid, name = tpl.name, builtin = tpl.builtin },
        templates = Templates.choices(ns_id, "supplier_intro", s.id),
        subject = T.render(tpl.subject, vars), body = T.render(tpl.body, vars),
    }
end

local function html_of(message)
    local esc = message:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return "<div style=\"font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5\">"
        .. esc:gsub("\n", "<br>\n") .. "</div>"
end

function I.send(ns_id, quote_uuid, body, user)
    body, user = type(body) == "table" and body or {}, user or {}
    local channel = body.channel
    if not I.CHANNELS[channel] then
        return nil, U.err(400, "VALIDATION_ERROR", "Choose how to send it: email, WhatsApp or a text message")
    end
    if body.customer_agreed ~= true then
        return nil, U.err(422, "CUSTOMER_AGREEMENT_REQUIRED", "An introduction shares the customer's details with the supplier: "
            .. "confirm the customer agreed to it first")
    end
    local q, code = quote_of(ns_id, quote_uuid, user.id)
    if not q then return nil, code end
    local s = supplier_of(ns_id, body.supplier_uuid)
    if not s then return nil, U.err(404, "SUPPLIER_NOT_FOUND", "Choose a supplier") end
    local subject = text(body.subject, 200) or ("Introduction: " .. code)
    local message = text(body.message, 8000)
    if not message then return nil, U.err(400, "VALIDATION_ERROR", "Write the message to the supplier") end
    local cust = I.customer(q)

    local out = { channel = channel }
    if channel == "email" then
        if not s.email then
            return nil, U.err(400, "SUPPLIER_NO_EMAIL", "Add an email address to " .. s.name .. " first (Shop → Suppliers)")
        end
        local cc = (body.cc_customer ~= false) and cust.email or nil
        local NamespaceMail = require("helper.namespace-mail")
        local msg, smtp_or_err = NamespaceMail.prepare(ns_id, "supplier_requests", {
            to = s.email, cc = cc, subject = subject, html = html_of(message), text = message,
            from_name = require("queries.ShopSettingsQueries").brandName(ns_id), reply_to = U.nz(user.email), sync = true,
        })
        if not msg then
            return nil, U.err(503, "EMAIL_NOT_CONFIGURED", "No email account can send this: " .. tostring(smtp_or_err))
        end
        local sent, err = require("helper.mail").send(msg)
        if not sent then
            ngx.log(ngx.ERR, "[shop-supplier-intro] email to supplier ", s.uuid, " failed: ", tostring(err))
            return nil, U.err(502, "EMAIL_FAILED", "The email could not be sent. Check the workspace's email settings "
                .. "(Workspace → Email) and try again")
        end
        out.sent_to, out.cc = s.email, cc or U.null
    else
        local links = Codes.message_links(s.phone, subject .. "\n\n" .. message)
        if not links then
            return nil, U.err(400, "SUPPLIER_NO_PHONE", "Add a phone number to " .. s.name .. " first (Shop → Suppliers)")
        end
        out.link = links[channel]
    end

    -- Recorded on the deal: what was sent, to whom, and that the customer agreed.
    local lines = {}
    for _, l in ipairs(Ask.lines(q)) do
        lines[#lines + 1] = { line_uuid = l.line_uuid, description = l.description, qty = l.qty,
                              note = #l.parts > 0 and U.cut(table.concat(l.parts, "; "), 500) or nil }
    end
    local ok, err = pcall(db.query, [[
        INSERT INTO shop_supplier_requests (uuid, namespace_id, kind, deal_code, supplier_id, supplier_name, contact_name,
                                            contact_email, sent_at, lines, channel, message, notes, created_by_user_id,
                                            created_at, updated_at)
        VALUES (?, ?, 'intro', ?, ?, ?, ?, ?, ?::date, ?::jsonb, ?, ?, ?, ?, NOW(), NOW())
    ]], require("helper.global").generateUUID(), ns_id, code, s.id, s.name, s.contact_name or db.NULL, s.email or db.NULL,
        os.date("!%Y-%m-%d"), U.enc(U.arr(lines)), channel, U.cut(subject .. "\n\n" .. message, 8000),
        "Customer introduced with their agreement" .. ((channel == "email" and out.cc ~= U.null) and " (customer copied)" or ""),
        tonumber(user.id) or db.NULL)
    if not ok then
        ngx.log(ngx.ERR, "[shop-supplier-intro] not recorded on ", code, ": ", tostring(err))
        out.not_recorded = "not recorded"
    end
    Deal.audit(ns_id, code, "supplier_intro.sent", user.id, {
        supplier = s.name, channel = channel, customer_agreed = true, customer_copied = channel == "email" and out.cc ~= U.null,
        template = U.nz(body.template_uuid) or "builtin",
    })
    return out
end

return I
