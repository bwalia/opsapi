--[[
    Purchase Order Routes
    =====================

    Namespace-scoped supplier purchase orders. Every endpoint needs a JWT, a
    namespace and the `purchase_orders` RBAC module. Loaded with the invoicing
    feature (app.lua). Business rules live in queries/PurchaseOrderQueries.lua.

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
    - POST   /api/v2/purchase-orders/:uuid/receive         - Record received quantities
    - POST   /api/v2/purchase-orders/:uuid/convert-to-bill - Bill it (purchase-ledger expense)
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
local Global = require("helper.global")

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

    local function fail(message, code)
        return { status = STATUS_FOR[code] or 400, json = { success = false, error = message } }
    end

    -- Wrap a query call: malformed dates/numbers hit Postgres casts and would
    -- otherwise surface as a raw 500 instead of a clean validation error.
    local function run(label, fn, ...)
        local okc, value, message, code = pcall(fn, ...)
        if not okc then
            ngx.log(ngx.ERR, "[PurchaseOrders] ", label, " failed: ", tostring(value))
            return nil, "Could not " .. label .. " - check the submitted fields (dates, amounts, items)", "invalid"
        end
        return value, message, code
    end

    local function guard(action, handler)
        return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission("purchase_orders", action, handler))
    end

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
        local result, message, code = run("list purchase orders", PurchaseOrderQueries.list, self.namespace.id, {
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
        local po, message, code = run("create the purchase order", PurchaseOrderQueries.create,
            self.namespace.id, self.current_user.uuid, parse_body())
        if not po then return fail(message, code) end
        return ok(201, po)
    end))

    -- ============================================================
    -- LINE ITEMS by item uuid (before :uuid so "items" isn't a PO uuid)
    -- ============================================================

    app:put("/api/v2/purchase-orders/items/:item_uuid", guard("update", function(self)
        local item, message, code = run("update the line", PurchaseOrderQueries.updateItem,
            self.params.item_uuid, self.namespace.id, parse_body())
        if not item then return fail(message, code) end
        return ok(200, item)
    end))

    app:delete("/api/v2/purchase-orders/items/:item_uuid", guard("update", function(self)
        local done, message, code = run("delete the line", PurchaseOrderQueries.deleteItem,
            self.params.item_uuid, self.namespace.id)
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
        local po, message, code = run("update the purchase order", PurchaseOrderQueries.update,
            self.params.uuid, self.namespace.id, parse_body())
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    app:delete("/api/v2/purchase-orders/:uuid", guard("delete", function(self)
        local done, message, code = run("delete the purchase order", PurchaseOrderQueries.delete,
            self.params.uuid, self.namespace.id)
        if not done then return fail(message, code) end
        return ok(200, { message = "Purchase order deleted" })
    end))

    -- ============================================================
    -- WORKFLOW
    -- ============================================================

    app:post("/api/v2/purchase-orders/:uuid/send", guard("update", function(self)
        local po, message, code = run("send the purchase order", PurchaseOrderQueries.send,
            self.params.uuid, self.namespace.id)
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    -- Email the PO to the supplier. The dashboard builds the PDF in the browser
    -- (same as invoices) and posts it as base64; without one the email still
    -- carries the lines in its body. A draft is marked sent once emailed.
    app:post("/api/v2/purchase-orders/:uuid/email", guard("update", function(self)
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
        if not to or to == "" then to = po.supplier_email end
        if not to or to == "" then
            return fail("No supplier email on this purchase order - add one or pass a recipient", "invalid")
        end

        local company = self.namespace.name or "Our company"
        local subject = body.subject
        if not subject or subject == "" then
            subject = "Purchase order " .. po.po_number .. " from " .. company
        end

        local rows = {}
        for _, it in ipairs(po.items) do
            rows[#rows + 1] = "<tr><td>" .. html_escape(it.description) .. "</td><td style=\"text-align:right\">"
                .. html_escape(it.quantity) .. "</td><td style=\"text-align:right\">"
                .. html_escape(it.unit_price) .. "</td><td style=\"text-align:right\">"
                .. html_escape(it.line_total) .. "</td></tr>"
        end
        local note = (body.message and body.message ~= "")
            and ("<p>" .. html_escape(body.message) .. "</p>") or ""
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
        if body.pdf_base64 and body.pdf_base64 ~= "" then
            local filename = body.filename
            if not filename or filename == "" then filename = "PurchaseOrder-" .. po.po_number .. ".pdf" end
            attachments = {
                { filename = filename, content_type = "application/pdf", content_b64 = body.pdf_base64 },
            }
        end

        local sent, mail_err = Mail.send({ to = to, subject = subject, html = html, attachments = attachments })
        if not sent then
            return { status = 502, json = { success = false, error = "Could not send email: " .. tostring(mail_err) } }
        end

        local status = po.status
        if po.status == "draft" then
            local updated = PurchaseOrderQueries.send(po.uuid, self.namespace.id)
            if updated then status = updated.status end
        end
        return ok(200, { message = "Purchase order emailed to " .. to, to = to, status = status })
    end))

    app:post("/api/v2/purchase-orders/:uuid/acknowledge", guard("update", function(self)
        local po, message, code = run("acknowledge the purchase order", PurchaseOrderQueries.acknowledge,
            self.params.uuid, self.namespace.id)
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    app:post("/api/v2/purchase-orders/:uuid/receive", guard("update", function(self)
        local po, message, code = run("record the receipt", PurchaseOrderQueries.receive,
            self.params.uuid, self.namespace.id, self.current_user.uuid, parse_body())
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    app:post("/api/v2/purchase-orders/:uuid/convert-to-bill", guard("update", function(self)
        local po, message, code = run("bill the purchase order", PurchaseOrderQueries.convertToBill,
            self.params.uuid, self.namespace.id, self.current_user.uuid, parse_body())
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    app:post("/api/v2/purchase-orders/:uuid/cancel", guard("update", function(self)
        local body = parse_body()
        local po, message, code = run("cancel the purchase order", PurchaseOrderQueries.cancel,
            self.params.uuid, self.namespace.id, body.reason)
        if not po then return fail(message, code) end
        return ok(200, po)
    end))

    -- ============================================================
    -- LINE ITEMS on a PO
    -- ============================================================

    app:post("/api/v2/purchase-orders/:uuid/items", guard("update", function(self)
        local item, message, code = run("add the line", PurchaseOrderQueries.addItem,
            self.params.uuid, self.namespace.id, parse_body())
        if not item then return fail(message, code) end
        return ok(201, item)
    end))

end
