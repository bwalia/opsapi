--[[
    Invoice Routes
    ==============

    API endpoints for namespace-scoped invoice management.
    All endpoints require JWT authentication and namespace context.

    Endpoints:
    - GET    /api/v2/invoices                          - List invoices
    - POST   /api/v2/invoices                          - Create invoice
    - GET    /api/v2/invoices/:uuid                    - Get invoice with line items and payments
    - PUT    /api/v2/invoices/:uuid                    - Update invoice
    - DELETE /api/v2/invoices/:uuid                    - Soft delete (draft only)

    - POST   /api/v2/invoices/:uuid/send               - Mark as sent
    - POST   /api/v2/invoices/:uuid/void               - Void invoice

    - POST   /api/v2/invoices/:uuid/items              - Add line item
    - PUT    /api/v2/invoices/items/:item_uuid         - Update line item
    - DELETE /api/v2/invoices/items/:item_uuid         - Delete line item

    - POST   /api/v2/invoices/:uuid/payments           - Record payment
    - GET    /api/v2/invoices/:uuid/payments           - List payments
    - DELETE /api/v2/invoices/payments/:payment_uuid   - Delete payment

    - POST   /api/v2/invoices/from-timesheet           - Create invoice from timesheet

    - GET    /api/v2/invoices/tax-rates                - List tax rates
    - POST   /api/v2/invoices/tax-rates                - Create tax rate
    - PUT    /api/v2/invoices/tax-rates/:uuid          - Update tax rate
    - DELETE /api/v2/invoices/tax-rates/:uuid          - Deactivate tax rate

    - GET    /api/v2/invoices/dashboard/stats          - Invoice statistics
]]

local cjson = require("cjson.safe")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local InvoiceQueries = require("queries.InvoiceQueries")

-- Configure cjson
cjson.encode_empty_table_as_object(false)

return function(app)

    -- Parse request body (supports both JSON and form-urlencoded)
    local function parse_request_body()
        ngx.req.read_body()

        -- First, check if we have form params
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then
            return post_args
        end

        -- Fallback to JSON parsing
        local ok, result = pcall(function()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cjson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
        end
        return {}
    end

    local function parse_json_body()
        return parse_request_body()
    end

    -- Standard API response wrapper
    local function api_response(status, data, error_msg)
        if error_msg then
            return {
                status = status,
                json = {
                    success = false,
                    error = error_msg
                }
            }
        end
        return {
            status = status,
            json = {
                success = true,
                data = data
            }
        }
    end

    -- Validate required fields
    local function validate_required(data, fields)
        local missing = {}
        for _, field in ipairs(fields) do
            if not data[field] or data[field] == "" then
                table.insert(missing, field)
            end
        end
        if #missing > 0 then
            return false, "Missing required fields: " .. table.concat(missing, ", ")
        end
        return true
    end

    -- ============================================================
    -- DASHBOARD STATS (must be before :uuid routes)
    -- ============================================================

    app:get("/api/v2/invoices/dashboard/stats", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local stats = InvoiceQueries.getDashboardStats(self.namespace.id)
            return api_response(200, stats)
        end)
    ))

    -- ============================================================
    -- TAX RATES (must be before :uuid routes)
    -- ============================================================

    -- GET /api/v2/invoices/tax-rates - List tax rates
    app:get("/api/v2/invoices/tax-rates", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local rates = InvoiceQueries.getTaxRates(self.namespace.id)
            return api_response(200, rates)
        end)
    ))

    -- POST /api/v2/invoices/tax-rates - Create tax rate
    app:post("/api/v2/invoices/tax-rates", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            local valid, err = validate_required(body, { "name", "rate" })
            if not valid then
                return api_response(400, nil, err)
            end

            body.namespace_id = self.namespace.id
            local rate = InvoiceQueries.createTaxRate(body)
            return api_response(201, rate)
        end)
    ))

    -- PUT /api/v2/invoices/tax-rates/:uuid - Update tax rate
    app:put("/api/v2/invoices/tax-rates/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            local rate, err = InvoiceQueries.updateTaxRate(self.params.uuid, body)
            if not rate then
                return api_response(404, nil, err)
            end
            return api_response(200, rate)
        end)
    ))

    -- DELETE /api/v2/invoices/tax-rates/:uuid - Deactivate tax rate
    app:delete("/api/v2/invoices/tax-rates/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ok, err = InvoiceQueries.deleteTaxRate(self.params.uuid)
            if not ok then
                return api_response(404, nil, err)
            end
            return api_response(200, { message = "Tax rate deactivated" })
        end)
    ))

    -- ============================================================
    -- FROM TIMESHEET (must be before :uuid routes)
    -- ============================================================

    -- POST /api/v2/invoices/from-timesheet - Create invoice from approved timesheet
    app:post("/api/v2/invoices/from-timesheet", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            local valid, err = validate_required(body, { "timesheet_id" })
            if not valid then
                return api_response(400, nil, err)
            end

            local hourly_rate = tonumber(body.hourly_rate) or 0
            if hourly_rate <= 0 then
                return api_response(400, nil, "hourly_rate must be greater than zero")
            end

            local result, create_err = InvoiceQueries.createFromTimesheet(
                self.namespace.id,
                body.timesheet_id,
                self.current_user.uuid,
                hourly_rate
            )

            if not result then
                return api_response(400, nil, create_err)
            end

            return api_response(201, result.data)
        end)
    ))

    -- ============================================================
    -- INVOICE CRUD
    -- ============================================================

    -- GET /api/v2/invoices - List invoices
    app:get("/api/v2/invoices", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = {
                page = tonumber(self.params.page) or 1,
                perPage = tonumber(self.params.perPage) or 20,
                status = self.params.status,
                search = self.params.search or self.params.q,
                from_date = self.params.from_date,
                to_date = self.params.to_date,
                owner_user_uuid = self.params.owner_user_uuid
            }

            local result = InvoiceQueries.list(self.namespace.id, params)

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.data,
                    meta = {
                        total = result.total,
                        page = result.page,
                        perPage = result.perPage,
                        totalPages = math.ceil(result.total / result.perPage)
                    }
                }
            }
        end)
    ))

    -- POST /api/v2/invoices - Create invoice
    app:post("/api/v2/invoices", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            -- Require at least customer_name or account_id
            if (not body.customer_name or body.customer_name == "") and
               (not body.account_id or body.account_id == "") then
                return api_response(400, nil, "customer_name or account_id is required")
            end

            body.namespace_id = self.namespace.id
            body.owner_user_uuid = self.current_user.uuid

            -- Parse line_items if passed as JSON string
            if body.line_items and type(body.line_items) == "string" then
                local ok, items = pcall(cjson.decode, body.line_items)
                if ok then
                    body.line_items = items
                else
                    body.line_items = nil
                end
            end

            local result = InvoiceQueries.create(body)
            return api_response(201, result.data)
        end)
    ))

    -- GET /api/v2/invoices/:uuid - Get invoice with line items and payments
    app:get("/api/v2/invoices/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local invoice = InvoiceQueries.get(self.params.uuid)
            if not invoice then
                return api_response(404, nil, "Invoice not found")
            end
            return api_response(200, invoice)
        end)
    ))

    -- PUT /api/v2/invoices/:uuid - Update invoice
    app:put("/api/v2/invoices/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            local invoice, err = InvoiceQueries.update(self.params.uuid, body)
            if not invoice then
                local status = err == "Invoice not found" and 404 or 400
                return api_response(status, nil, err)
            end
            return api_response(200, invoice)
        end)
    ))

    -- DELETE /api/v2/invoices/:uuid - Soft delete (draft only)
    app:delete("/api/v2/invoices/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ok, err = InvoiceQueries.delete(self.params.uuid)
            if not ok then
                local status = err == "Invoice not found" and 404 or 400
                return api_response(status, nil, err)
            end
            return api_response(200, { message = "Invoice deleted" })
        end)
    ))

    -- ============================================================
    -- WORKFLOW
    -- ============================================================

    -- POST /api/v2/invoices/:uuid/send - Mark as sent
    app:post("/api/v2/invoices/:uuid/send", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local invoice, err = InvoiceQueries.send(self.params.uuid)
            if not invoice then
                local status = err == "Invoice not found" and 404 or 400
                return api_response(status, nil, err)
            end
            return api_response(200, invoice)
        end)
    ))

    -- POST /api/v2/invoices/:uuid/void - Void invoice
    app:post("/api/v2/invoices/:uuid/void", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local invoice, err = InvoiceQueries.void(self.params.uuid)
            if not invoice then
                local status = err == "Invoice not found" and 404 or 400
                return api_response(status, nil, err)
            end
            return api_response(200, invoice)
        end)
    ))

    -- ============================================================
    -- LINE ITEMS
    -- ============================================================

    -- POST /api/v2/invoices/:uuid/items - Add line item
    app:post("/api/v2/invoices/:uuid/items", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            -- Look up the invoice by UUID to get internal ID
            local invoice = InvoiceQueries.get(self.params.uuid)
            if not invoice then
                return api_response(404, nil, "Invoice not found")
            end

            local valid, err = validate_required(body, { "description" })
            if not valid then
                return api_response(400, nil, err)
            end

            local item = InvoiceQueries.addLineItem(invoice.internal_id, body)
            return api_response(201, item)
        end)
    ))

    -- PUT /api/v2/invoices/items/:item_uuid - Update line item
    app:put("/api/v2/invoices/items/:item_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            local item, err = InvoiceQueries.updateLineItem(self.params.item_uuid, body)
            if not item then
                return api_response(404, nil, err)
            end
            return api_response(200, item)
        end)
    ))

    -- DELETE /api/v2/invoices/items/:item_uuid - Delete line item
    app:delete("/api/v2/invoices/items/:item_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ok, err = InvoiceQueries.deleteLineItem(self.params.item_uuid)
            if not ok then
                return api_response(404, nil, err)
            end
            return api_response(200, { message = "Line item deleted" })
        end)
    ))

    -- ============================================================
    -- PAYMENTS
    -- ============================================================

    -- POST /api/v2/invoices/:uuid/payments - Record payment
    app:post("/api/v2/invoices/:uuid/payments", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            local valid, err = validate_required(body, { "amount" })
            if not valid then
                return api_response(400, nil, err)
            end

            body.invoice_uuid = self.params.uuid
            local payment, pay_err = InvoiceQueries.recordPayment(body)
            if not payment then
                return api_response(400, nil, pay_err)
            end
            return api_response(201, payment)
        end)
    ))

    -- GET /api/v2/invoices/:uuid/payments - List payments
    app:get("/api/v2/invoices/:uuid/payments", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local invoice = InvoiceQueries.get(self.params.uuid)
            if not invoice then
                return api_response(404, nil, "Invoice not found")
            end
            local payments = InvoiceQueries.getPayments(invoice.internal_id)
            return api_response(200, payments)
        end)
    ))

    -- DELETE /api/v2/invoices/payments/:payment_uuid - Delete payment
    app:delete("/api/v2/invoices/payments/:payment_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ok, err = InvoiceQueries.deletePayment(self.params.payment_uuid)
            if not ok then
                return api_response(404, nil, err)
            end
            return api_response(200, { message = "Payment deleted" })
        end)
    ))

end
