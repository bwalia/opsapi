--[[
    Purchase Order Routes
    =====================

    Namespace-scoped supplier purchase orders. Every endpoint needs a JWT, a
    namespace and the `purchase_orders` RBAC module; billing and voiding a bill
    also need `accounting` create/delete when Bookkeeping is on (they write the
    purchase ledger). Loaded with the invoicing feature (app.lua). Business
    rules live in queries/PurchaseOrderQueries.lua. Create, email, receive and
    bill take an Idempotency-Key header (helper/idempotency.lua). Exceptions go
    to the app error handler (client input -> 4xx, anything else -> SYSTEM_500).

    Endpoints:
    - GET    /api/v2/purchase-orders/stats                 - Counts/values for the list page
    - GET    /api/v2/purchase-orders                       - List (status, supplier, project_uuid, dates)
    - POST   /api/v2/purchase-orders                       - Create draft (optionally with items)
    - GET    /api/v2/purchase-orders/:uuid                 - PO with items + linked project
    - PUT    /api/v2/purchase-orders/:uuid                 - Update header (draft/sent/acknowledged)
    - DELETE /api/v2/purchase-orders/:uuid                 - Soft delete (draft only)

    - POST   /api/v2/purchase-orders/:uuid/send            - draft -> sent (no email)
    - POST   /api/v2/purchase-orders/:uuid/email           - Email supplier (+PDF), marks a draft sent
    - POST   /api/v2/purchase-orders/:uuid/acknowledge     - sent -> acknowledged
    - POST   /api/v2/purchase-orders/:uuid/receive         - Record quantities received now
    - POST   /api/v2/purchase-orders/:uuid/convert-to-bill - Bill what is received, not yet billed
    - POST   /api/v2/purchase-orders/:uuid/bills/:bill_uuid/void - Void a bill (ledger expense still pending)
    - POST   /api/v2/purchase-orders/:uuid/close           - Close a partially received PO short
    - POST   /api/v2/purchase-orders/:uuid/cancel          - Cancel (draft/sent/acknowledged)

    - POST   /api/v2/purchase-orders/:uuid/items           - Add line (draft)
    - PUT    /api/v2/purchase-orders/items/:item_uuid      - Update line (draft)
    - DELETE /api/v2/purchase-orders/items/:item_uuid      - Delete line (draft)
]]

local cjson = require("cjson.safe")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local PurchaseOrderQueries = require("queries.PurchaseOrderQueries")
local Mail = require("helper.mail")
local NamespaceMail = require("helper.namespace-mail")
local Idempotency = require("helper.idempotency")
local RateLimit = require("middleware.rate-limit")
local Global = require("helper.global")

-- One address: no lists, display names or header characters.
local EMAIL = "^[%w%.%%%+%-_']+@[%w%-]+[%w%-%.]*%.%a%a+$"
local MAX_PDF_B64 = 7 * 1024 * 1024 -- ~5 MB of PDF
local EMAIL_LIMIT = { rate = 20, window = 600 } -- per user

return function(app)

    -- JSON first; form-encoded as a fallback (same contract as routes/invoices.lua).
    local function parse_body()
        ngx.req.read_body()
        local content_type = ngx.req.get_headers()["content-type"] or ""
        local raw = ngx.req.get_body_data()
        if content_type:find("application/json", 1, true) then
            if not raw or raw == "" then return {} end
            local decoded = cjson.decode(raw)
            return type(decoded) == "table" and decoded or {}
        end
        local args = ngx.req.get_post_args()
        if args and next(args) then
            -- Form posts carry nested arrays as JSON strings.
            for _, k in ipairs({ "items", "metadata" }) do
                if type(args[k]) == "string" then args[k] = cjson.decode(args[k]) end
            end
            return args
        end
        if raw and raw ~= "" then
            local decoded = cjson.decode(raw)
            if type(decoded) == "table" then return decoded end
        end
        return {}
    end

    local function ok(status, data)
        return { status = status, json = { success = true, data = data } }
    end

    local STATUS_FOR = { not_found = 404, conflict = 409, invalid = 400 }

    local function fail(message, code, status)
        return { status = status or STATUS_FOR[code] or 400, json = { success = false, error = message } }
    end

    local function blank(v) return v == nil or v == "" or v == cjson.null end

    local function guard(action, handler)
        return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("purchase_orders", action, handler))
    end

    -- Idempotency-Key: a retried request gets the first answer, nothing runs twice.
    local function idem(self, fn)
        return Idempotency.run(self, self.namespace.id, self.current_user.uuid, fn)
    end

    -- Billing writes the accounting purchase ledger (and voiding removes from
    -- it): with Bookkeeping on, the user needs that permission too.
    local function ledger_denied(self, action)
        if PurchaseOrderQueries.ledgerOn() and not NamespaceMiddleware.hasPermission(self, "accounting", action) then
            return fail("This posts to the purchase ledger: you also need the Bookkeeping (accounting) "
                .. action .. " permission", nil, 403)
        end
    end

    -- Header-safe text: no control characters (CR/LF would start a new header).
    local function one_line(v) return (tostring(v):gsub("%c", " ")) end

    local function html_escape(s)
        return (tostring(s or ""):gsub("[&<>\"']", {
            ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
        }))
    end

    -- ============================================================
    -- STATS + LIST + CREATE (static paths before :uuid)
    -- ============================================================

    app:get("/api/v2/purchase-orders/stats", guard("read", function(self)
        return ok(200, PurchaseOrderQueries.getStats(self.namespace.id))
    end))

    app:get("/api/v2/purchase-orders", guard("read", function(self)
        local p = self.params
        local result, message, code = PurchaseOrderQueries.list(self.namespace.id, {
            page = Global.pageParam(p.page),
            perPage = Global.perPageParam(p.perPage or p.per_page, 20, 500),
            status = p.status,
            supplier = p.supplier,
            supplier_company_uuid = p.supplier_company_uuid,
            project_uuid = p.project_uuid,
            from_date = p.from_date or p.date_from,
            to_date = p.to_date or p.date_to,
            search = p.search or p.q,
            order_by = p.order_by,
            order_dir = p.order_dir,
        })
        if not result then return fail(message, code) end
        return {
            status = 200,
            json = {
                success = true,
                data = result.data,
                meta = {
                    total = result.total,
                    page = result.page,
                    perPage = result.perPage,
                    totalPages = math.ceil(result.total / result.perPage),
                },
            },
        }
    end))

    app:post("/api/v2/purchase-orders", guard("create", function(self)
        return idem(self, function()
            local po, message, code = PurchaseOrderQueries.create(self.namespace.id, self.current_user.uuid,
                parse_body())
            if not po then return fail(message, code) end
            return ok(201, po)
        end)
    end))

    -- ============================================================
    -- LINE ITEMS by item uuid (before :uuid so "items" isn't a PO uuid)
    -- ============================================================

    app:put("/api/v2/purchase-orders/items/:item_uuid", guard("update", function(self)
        local item, message, code = PurchaseOrderQueries.updateItem(self.params.item_uuid, self.namespace.id,
            parse_body())
        if not item then return fail(message, code) end
        return ok(200, item)
    end))

    app:delete("/api/v2/purchase-orders/items/:item_uuid", guard("update", function(self)
        local done, message, code = PurchaseOrderQueries.deleteItem(self.params.item_uuid, self.namespace.id)
        if not done then return fail(message, code) end
        return ok(200, { message = "Line item deleted" })
    end))

    -- ============================================================
    -- CRUD
    -- ============================================================

    app:get("/api/v2/purchase-orders/:uuid", guard("read", function(self)
        local po = PurchaseOrderQueries.get(self.params.uuid, self.namespace.id)
        if not po then return fail("Purchase order not found", "not_found") end
        return ok(200, po)
    end))

    app:put("/api/v2/purchase-orders/:uuid", guard("update", function(self)
        local po, message, code = PurchaseOrderQueries.update(self.params.uuid, self.namespace.id, parse_body())
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    app:delete("/api/v2/purchase-orders/:uuid", guard("delete", function(self)
        local done, message, code = PurchaseOrderQueries.delete(self.params.uuid, self.namespace.id)
        if not done then return fail(message, code) end
        return ok(200, { message = "Purchase order deleted" })
    end))

    -- ============================================================
    -- WORKFLOW
    -- ============================================================

    app:post("/api/v2/purchase-orders/:uuid/send", guard("update", function(self)
        local po, message, code = PurchaseOrderQueries.send(self.params.uuid, self.namespace.id)
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    -- Email the PO to the supplier (one address: `to`, else the PO's supplier
    -- email). The dashboard builds the PDF in the browser (same as invoices)
    -- and posts it as base64; without one the email still carries the lines.
    -- Sent through the workspace's own SMTP when set up (the mail server's
    -- answer is known), else queued on the platform's with reply-to = the
    -- sender. A draft is marked sent. Rate-limited per user.
    app:post("/api/v2/purchase-orders/:uuid/email", guard("update", function(self)
        local allowed, _, retry = RateLimit.check("po_email:" .. tostring(self.current_user.uuid),
            EMAIL_LIMIT.rate, EMAIL_LIMIT.window)
        if not allowed then
            ngx.header["Retry-After"] = tostring(retry)
            return fail("Too many purchase order emails - try again in " .. retry .. " seconds", nil, 429)
        end
        return idem(self, function()
            local body = parse_body()
            local po = PurchaseOrderQueries.get(self.params.uuid, self.namespace.id)
            if not po then return fail("Purchase order not found", "not_found") end
            if po.status == "cancelled" or po.status == "billed" then
                return fail("Cannot email a " .. po.status .. " purchase order", "conflict")
            end
            if po.status == "draft" and #po.items == 0 then
                return fail("Add at least one line before sending", "invalid")
            end

            local to = body.to
            if blank(to) then
                to = po.supplier_email
                if blank(to) then
                    return fail("No supplier email on this purchase order - add one or pass a recipient", "invalid")
                end
            end
            if type(to) ~= "string" or #to > 254 or not to:match(EMAIL) then
                return fail(blank(body.to) and "The supplier email on this purchase order isn't a valid address"
                    or "to must be one email address", "invalid")
            end
            for _, k in ipairs({ "subject", "message", "filename" }) do
                if not blank(body[k]) and type(body[k]) ~= "string" then
                    return fail(k .. " must be text", "invalid")
                end
            end
            if not blank(body.subject) and #body.subject > 200 then
                return fail("subject is too long (200 characters at most)", "invalid")
            end
            if not blank(body.message) and #body.message > 5000 then
                return fail("message is too long (5000 characters at most)", "invalid")
            end

            local company = one_line(self.namespace.name or "Our company"):sub(1, 100)
            local subject = blank(body.subject) and ("Purchase order " .. po.po_number .. " from " .. company)
                or one_line(body.subject)

            local rows = {}
            for _, it in ipairs(po.items) do
                rows[#rows + 1] = "<tr><td>" .. html_escape(it.description) .. "</td><td style=\"text-align:right\">"
                    .. html_escape(it.quantity) .. "</td><td style=\"text-align:right\">"
                    .. html_escape(it.unit_price) .. "</td><td style=\"text-align:right\">"
                    .. html_escape(it.line_total) .. "</td></tr>"
            end
            local note = not blank(body.message) and ("<p>" .. html_escape(body.message) .. "</p>") or ""
            local html = table.concat({
                "<p>Dear ", html_escape(po.supplier_name), ",</p>", note,
                "<p>Please supply the following against purchase order <strong>", html_escape(po.po_number),
                "</strong>", po.reference and (" (ref " .. html_escape(po.reference) .. ")") or "", ".</p>",
                "<table cellpadding=\"6\" style=\"border-collapse:collapse\">",
                "<tr><th align=\"left\">Item</th><th>Qty</th><th>Unit price</th><th>Total</th></tr>",
                table.concat(rows),
                "<tr><td colspan=\"3\" align=\"right\"><strong>Total (", html_escape(po.currency), ")</strong></td>",
                "<td style=\"text-align:right\"><strong>", html_escape(po.total), "</strong></td></tr></table>",
                po.expected_date and ("<p>Required by: " .. html_escape(po.expected_date) .. "</p>") or "",
                po.delivery_address and ("<p>Deliver to: " .. html_escape(po.delivery_address) .. "</p>") or "",
                "<p>Please quote the PO number on your invoice.</p>",
                "<p>", html_escape(company), "</p>",
            })

            local attachments
            if not blank(body.pdf_base64) then
                local pdf = type(body.pdf_base64) == "string" and #body.pdf_base64 <= MAX_PDF_B64
                    and ngx.decode_base64(body.pdf_base64)
                if not pdf or pdf:sub(1, 5) ~= "%PDF-" then
                    return fail("pdf_base64 must be a base64-encoded PDF of at most 5 MB", "invalid")
                end
                local filename = blank(body.filename) and ("PurchaseOrder-" .. po.po_number)
                    or body.filename:gsub("%.[pP][dD][fF]$", ""):gsub("[^%w%.%-_ ()]", "_"):sub(1, 100)
                attachments = {
                    { filename = filename .. ".pdf", content_type = "application/pdf", content_b64 = body.pdf_base64 },
                }
            end

            -- The sender, for supplier replies (the platform's address isn't read by anyone here).
            local user_email = self.current_user.email
            if type(user_email) ~= "string" or not user_email:match(EMAIL) then user_email = nil end
            local mail = { to = to, subject = subject, html = html, attachments = attachments,
                from_name = company, reply_to = user_email }
            local smtp = NamespaceMail.smtp(self.namespace.id)
            if smtp then
                if not NamespaceMail.hostOk(smtp.host) then
                    return fail("This workspace's mail server address isn't allowed - check Settings > Email",
                        "invalid", 422)
                end
                -- Workspace server: sent now (the async queue only knows the platform's server).
                mail.smtp, mail.sync, mail.from_email = smtp, true, smtp.from_email
                mail.from_name = smtp.from_name or company
                mail.reply_to = smtp.reply_to or user_email
            elseif not Mail.isConfigured() then
                return fail("Email isn't set up: add this workspace's mail server in Settings > Email, "
                    .. "or ask your administrator to configure SMTP", nil, 503)
            end

            local sent, mail_err = Mail.send(mail)
            if not sent then
                -- The mail server's reply stays in the log: it can echo addresses and server details.
                ngx.log(ngx.ERR, "[purchase-orders] email ", po.uuid, " failed: ", tostring(mail_err))
                if smtp then
                    return fail("Your workspace's mail server didn't accept the email - check Settings > Email "
                        .. "and try again", nil, 502)
                end
                return fail("The email couldn't be queued - try again shortly", nil, 503)
            end

            local status = po.status
            if po.status == "draft" then
                local updated = PurchaseOrderQueries.send(po.uuid, self.namespace.id)
                if updated then status = updated.status end
            end
            -- Accepted for sending, not delivered: the platform queue sends in the background.
            return ok(200, {
                message = smtp and ("Purchase order handed to your mail server for " .. to)
                    or ("Purchase order queued for sending to " .. to),
                to = to, status = status, via = smtp and "workspace" or "platform",
            })
        end)
    end))

    app:post("/api/v2/purchase-orders/:uuid/acknowledge", guard("update", function(self)
        local po, message, code = PurchaseOrderQueries.acknowledge(self.params.uuid, self.namespace.id)
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    -- items[].quantity is what arrived now (added to the line, never above the
    -- ordered quantity); receive_all takes in everything outstanding.
    app:post("/api/v2/purchase-orders/:uuid/receive", guard("update", function(self)
        return idem(self, function()
            local po, message, code = PurchaseOrderQueries.receive(self.params.uuid, self.namespace.id,
                self.current_user.uuid, parse_body())
            if not po then return fail(message, code) end
            return ok(200, po)
        end)
    end))

    -- Bills what is received and not yet billed; may be called again as more arrives.
    app:post("/api/v2/purchase-orders/:uuid/convert-to-bill", guard("update", function(self)
        local denied = ledger_denied(self, "create")
        if denied then return denied end
        return idem(self, function()
            local po, message, code = PurchaseOrderQueries.convertToBill(self.params.uuid, self.namespace.id,
                self.current_user.uuid, parse_body())
            if not po then return fail(message, code) end
            return ok(200, po)
        end)
    end))

    app:post("/api/v2/purchase-orders/:uuid/bills/:bill_uuid/void", guard("update", function(self)
        local denied = ledger_denied(self, "delete")
        if denied then return denied end
        local po, message, code = PurchaseOrderQueries.voidBill(self.params.uuid, self.namespace.id,
            self.current_user.uuid, self.params.bill_uuid, parse_body().reason)
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    app:post("/api/v2/purchase-orders/:uuid/close", guard("update", function(self)
        local po, message, code = PurchaseOrderQueries.close(self.params.uuid, self.namespace.id,
            self.current_user.uuid, parse_body().reason)
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    app:post("/api/v2/purchase-orders/:uuid/cancel", guard("update", function(self)
        local body = parse_body()
        local po, message, code = PurchaseOrderQueries.cancel(self.params.uuid, self.namespace.id, body.reason)
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    -- ============================================================
    -- LINE ITEMS on a PO
    -- ============================================================

    app:post("/api/v2/purchase-orders/:uuid/items", guard("update", function(self)
        local item, message, code = PurchaseOrderQueries.addItem(self.params.uuid, self.namespace.id, parse_body())
        if not item then return fail(message, code) end
        return ok(201, item)
    end))

end
