--[[
    Document Template Routes
    ========================

    API endpoints for namespace-scoped document template management,
    preview, PDF generation, and generated document tracking.

    All endpoints require JWT authentication and namespace context.

    Endpoints:
    - GET    /api/v2/templates                                  - List templates
    - POST   /api/v2/templates                                  - Create template
    - GET    /api/v2/templates/:uuid                            - Get template
    - PUT    /api/v2/templates/:uuid                            - Update template
    - DELETE /api/v2/templates/:uuid                            - Soft delete

    - POST   /api/v2/templates/:uuid/clone                     - Clone template
    - POST   /api/v2/templates/:uuid/set-default               - Set as default
    - GET    /api/v2/templates/:uuid/versions                   - Get version history
    - POST   /api/v2/templates/:uuid/restore/:version          - Restore to version

    - POST   /api/v2/templates/:uuid/preview                   - Preview with sample data
    - POST   /api/v2/templates/preview-raw                     - Preview raw HTML

    - POST   /api/v2/documents/generate/invoice/:invoice_uuid  - Generate invoice PDF
    - POST   /api/v2/documents/generate/timesheet/:timesheet_uuid - Generate timesheet PDF
    - GET    /api/v2/documents                                  - List generated documents
    - GET    /api/v2/documents/:uuid                            - Get generated document
    - POST   /api/v2/documents/:uuid/email                     - Email generated document

    - GET    /api/v2/templates/variables/:type                  - Get available variables
]]

local cjson = require("cjson.safe")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local DocumentTemplateQueries = require("queries.DocumentTemplateQueries")

-- Configure cjson
cjson.encode_empty_table_as_object(false)

-- Variable reference data
local invoice_variables = {
    "company.name", "company.logo_url", "company.address", "company.email", "company.phone",
    "invoice.number", "invoice.date", "invoice.due_date", "invoice.currency", "invoice.subtotal",
    "invoice.tax_amount", "invoice.discount_amount", "invoice.total_amount", "invoice.balance_due",
    "invoice.notes", "invoice.terms", "invoice.status",
    "client.name", "client.email", "client.address",
    "invoice.items[].description", "invoice.items[].quantity", "invoice.items[].unit_price",
    "invoice.items[].tax_rate", "invoice.items[].tax_amount", "invoice.items[].line_total",
    "theme.primary_color", "theme.secondary_color", "theme.font", "theme.footer_text"
}

local timesheet_variables = {
    "company.name", "company.logo_url", "company.address", "company.email", "company.phone",
    "employee.name", "employee.email", "employee.department",
    "timesheet.period_start", "timesheet.period_end", "timesheet.status",
    "timesheet.total_hours", "timesheet.billable_hours", "timesheet.non_billable_hours",
    "timesheet.overtime_hours", "timesheet.approval_status", "timesheet.approval_date",
    "timesheet.manager_name",
    "timesheet.entries[].date", "timesheet.entries[].project", "timesheet.entries[].task",
    "timesheet.entries[].hours", "timesheet.entries[].description", "timesheet.entries[].is_billable",
    "theme.primary_color", "theme.secondary_color", "theme.font", "theme.footer_text"
}

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

    -- Simple mustache-style template rendering
    -- Replaces {{ variable }} and {{# section }}...{{/ section }} blocks
    local function render_template(html, data)
        if not html then return "" end

        -- Replace simple variables {{ key }}
        local rendered = html:gsub("{{%s*([%w_%.]+)%s*}}", function(key)
            -- Support nested keys like "company.name"
            local value = data
            for part in key:gmatch("[^%.]+") do
                if type(value) == "table" then
                    value = value[part]
                else
                    return "{{ " .. key .. " }}"
                end
            end
            if value == nil or type(value) == "table" then
                return ""
            end
            return tostring(value)
        end)

        -- Replace section blocks {{# items }}...{{/ items }}
        rendered = rendered:gsub("{{#%s*([%w_]+)%s*}}(.-){{/%s*%1%s*}}", function(key, block)
            local list = data[key]
            if type(list) ~= "table" then
                return ""
            end
            local parts = {}
            for _, item in ipairs(list) do
                local row = block:gsub("{{%s*([%w_%.]+)%s*}}", function(inner_key)
                    local val = item
                    for part in inner_key:gmatch("[^%.]+") do
                        if type(val) == "table" then
                            val = val[part]
                        else
                            return ""
                        end
                    end
                    if val == nil or type(val) == "table" then
                        return ""
                    end
                    return tostring(val)
                end)
                table.insert(parts, row)
            end
            return table.concat(parts, "")
        end)

        return rendered
    end

    -- ============================================================
    -- VARIABLES REFERENCE (must be before :uuid routes)
    -- ============================================================

    -- GET /api/v2/templates/variables/:type - Get available variables for a template type
    app:get("/api/v2/templates/variables/:type", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local template_type = self.params.type

            if template_type == "invoice" then
                return api_response(200, {
                    type = "invoice",
                    variables = invoice_variables
                })
            elseif template_type == "timesheet" then
                return api_response(200, {
                    type = "timesheet",
                    variables = timesheet_variables
                })
            else
                return api_response(400, nil, "Unknown template type: " .. tostring(template_type) .. ". Supported types: invoice, timesheet")
            end
        end)
    ))

    -- ============================================================
    -- PREVIEW RAW (must be before :uuid routes)
    -- ============================================================

    -- POST /api/v2/templates/preview-raw - Preview raw HTML template with provided data
    app:post("/api/v2/templates/preview-raw", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            local valid, err = validate_required(body, { "template_html" })
            if not valid then
                return api_response(400, nil, err)
            end

            local data = body.data or {}
            local css = body.template_css or ""
            local html = body.template_html

            -- Try external renderer first, fall back to built-in
            local ok_renderer, TemplateRenderer = pcall(require, "lib.template-renderer")
            local rendered_html
            if ok_renderer and TemplateRenderer and TemplateRenderer.render then
                rendered_html = TemplateRenderer.render(html, data)
            else
                rendered_html = render_template(html, data)
            end

            -- Wrap with CSS if provided
            if css and css ~= "" then
                rendered_html = "<style>" .. css .. "</style>" .. rendered_html
            end

            return api_response(200, {
                rendered_html = rendered_html
            })
        end)
    ))

    -- ============================================================
    -- TEMPLATE CRUD
    -- ============================================================

    -- GET /api/v2/templates - List templates
    app:get("/api/v2/templates", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = {
                page = tonumber(self.params.page) or 1,
                perPage = tonumber(self.params.perPage) or 20,
                type = self.params.type,
                is_active = self.params.is_active,
                search = self.params.search or self.params.q
            }

            local result = DocumentTemplateQueries.list(self.namespace.id, params)

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

    -- POST /api/v2/templates - Create template
    app:post("/api/v2/templates", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            local valid, err = validate_required(body, { "name", "type", "template_html" })
            if not valid then
                return api_response(400, nil, err)
            end

            -- Validate type
            local valid_types = { invoice = true, timesheet = true, receipt = true, report = true }
            if not valid_types[body.type] then
                return api_response(400, nil, "Invalid template type. Must be one of: invoice, timesheet, receipt, report")
            end

            body.namespace_id = self.namespace.id
            body.created_by_uuid = self.current_user.uuid

            local result = DocumentTemplateQueries.create(body)
            return api_response(201, result.data)
        end)
    ))

    -- GET /api/v2/templates/:uuid - Get template
    app:get("/api/v2/templates/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local template = DocumentTemplateQueries.get(self.params.uuid)
            if not template then
                return api_response(404, nil, "Template not found")
            end
            return api_response(200, template)
        end)
    ))

    -- PUT /api/v2/templates/:uuid - Update template
    app:put("/api/v2/templates/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            body.updated_by_uuid = self.current_user.uuid

            local template, err = DocumentTemplateQueries.update(self.params.uuid, body)
            if not template then
                return api_response(404, nil, err)
            end
            return api_response(200, template)
        end)
    ))

    -- DELETE /api/v2/templates/:uuid - Soft delete
    app:delete("/api/v2/templates/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ok, err = DocumentTemplateQueries.delete(self.params.uuid)
            if not ok then
                return api_response(404, nil, err)
            end
            return api_response(200, { message = "Template deleted" })
        end)
    ))

    -- ============================================================
    -- TEMPLATE OPERATIONS
    -- ============================================================

    -- POST /api/v2/templates/:uuid/clone - Clone template
    app:post("/api/v2/templates/:uuid/clone", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            local valid, err = validate_required(body, { "name" })
            if not valid then
                return api_response(400, nil, err)
            end

            local result, clone_err = DocumentTemplateQueries.clone(self.params.uuid, body.name)
            if not result then
                return api_response(404, nil, clone_err)
            end
            return api_response(201, result.data)
        end)
    ))

    -- POST /api/v2/templates/:uuid/set-default - Set as default for its type
    app:post("/api/v2/templates/:uuid/set-default", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            -- Look up template to get its type
            local template = DocumentTemplateQueries.get(self.params.uuid)
            if not template then
                return api_response(404, nil, "Template not found")
            end

            local ok, err = DocumentTemplateQueries.setDefault(
                self.params.uuid,
                self.namespace.id,
                template.type
            )
            if not ok then
                return api_response(400, nil, err)
            end

            return api_response(200, { message = "Template set as default for " .. template.type })
        end)
    ))

    -- GET /api/v2/templates/:uuid/versions - Get version history
    app:get("/api/v2/templates/:uuid/versions", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local template = DocumentTemplateQueries.get(self.params.uuid)
            if not template then
                return api_response(404, nil, "Template not found")
            end

            local versions = DocumentTemplateQueries.getVersions(template.internal_id)
            return api_response(200, versions)
        end)
    ))

    -- POST /api/v2/templates/:uuid/restore/:version - Restore to version
    app:post("/api/v2/templates/:uuid/restore/:version", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local template = DocumentTemplateQueries.get(self.params.uuid)
            if not template then
                return api_response(404, nil, "Template not found")
            end

            local version_number = tonumber(self.params.version)
            if not version_number then
                return api_response(400, nil, "Invalid version number")
            end

            local restored, err = DocumentTemplateQueries.restoreVersion(
                template.internal_id,
                version_number
            )
            if not restored then
                return api_response(404, nil, err)
            end

            return api_response(200, restored)
        end)
    ))

    -- ============================================================
    -- PREVIEW
    -- ============================================================

    -- POST /api/v2/templates/:uuid/preview - Preview template with sample data
    app:post("/api/v2/templates/:uuid/preview", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            local template = DocumentTemplateQueries.get(self.params.uuid)
            if not template then
                return api_response(404, nil, "Template not found")
            end

            local data = body.data or {}
            local html = template.template_html
            local css = template.template_css or ""

            -- Try external renderer first, fall back to built-in
            local ok_renderer, TemplateRenderer = pcall(require, "lib.template-renderer")
            local rendered_html
            if ok_renderer and TemplateRenderer and TemplateRenderer.render then
                rendered_html = TemplateRenderer.render(html, data)
            else
                rendered_html = render_template(html, data)
            end

            -- Wrap with CSS
            if css and css ~= "" then
                rendered_html = "<style>" .. css .. "</style>" .. rendered_html
            end

            return api_response(200, {
                template_id = template.id,
                template_name = template.name,
                rendered_html = rendered_html
            })
        end)
    ))

    -- ============================================================
    -- DOCUMENT GENERATION
    -- ============================================================

    -- POST /api/v2/documents/generate/invoice/:invoice_uuid - Generate PDF for an invoice
    app:post("/api/v2/documents/generate/invoice/:invoice_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            local db_module = require("lapis.db")

            -- Fetch the invoice
            local invoice_results = db_module.query([[
                SELECT
                    i.id as internal_id, i.uuid, i.namespace_id, i.invoice_number,
                    i.status, i.customer_name, i.customer_email, i.customer_address,
                    i.invoice_date, i.due_date, i.currency, i.subtotal, i.tax_amount,
                    i.discount_amount, i.total_amount, i.amount_paid, i.balance_due,
                    i.notes, i.payment_terms
                FROM invoices i
                WHERE i.uuid = ? AND i.namespace_id = ? AND i.deleted_at IS NULL
                LIMIT 1
            ]], self.params.invoice_uuid, self.namespace.id)

            if not invoice_results or #invoice_results == 0 then
                return api_response(404, nil, "Invoice not found")
            end
            local invoice = invoice_results[1]

            -- Fetch line items
            local line_items = db_module.query([[
                SELECT description, quantity, unit_price, tax_rate, tax_amount, line_total
                FROM invoice_line_items
                WHERE invoice_id = ?
                ORDER BY sort_order ASC, id ASC
            ]], invoice.internal_id)

            -- Get template (from request body or default)
            local template
            if body.template_uuid and body.template_uuid ~= "" then
                template = DocumentTemplateQueries.get(body.template_uuid)
            else
                template = DocumentTemplateQueries.getDefault(self.namespace.id, "invoice")
            end

            if not template then
                return api_response(404, nil, "No template found. Create an invoice template or specify template_uuid.")
            end

            -- Build data context
            local data = {
                company_name = self.namespace.name or "",
                company_logo = body.company_logo_url or "",
                company_address = body.company_address or "",
                company_email = body.company_email or "",
                company_phone = body.company_phone or "",
                invoice_number = invoice.invoice_number,
                invoice_date = invoice.invoice_date,
                due_date = invoice.due_date or "",
                currency = invoice.currency or "GBP",
                client_name = invoice.customer_name or "",
                client_email = invoice.customer_email or "",
                client_address = invoice.customer_address or "",
                subtotal = invoice.subtotal or 0,
                tax_total = invoice.tax_amount or 0,
                discount = invoice.discount_amount or 0,
                total = invoice.total_amount or 0,
                balance_due = invoice.balance_due or 0,
                notes = invoice.notes or "",
                payment_terms = invoice.payment_terms or "",
                status = invoice.status or "",
                line_items = line_items or {}
            }

            -- Render HTML
            local ok_renderer, TemplateRenderer = pcall(require, "lib.template-renderer")
            local rendered_html
            if ok_renderer and TemplateRenderer and TemplateRenderer.render then
                rendered_html = TemplateRenderer.render(template.template_html, data)
            else
                rendered_html = render_template(template.template_html, data)
            end

            -- Add CSS
            local css = template.template_css or ""
            if css ~= "" then
                rendered_html = "<style>" .. css .. "</style>" .. rendered_html
            end

            -- Generate PDF if pdf-service available
            local ok_pdf, PdfService = pcall(require, "lib.pdf-service")
            local file_path = nil
            local file_size = nil

            if ok_pdf and PdfService and PdfService.generateFromHtml then
                local pdf_result = PdfService.generateFromHtml(rendered_html, {
                    page_size = template.page_size or "A4",
                    orientation = template.page_orientation or "portrait",
                    margin_top = template.margin_top or "20mm",
                    margin_bottom = template.margin_bottom or "20mm",
                    margin_left = template.margin_left or "15mm",
                    margin_right = template.margin_right or "15mm",
                    header_html = template.header_html,
                    footer_html = template.footer_html
                })
                if pdf_result then
                    file_path = pdf_result.file_path
                    file_size = pdf_result.file_size
                end
            end

            -- Log the generation
            local generation = DocumentTemplateQueries.logGeneration({
                namespace_id = self.namespace.id,
                template_id = template.internal_id,
                document_type = "invoice",
                entity_type = "invoice",
                entity_id = self.params.invoice_uuid,
                file_path = file_path,
                file_size = file_size,
                rendered_html = rendered_html,
                generated_by_uuid = self.current_user.uuid,
                metadata = {
                    invoice_number = invoice.invoice_number,
                    customer_name = invoice.customer_name,
                    total_amount = invoice.total_amount,
                    template_name = template.name
                }
            })

            return api_response(200, {
                document = generation.data,
                rendered_html = rendered_html,
                file_path = file_path,
                pdf_available = (file_path ~= nil)
            })
        end)
    ))

    -- POST /api/v2/documents/generate/timesheet/:timesheet_uuid - Generate PDF for a timesheet
    app:post("/api/v2/documents/generate/timesheet/:timesheet_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            local db_module = require("lapis.db")

            -- Fetch the timesheet
            local timesheet_results = db_module.query([[
                SELECT
                    t.id as internal_id, t.uuid, t.namespace_id, t.user_uuid,
                    t.period_start, t.period_end, t.status,
                    t.total_hours, t.billable_hours,
                    t.notes, t.approved_by_uuid, t.approved_at
                FROM timesheets t
                WHERE t.uuid = ? AND t.namespace_id = ?
                LIMIT 1
            ]], self.params.timesheet_uuid, self.namespace.id)

            if not timesheet_results or #timesheet_results == 0 then
                return api_response(404, nil, "Timesheet not found")
            end
            local timesheet = timesheet_results[1]

            -- Fetch timesheet entries
            local entries = db_module.query([[
                SELECT entry_date as date, project_name as project, task_name as task,
                       hours, description, is_billable
                FROM timesheet_entries
                WHERE timesheet_id = ?
                ORDER BY entry_date ASC, id ASC
            ]], timesheet.internal_id)

            -- Get template (from request body or default)
            local template
            if body.template_uuid and body.template_uuid ~= "" then
                template = DocumentTemplateQueries.get(body.template_uuid)
            else
                template = DocumentTemplateQueries.getDefault(self.namespace.id, "timesheet")
            end

            if not template then
                return api_response(404, nil, "No template found. Create a timesheet template or specify template_uuid.")
            end

            -- Calculate hours
            local total_hours = tonumber(timesheet.total_hours) or 0
            local billable_hours = tonumber(timesheet.billable_hours) or 0
            local non_billable_hours = total_hours - billable_hours
            local overtime_hours = 0
            if total_hours > 40 then
                overtime_hours = total_hours - 40
            end

            -- Build data context
            local data = {
                company_name = self.namespace.name or "",
                employee_name = body.employee_name or timesheet.user_uuid or "",
                period_start = timesheet.period_start or "",
                period_end = timesheet.period_end or "",
                manager_name = body.manager_name or "",
                department = body.department or "",
                entries = entries or {},
                total_hours = total_hours,
                billable_hours = billable_hours,
                non_billable_hours = non_billable_hours,
                overtime_hours = overtime_hours,
                approval_status = timesheet.status or "pending",
                approval_date = timesheet.approved_at or ""
            }

            -- Render HTML
            local ok_renderer, TemplateRenderer = pcall(require, "lib.template-renderer")
            local rendered_html
            if ok_renderer and TemplateRenderer and TemplateRenderer.render then
                rendered_html = TemplateRenderer.render(template.template_html, data)
            else
                rendered_html = render_template(template.template_html, data)
            end

            -- Add CSS
            local css = template.template_css or ""
            if css ~= "" then
                rendered_html = "<style>" .. css .. "</style>" .. rendered_html
            end

            -- Generate PDF if pdf-service available
            local ok_pdf, PdfService = pcall(require, "lib.pdf-service")
            local file_path = nil
            local file_size = nil

            if ok_pdf and PdfService and PdfService.generateFromHtml then
                local pdf_result = PdfService.generateFromHtml(rendered_html, {
                    page_size = template.page_size or "A4",
                    orientation = template.page_orientation or "portrait",
                    margin_top = template.margin_top or "20mm",
                    margin_bottom = template.margin_bottom or "20mm",
                    margin_left = template.margin_left or "15mm",
                    margin_right = template.margin_right or "15mm",
                    header_html = template.header_html,
                    footer_html = template.footer_html
                })
                if pdf_result then
                    file_path = pdf_result.file_path
                    file_size = pdf_result.file_size
                end
            end

            -- Log the generation
            local generation = DocumentTemplateQueries.logGeneration({
                namespace_id = self.namespace.id,
                template_id = template.internal_id,
                document_type = "timesheet",
                entity_type = "timesheet",
                entity_id = self.params.timesheet_uuid,
                file_path = file_path,
                file_size = file_size,
                rendered_html = rendered_html,
                generated_by_uuid = self.current_user.uuid,
                metadata = {
                    period = (timesheet.period_start or "") .. " - " .. (timesheet.period_end or ""),
                    total_hours = total_hours,
                    status = timesheet.status,
                    template_name = template.name
                }
            })

            return api_response(200, {
                document = generation.data,
                rendered_html = rendered_html,
                file_path = file_path,
                pdf_available = (file_path ~= nil)
            })
        end)
    ))

    -- ============================================================
    -- GENERATED DOCUMENTS
    -- ============================================================

    -- GET /api/v2/documents - List generated documents
    app:get("/api/v2/documents", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local params = {
                page = tonumber(self.params.page) or 1,
                perPage = tonumber(self.params.perPage) or 20,
                document_type = self.params.document_type,
                entity_type = self.params.entity_type,
                entity_id = self.params.entity_id
            }

            local result = DocumentTemplateQueries.getGeneratedDocuments(self.namespace.id, params)

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

    -- GET /api/v2/documents/:uuid - Get generated document details
    app:get("/api/v2/documents/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local doc = DocumentTemplateQueries.getGeneratedDocument(self.params.uuid)
            if not doc then
                return api_response(404, nil, "Generated document not found")
            end
            return api_response(200, doc)
        end)
    ))

    -- POST /api/v2/documents/:uuid/email - Email generated document
    app:post("/api/v2/documents/:uuid/email", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()

            local valid, err = validate_required(body, { "to" })
            if not valid then
                return api_response(400, nil, err)
            end

            -- Get the generated document
            local doc = DocumentTemplateQueries.getGeneratedDocument(self.params.uuid)
            if not doc then
                return api_response(404, nil, "Generated document not found")
            end

            -- Try to send email
            local ok_mail, MailHelper = pcall(require, "helper.mail")
            if not ok_mail or not MailHelper then
                return api_response(503, nil, "Email service is not available")
            end

            local subject = body.subject or ("Document: " .. (doc.document_type or "document"))
            local email_body = body.message or "Please find the attached document."

            local send_ok, send_err = pcall(function()
                if MailHelper.send then
                    MailHelper.send({
                        to = body.to,
                        subject = subject,
                        body = email_body,
                        html = doc.rendered_html,
                        attachment_path = doc.file_path
                    })
                elseif MailHelper.sendMail then
                    MailHelper.sendMail({
                        to = body.to,
                        subject = subject,
                        body = email_body,
                        html = doc.rendered_html,
                        attachment_path = doc.file_path
                    })
                end
            end)

            if not send_ok then
                return api_response(500, nil, "Failed to send email: " .. tostring(send_err))
            end

            -- Mark as emailed
            DocumentTemplateQueries.markEmailed(self.params.uuid, body.to)

            return api_response(200, {
                message = "Document emailed successfully",
                emailed_to = body.to
            })
        end)
    ))

end
