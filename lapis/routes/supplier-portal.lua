-- luacheck: max line length 140
--[[
    Supplier portal API (FEATURES.SHOP + purchase orders)
    =====================================================
    Suppliers sign in with their own OpsAPI login (always with an emailed sign-in code) and see ONLY their own
    supplier's purchase orders. A supplier login can use nothing else: helper/supplier-portal-guard.lua refuses
    every other route for it. Everything they do is in the PO's history (who, when, IP).

    Supplier routes — /api/v2/supplier-portal (JWT of a supplier login; 403 PORTAL_NOT_AVAILABLE while
    Shop → Settings → Supplier portal is off; another supplier's ids answer 404)
      GET  /me                                    who I am, my company, the buyer's name
      GET  /purchase-orders?stage=open|all|<stage>&search=&page=&perPage=
      GET  /purchase-orders/:uuid                 PO (deal code + spec, never our customer), documents, proforma /
                                                  invoices, payments, deliveries, messages, history, what I can do
      POST /purchase-orders/:uuid/acknowledge     { note? }
      POST /purchase-orders/:uuid/documents       multipart: file (PDF/PNG/JPG ≤ 20 MB), doc_type = proforma |
                                                  vat_invoice | delivery_note | proof_of_delivery | credit_note | other,
                                                  note?, invoice (JSON text, for proforma / vat_invoice / credit_note:
                                                  { number, invoice_date, net, vat, total, supplier_order_ref?,
                                                  payment_terms?, incoterm?, due_date?, bank_details?, currency? })
      POST /purchase-orders/:uuid/dispatch        { carrier, tracking_number?, tracking_url?, dispatched_on?, expected_on?, note? }
      POST /purchase-orders/:uuid/delivered       multipart: file (proof of delivery) + delivered_on?, received_by?, note?
                                                  (or JSON when a POD / delivery note is already uploaded)
      POST /purchase-orders/:uuid/messages        { body }
      GET  /documents?doc_type=   GET /payments   GET /messages
      POST /documents/:uuid/link                  { path, expires_in, expires_at }: a 2-minute download link
    Download (no JWT: the signed link is the credential, checked again against the person and the document)
      GET  /api/v2/public/supplier-portal/files/:token

    Staff routes — RBAC purchase_orders (read / update / delete); supplier logins refused
      GET  /api/v2/purchase-invoices                                  every supplier invoice / proforma / credit note
                                                                      across POs: paid, owed, overdue (?q=&state=&kind=
                                                                      &supplier=&from=&to=&limit=&offset=)
      GET  /api/v2/purchase-orders/:uuid/portal                       the PO page's supplier panels
      POST /api/v2/purchase-orders/:uuid/portal/link                  { supplier_id, confirm? } link to a shop supplier
      POST /api/v2/purchase-orders/:uuid/portal/stage                 { to: acknowledged|cancelled|closed, reason?, force? }
      POST /api/v2/purchase-orders/:uuid/portal/documents             multipart as above; doc_type also purchase_order,
                                                                      payment_proof; visible_to_supplier? (default true)
      POST /api/v2/purchase-orders/:uuid/portal/documents/:doc/link   download link
      POST /api/v2/purchase-orders/:uuid/portal/documents/:doc/remove { reason } (delete permission)
      POST /api/v2/purchase-orders/:uuid/portal/invoices              { kind, number, invoice_date, net, vat, total, ... ,
                                                                      document_id? } (no file: it came by email)
      POST /api/v2/purchase-orders/:uuid/portal/invoices/:inv/remove  { reason } (delete permission)
      POST /api/v2/purchase-orders/:uuid/portal/payments              JSON or multipart (file = the bank's confirmation):
                                                                      { amount, method, sent_on, cleared_on?,
                                                                      bank_transaction_id?, payment_reference?, invoice_id?,
                                                                      proof_document_id?, note? }
      PUT  /api/v2/purchase-orders/:uuid/portal/payments/:pay         { cleared_on?, bank_transaction_id?, payment_reference?, note? }
      POST /api/v2/purchase-orders/:uuid/portal/payments/:pay/void    { reason }
      POST /api/v2/purchase-orders/:uuid/portal/dispatch | /delivered | /messages   as the supplier routes
    Supplier logins — RBAC shop
      GET  /api/v2/shop/admin/suppliers/:uuid/portal-users
      POST /api/v2/shop/admin/suppliers/:uuid/portal-users            { email, name? } → set_password_path (7 days)
      POST /api/v2/shop/admin/suppliers/:uuid/portal-users/:pu/link | /disable | /enable
    Settings: PUT /api/v2/shop/admin/settings { supplier_portal_enabled, supplier_portal_emails_enabled } (both off by default)
]]

local U = require("lib.shop-util")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RateLimit = require("middleware.rate-limit")
local Guard = require("helper.supplier-portal-guard")
local Q = require("queries.SupplierPortalQueries")

local SP = "/api/v2/supplier-portal"
local PO = "/api/v2/purchase-orders/:uuid/portal"
local SUP = "/api/v2/shop/admin/suppliers/:uuid/portal-users"

local READ_LIMIT = { rate = 120, window = 60, prefix = "supplier-portal:read" }
local WRITE_LIMIT = { rate = 30, window = 60, prefix = "supplier-portal:write" }
local UPLOAD_LIMIT = { rate = 60, window = 600, prefix = "supplier-portal:upload" }
local LINK_LIMIT = { rate = 60, window = 60, prefix = "supplier-portal:link" }
local DOWNLOAD_LIMIT = { rate = 60, window = 60, prefix = "supplier-portal:download" }

local function result(res, err)
    if res == nil then return U.from_err(err) end
    return U.ok(res, 200)
end

-- (value, err) of a query as a 201 Created
local function created(res, err)
    if res == nil then return U.from_err(err) end
    return U.ok(res, 201)
end

local function is_multipart()
    return (ngx.var.http_content_type or ""):lower():find("multipart/form-data", 1, true) ~= nil
end

--- The request's fields: JSON body, or the form / multipart params.
local function fields(self)
    if (ngx.var.http_content_type or ""):lower():find("application/json", 1, true) then
        local body, err = U.read_json()
        if not body then return nil, U.fail(400, "INVALID_JSON", err) end
        return body
    end
    local out = {}
    for k, val in pairs(self.params or {}) do
        if type(k) == "string" and type(val) ~= "table" then out[k] = val end
    end
    return out
end

--- The uploaded file from a multipart request: { filename, content, content_type } | nil
local function upload_of(self)
    local f = self.params and self.params.file
    if type(f) ~= "table" or type(f.content) ~= "string" then return nil end
    return { filename = f.filename, content = f.content, content_type = f["content-type"] or f.content_type }
end

-- A signed-in supplier (supplier_portal_users), rate limited per IP.
local function supplier(limit, handler)
    return RateLimit.wrap(limit, U.safe(function(self)
        if not self.current_user then return U.fail(401, "UNAUTHORIZED", "Please sign in") end
        local ctx, err = Q.supplierContext(self.current_user)
        if not ctx then return U.from_err(err) end
        return handler(self, ctx)
    end))
end

-- Staff with module.action; a supplier login never passes, whatever role it has been given.
local function staff(module, action, handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission(module, action, U.safe(function(self)
        if Guard.isSupplier(self.current_user and self.current_user.uuid) then
            return U.fail(403, "SUPPLIER_PORTAL_ONLY", "Supplier accounts can only use the supplier portal")
        end
        if not Q.available() then
            return U.fail(404, "NOT_AVAILABLE", "The supplier portal isn't set up in this deployment")
        end
        return handler(self, self.namespace.id, Q.staffActor(self.current_user))
    end)))
end

return function(app)
    -- =====================================================================
    -- supplier
    -- =====================================================================

    app:get(SP .. "/me", supplier(READ_LIMIT, function(_, ctx)
        local s = Q.settings(ctx.ns_id)
        return U.ok({
            user = { name = ctx.name, email = ctx.email },
            supplier = { id = ctx.supplier_uuid, name = ctx.supplier_name },
            buyer = { name = ctx.ns_name },
            emails_enabled = s.emails_enabled,
        })
    end))

    app:get(SP .. "/purchase-orders", supplier(READ_LIMIT, function(self, ctx)
        local r = Q.supplierList(ctx, self.params)
        return U.ok(r.data, 200, r.meta)
    end))

    app:get(SP .. "/purchase-orders/:uuid", supplier(READ_LIMIT, function(self, ctx)
        return result(Q.supplierGet(ctx, self.params.uuid))
    end))

    app:post(SP .. "/purchase-orders/:uuid/acknowledge", supplier(WRITE_LIMIT, function(self, ctx)
        local body, bad = fields(self)
        if not body then return bad end
        local ok, err = Q.acknowledge(Q.supplierScope(ctx), self.params.uuid, ctx, body)
        if not ok then return U.from_err(err) end
        return result(Q.supplierGet(ctx, self.params.uuid))
    end))

    app:post(SP .. "/purchase-orders/:uuid/documents", supplier(UPLOAD_LIMIT, function(self, ctx)
        if not is_multipart() then return U.fail(400, "VALIDATION_ERROR", "Send the file as multipart/form-data (field: file)") end
        local body = fields(self)
        return created(Q.upload(Q.supplierScope(ctx), self.params.uuid, ctx, upload_of(self), body))
    end))

    app:post(SP .. "/purchase-orders/:uuid/dispatch", supplier(WRITE_LIMIT, function(self, ctx)
        local body, bad = fields(self)
        if not body then return bad end
        return result(Q.dispatch(Q.supplierScope(ctx), self.params.uuid, ctx, body))
    end))

    app:post(SP .. "/purchase-orders/:uuid/delivered", supplier(UPLOAD_LIMIT, function(self, ctx)
        local body, bad = fields(self)
        if not body then return bad end
        return result(Q.delivered(Q.supplierScope(ctx), self.params.uuid, ctx, body, is_multipart() and upload_of(self) or nil))
    end))

    app:post(SP .. "/purchase-orders/:uuid/messages", supplier(WRITE_LIMIT, function(self, ctx)
        local body, bad = fields(self)
        if not body then return bad end
        return created(Q.postMessage(Q.supplierScope(ctx), self.params.uuid, ctx, body))
    end))

    app:get(SP .. "/documents", supplier(READ_LIMIT, function(self, ctx)
        return U.ok(Q.supplierDocuments(ctx, self.params))
    end))

    app:post(SP .. "/documents/:uuid/link", supplier(LINK_LIMIT, function(self, ctx)
        return result(Q.documentLink(Q.supplierScope(ctx), self.params.uuid, ctx))
    end))

    app:get(SP .. "/payments", supplier(READ_LIMIT, function(_, ctx)
        return U.ok(Q.supplierPayments(ctx))
    end))

    app:get(SP .. "/messages", supplier(READ_LIMIT, function(_, ctx)
        return U.ok(Q.supplierMessages(ctx))
    end))

    -- =====================================================================
    -- download (the signed link is the credential)
    -- =====================================================================

    app:get("/api/v2/public/supplier-portal/files/:token", RateLimit.wrap(DOWNLOAD_LIMIT, U.safe(function(self)
        local f, err = Q.download(self.params.token)
        if not f then return U.from_err(err) end
        local name = tostring(f.filename or "document"):gsub("[^%w%._%-() ]", "_")
        return {
            status = 200, layout = false, content_type = f.content_type,
            headers = {
                ["Content-Disposition"] = 'attachment; filename="' .. name .. '"',
                ["Cache-Control"] = "no-store, private",
                ["X-Content-Type-Options"] = "nosniff",
                ["Content-Security-Policy"] = "default-src 'none'; sandbox",
                ["Referrer-Policy"] = "no-referrer",
            },
            f.content,
        }
    end)))

    -- =====================================================================
    -- staff: the PO page
    -- =====================================================================

    -- Purchase invoices: every supplier invoice, proforma and credit note across POs, with what is paid and owed
    -- (queries/PurchaseInvoiceQueries.lua). ?q=&state=owed|overdue|paid|unpaid|part_paid|proforma|credit&kind=
    -- &supplier=&from=&to=&limit=&offset=
    app:get("/api/v2/purchase-invoices", staff("purchase_orders", "read", function(self, ns_id)
        local rows, meta = require("queries.PurchaseInvoiceQueries").list(ns_id, self.params)
        if not rows then return U.from_err(meta) end
        return U.ok(rows, 200, meta)
    end))

    app:get(PO, staff("purchase_orders", "read", function(self, ns_id)
        return result(Q.staffPanel(ns_id, self.params.uuid))
    end))

    app:post(PO .. "/link", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return result(Q.link(ns_id, self.params.uuid, actor, body))
    end))

    app:post(PO .. "/stage", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return result(Q.staffStage(ns_id, self.params.uuid, actor, body))
    end))

    app:post(PO .. "/documents", staff("purchase_orders", "update", function(self, ns_id, actor)
        if not is_multipart() then return U.fail(400, "VALIDATION_ERROR", "Send the file as multipart/form-data (field: file)") end
        local res, err = Q.upload(Q.staffScope(ns_id), self.params.uuid, actor, upload_of(self), fields(self))
        if not res then return U.from_err(err) end
        local panel = Q.staffPanel(ns_id, self.params.uuid)
        panel.uploaded = res
        return U.ok(panel, 201)
    end))

    app:post(PO .. "/documents/:doc/link", staff("purchase_orders", "read", function(self, ns_id, actor)
        return result(Q.documentLink(Q.staffScope(ns_id), self.params.doc, actor))
    end))

    app:post(PO .. "/documents/:doc/remove", staff("purchase_orders", "delete", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return result(Q.deleteDocument(ns_id, self.params.uuid, self.params.doc, actor, body))
    end))

    app:post(PO .. "/invoices", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return created(Q.recordInvoice(ns_id, self.params.uuid, actor, body))
    end))

    app:post(PO .. "/invoices/:inv/remove", staff("purchase_orders", "delete", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return result(Q.deleteInvoice(ns_id, self.params.uuid, self.params.inv, actor, body))
    end))

    app:post(PO .. "/payments", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return created(Q.recordPayment(ns_id, self.params.uuid, actor, body, is_multipart() and upload_of(self) or nil))
    end))

    app:put(PO .. "/payments/:pay", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return result(Q.updatePayment(ns_id, self.params.uuid, self.params.pay, actor, body))
    end))

    app:post(PO .. "/payments/:pay/void", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return result(Q.voidPayment(ns_id, self.params.uuid, self.params.pay, actor, body))
    end))

    app:post(PO .. "/dispatch", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        local ok, err = Q.dispatch(Q.staffScope(ns_id), self.params.uuid, actor, body)
        if not ok then return U.from_err(err) end
        return result(Q.staffPanel(ns_id, self.params.uuid))
    end))

    app:post(PO .. "/delivered", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        local ok, err = Q.delivered(Q.staffScope(ns_id), self.params.uuid, actor, body, is_multipart() and upload_of(self) or nil)
        if not ok then return U.from_err(err) end
        return result(Q.staffPanel(ns_id, self.params.uuid))
    end))

    app:post(PO .. "/messages", staff("purchase_orders", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        local res, err = Q.postMessage(Q.staffScope(ns_id), self.params.uuid, actor, body)
        if not res then return U.from_err(err) end
        local panel = Q.staffPanel(ns_id, self.params.uuid)
        panel.notification = res.notification
        return U.ok(panel, 201)
    end))

    -- =====================================================================
    -- staff: supplier logins (Shop → Suppliers)
    -- =====================================================================

    app:get(SUP, staff("shop", "read", function(self, ns_id)
        return result(Q.listPortalUsers(ns_id, self.params.uuid))
    end))

    app:post(SUP, staff("shop", "update", function(self, ns_id, actor)
        local body, bad = fields(self)
        if not body then return bad end
        return created(Q.invite(ns_id, self.params.uuid, actor, body))
    end))

    app:post(SUP .. "/:pu/link", staff("shop", "update", function(self, ns_id, actor)
        return result(Q.newLink(ns_id, self.params.uuid, self.params.pu, actor))
    end))

    app:post(SUP .. "/:pu/disable", staff("shop", "update", function(self, ns_id, actor)
        return result(Q.setUserStatus(ns_id, self.params.uuid, self.params.pu, actor, false))
    end))

    app:post(SUP .. "/:pu/enable", staff("shop", "update", function(self, ns_id, actor)
        return result(Q.setUserStatus(ns_id, self.params.uuid, self.params.pu, actor, true))
    end))
end
