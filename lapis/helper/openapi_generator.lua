--[[
    Dynamic OpenAPI/Swagger Generator
    =================================

    Auto-discovers routes from the routes/ directory and generates
    a complete OpenAPI 3.0 specification. Caches the result for 60 seconds.

    Usage:
        local openapi = require("helper.openapi_generator")
        local spec = openapi.generate()
]]

local _M = {}

-- ============================================================
-- CACHING
-- ============================================================

local cached_spec = nil
local cache_timestamp = 0
local CACHE_TTL = 60 -- seconds

-- ============================================================
-- HELPERS
-- ============================================================

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

--- Convert a route filename to a human-readable tag.
-- Groups related files under a single tag (e.g. crm-accounts -> CRM).
local TAG_GROUPS = {
    ["crm"]      = "CRM",
    ["chat"]     = "Chat",
    ["kanban"]   = "Kanban",
    ["delivery"] = "Delivery",
    ["tax"]      = "Tax Copilot",
    ["order"]    = "Orders",
}

local EXACT_TAG_MAP = {
    ["auth"]                    = "Authentication",
    ["users"]                   = "Users",
    ["groups"]                  = "Groups",
    ["roles"]                   = "Roles",
    ["permissions"]             = "Permissions",
    ["products"]                = "Products",
    ["categories"]              = "Categories",
    ["orders"]                  = "Orders",
    ["cart"]                    = "Cart",
    ["payments"]                = "Payments",
    ["addresses"]               = "Addresses",
    ["stores"]                  = "Stores",
    ["storeproducts"]           = "Store Products",
    ["customers"]               = "Customers",
    ["orderitems"]              = "Order Items",
    ["checkout"]                = "Checkout",
    ["checkout_enhanced"]       = "Checkout",
    ["variants"]                = "Variants",
    ["stripe-webhook"]          = "Payments",
    ["order_management"]        = "Orders",
    ["order-status"]            = "Orders",
    ["buyer-orders"]            = "Orders",
    ["public-store"]            = "Public Store",
    ["tenants"]                 = "Tenants",
    ["invoices"]                = "Invoices",
    ["document-templates"]      = "Document Templates",
    ["timesheets"]              = "Timesheets",
    ["documents"]               = "Documents",
    ["secrets"]                 = "Secrets",
    ["secret-vault"]            = "Secret Vault",
    ["tags"]                    = "Tags",
    ["templates"]               = "Templates",
    ["projects"]                = "Projects",
    ["enquiries"]               = "Enquiries",
    ["register"]                = "Registration",
    ["namespaces"]              = "Namespaces",
    ["email"]                   = "Email",
    ["module"]                  = "Modules",
    ["menu"]                    = "Menu",
    ["pin"]                     = "Pin",
    ["notifications"]           = "Notifications",
    ["device-tokens"]           = "Notifications",
    ["test-notification"]       = "Notifications",
    ["services"]                = "Services",
    ["bank_transactions"]       = "Bank Transactions",
    ["profile-builder"]         = "Profile Builder",
}

local function route_name_to_tag(route_name)
    -- Exact match first
    if EXACT_TAG_MAP[route_name] then
        return EXACT_TAG_MAP[route_name]
    end
    -- Prefix group match
    for prefix, tag in pairs(TAG_GROUPS) do
        if route_name:match("^" .. prefix) then
            return tag
        end
    end
    -- Fallback: humanize the route name
    local tag = route_name:gsub("[-_]", " ")
    tag = tag:gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end)
    return tag
end

--- Convert Lapis path params (:uuid) to OpenAPI style ({uuid}).
local function lapis_to_openapi_path(path)
    return (path:gsub(":([%w_]+)", "{%1}"))
end

--- Extract path parameter names from a Lapis-style route.
local function extract_path_params(path)
    local params = {}
    for param in path:gmatch(":([%w_]+)") do
        table.insert(params, param)
    end
    return params
end

--- Determine if a path is likely public (no auth required).
local PUBLIC_PATHS = {
    ["/auth/login"]              = true,
    ["/auth/register"]           = true,
    ["/auth/forgot-password"]    = true,
    ["/auth/reset-password"]     = true,
    ["/auth/verify-email"]       = true,
    ["/auth/resend-verification"]= true,
    ["/auth/refresh"]            = true,
    ["/auth/2fa/verify"]         = true,
    ["/auth/2fa/resend"]         = true,
    ["/auth/google"]             = true,
    ["/auth/google/callback"]    = true,
    ["/auth/oauth/validate"]     = true,
    ["/auth/hmrc/callback"]      = true,
    ["/auth/logout"]             = true,
    ["/health"]                  = true,
    ["/ready"]                   = true,
    ["/live"]                    = true,
}

local function is_public_path(path)
    if PUBLIC_PATHS[path] then return true end
    if path:match("^/api/v2/public/") then return true end
    if path:match("^/api/v2/delivery/fee%-estimate") then return true end
    if path:match("^/api/v2/delivery/pricing%-config$") then return true end
    return false
end

--- Build parameter description based on name.
local PARAM_DESCRIPTIONS = {
    uuid          = "Unique identifier (UUID)",
    id            = "Resource ID",
    item_uuid     = "Line item UUID",
    entry_uuid    = "Entry UUID",
    payment_uuid  = "Payment UUID",
    pipeline_uuid = "Pipeline UUID",
    channel_id    = "Channel ID",
    message_id    = "Message ID",
    project_id    = "Project ID",
    board_id      = "Board ID",
    task_id       = "Task ID",
    label_id      = "Label ID",
    sprint_id     = "Sprint ID",
    invoice_uuid  = "Invoice UUID",
    timesheet_uuid= "Timesheet UUID",
    version       = "Version number",
    type          = "Resource type",
}

local function param_description(name)
    return PARAM_DESCRIPTIONS[name] or (name:gsub("_", " "):gsub("^%l", string.upper))
end

local function param_schema(name)
    if name == "id" or name == "version" then
        return { type = "integer" }
    end
    if name:match("uuid$") then
        return { type = "string", format = "uuid" }
    end
    return { type = "string" }
end

--- Build OpenAPI path parameters list from path param names.
local function build_path_parameters(path_params)
    local params = {}
    for _, p in ipairs(path_params) do
        table.insert(params, {
            name = p,
            ["in"] = "path",
            required = true,
            description = param_description(p),
            schema = param_schema(p),
        })
    end
    return params
end

--- Build common query parameters for GET list endpoints.
local function build_list_query_params(path, tag)
    local params = {}

    -- Only add pagination/filtering to list endpoints (no path params at the end)
    -- Skip if path ends with a parameter like {uuid}
    if path:match("{[%w_]+}$") then return params end

    -- Standard pagination
    table.insert(params, {
        name = "page",
        ["in"] = "query",
        required = false,
        description = "Page number",
        schema = { type = "integer", default = 1 },
    })
    table.insert(params, {
        name = "per_page",
        ["in"] = "query",
        required = false,
        description = "Items per page",
        schema = { type = "integer", default = 20 },
    })

    -- Search for most list endpoints
    if not path:match("/stats$") and not path:match("/summary$")
       and not path:match("/approval%-queue$") and not path:match("/variables/") then
        table.insert(params, {
            name = "search",
            ["in"] = "query",
            required = false,
            description = "Search query string",
            schema = { type = "string" },
        })
    end

    -- Status filter for many entities
    if tag == "CRM" or tag == "Invoices" or tag == "Timesheets"
       or tag == "Orders" or tag == "Kanban" or tag == "Delivery" then
        table.insert(params, {
            name = "status",
            ["in"] = "query",
            required = false,
            description = "Filter by status",
            schema = { type = "string" },
        })
    end

    return params
end

-- ============================================================
-- ENTITY SCHEMAS
-- ============================================================

local function base_entity_props()
    return {
        id = { type = "integer", description = "Internal ID" },
        uuid = { type = "string", format = "uuid" },
        created_at = { type = "string", format = "date-time" },
        updated_at = { type = "string", format = "date-time" },
    }
end

local function merge_props(base, extra)
    for k, v in pairs(extra) do
        base[k] = v
    end
    return base
end

local ENTITY_SCHEMAS = {}

local function define_entity(name, extra_props)
    ENTITY_SCHEMAS[name] = {
        type = "object",
        properties = merge_props(base_entity_props(), extra_props),
    }
end

-- CRM
define_entity("CrmAccount", {
    name             = { type = "string" },
    industry         = { type = "string" },
    website          = { type = "string" },
    phone            = { type = "string" },
    email            = { type = "string", format = "email" },
    address_line1    = { type = "string" },
    address_line2    = { type = "string" },
    city             = { type = "string" },
    state            = { type = "string" },
    postal_code      = { type = "string" },
    country          = { type = "string" },
    annual_revenue   = { type = "number" },
    employee_count   = { type = "integer" },
    owner_user_uuid  = { type = "string", format = "uuid" },
    status           = { type = "string", enum = { "active", "inactive", "prospect", "churned" } },
    metadata         = { type = "object" },
})

define_entity("CrmContact", {
    first_name       = { type = "string" },
    last_name        = { type = "string" },
    email            = { type = "string", format = "email" },
    phone            = { type = "string" },
    title            = { type = "string" },
    department       = { type = "string" },
    account_uuid     = { type = "string", format = "uuid" },
    owner_user_uuid  = { type = "string", format = "uuid" },
    status           = { type = "string", enum = { "active", "inactive" } },
    metadata         = { type = "object" },
})

define_entity("CrmDeal", {
    name             = { type = "string" },
    value            = { type = "number" },
    currency         = { type = "string", default = "GBP" },
    stage            = { type = "string" },
    pipeline_uuid    = { type = "string", format = "uuid" },
    account_uuid     = { type = "string", format = "uuid" },
    contact_uuid     = { type = "string", format = "uuid" },
    owner_user_uuid  = { type = "string", format = "uuid" },
    expected_close   = { type = "string", format = "date" },
    probability      = { type = "integer" },
    status           = { type = "string", enum = { "open", "won", "lost" } },
    metadata         = { type = "object" },
})

define_entity("CrmPipeline", {
    name             = { type = "string" },
    description      = { type = "string" },
    stages           = { type = "array", items = { type = "object", properties = {
        name = { type = "string" },
        order_position = { type = "integer" },
        probability = { type = "integer" },
    }}},
    is_default       = { type = "boolean" },
    status           = { type = "string", enum = { "active", "inactive" } },
})

define_entity("CrmActivity", {
    type              = { type = "string", enum = { "call", "email", "meeting", "note", "task" } },
    subject           = { type = "string" },
    description       = { type = "string" },
    activity_date     = { type = "string", format = "date-time" },
    duration_minutes  = { type = "integer" },
    account_uuid      = { type = "string", format = "uuid" },
    contact_uuid      = { type = "string", format = "uuid" },
    deal_uuid         = { type = "string", format = "uuid" },
    owner_user_uuid   = { type = "string", format = "uuid" },
    status            = { type = "string", enum = { "planned", "completed", "cancelled" } },
})

-- Timesheets
define_entity("Timesheet", {
    title            = { type = "string" },
    description      = { type = "string" },
    user_uuid        = { type = "string", format = "uuid" },
    period_start     = { type = "string", format = "date" },
    period_end       = { type = "string", format = "date" },
    status           = { type = "string", enum = { "draft", "submitted", "approved", "rejected" } },
    total_hours      = { type = "number" },
    billable_hours   = { type = "number" },
    submitted_at     = { type = "string", format = "date-time" },
    approved_at      = { type = "string", format = "date-time" },
    approved_by_uuid = { type = "string", format = "uuid" },
    rejection_reason = { type = "string" },
    entries          = { type = "array", items = { ["$ref"] = "#/components/schemas/TimesheetEntry" } },
})

define_entity("TimesheetEntry", {
    timesheet_id     = { type = "integer" },
    entry_date       = { type = "string", format = "date" },
    hours            = { type = "number" },
    billable         = { type = "boolean" },
    description      = { type = "string" },
    project_uuid     = { type = "string", format = "uuid" },
    category         = { type = "string" },
    task_reference   = { type = "string" },
})

-- Invoices
define_entity("Invoice", {
    invoice_number   = { type = "string" },
    status           = { type = "string", enum = { "draft", "sent", "paid", "partially_paid", "overdue", "cancelled", "void" } },
    customer_name    = { type = "string" },
    customer_email   = { type = "string", format = "email" },
    account_id       = { type = "string" },
    issue_date       = { type = "string", format = "date" },
    due_date         = { type = "string", format = "date" },
    currency         = { type = "string", default = "GBP" },
    subtotal         = { type = "number" },
    tax_amount       = { type = "number" },
    discount_amount  = { type = "number" },
    total_amount     = { type = "number" },
    amount_paid      = { type = "number" },
    balance_due      = { type = "number" },
    notes            = { type = "string" },
    terms            = { type = "string" },
    owner_user_uuid  = { type = "string", format = "uuid" },
    line_items       = { type = "array", items = { ["$ref"] = "#/components/schemas/InvoiceLineItem" } },
    payments         = { type = "array", items = { ["$ref"] = "#/components/schemas/InvoicePayment" } },
})

define_entity("InvoiceLineItem", {
    invoice_id       = { type = "integer" },
    description      = { type = "string" },
    quantity         = { type = "number", default = 1 },
    unit_price       = { type = "number" },
    tax_rate         = { type = "number" },
    tax_amount       = { type = "number" },
    discount         = { type = "number" },
    line_total       = { type = "number" },
    sort_order       = { type = "integer" },
})

define_entity("InvoicePayment", {
    invoice_id       = { type = "integer" },
    amount           = { type = "number" },
    payment_date     = { type = "string", format = "date" },
    payment_method   = { type = "string", enum = { "bank_transfer", "card", "cash", "cheque", "other" } },
    reference        = { type = "string" },
    notes            = { type = "string" },
})

define_entity("TaxRate", {
    name             = { type = "string" },
    rate             = { type = "number" },
    description      = { type = "string" },
    is_default       = { type = "boolean" },
    is_active        = { type = "boolean" },
})

-- Document Templates
define_entity("DocumentTemplate", {
    name             = { type = "string" },
    type             = { type = "string", enum = { "invoice", "timesheet", "quote", "receipt", "report" } },
    description      = { type = "string" },
    html_content     = { type = "string" },
    css_content      = { type = "string" },
    header_html      = { type = "string" },
    footer_html      = { type = "string" },
    variables        = { type = "object" },
    is_default       = { type = "boolean" },
    is_active        = { type = "boolean" },
    version          = { type = "integer" },
})

define_entity("GeneratedDocument", {
    template_uuid    = { type = "string", format = "uuid" },
    source_type      = { type = "string" },
    source_uuid      = { type = "string", format = "uuid" },
    file_path        = { type = "string" },
    file_size        = { type = "integer" },
    format           = { type = "string", enum = { "pdf", "html" } },
    status           = { type = "string" },
})

-- ============================================================
-- OPERATION BUILDER
-- ============================================================

--- Infer a short summary for an operation based on method + path.
local function build_summary(method, path, tag)
    -- Extract the last meaningful segment
    local segments = {}
    for seg in path:gmatch("[^/]+") do
        if not seg:match("^{") and seg ~= "api" and seg ~= "v2" then
            table.insert(segments, seg)
        end
    end

    local resource = segments[#segments] or "resource"
    -- Humanize: replace hyphens/underscores
    resource = resource:gsub("[-_]", " ")

    local has_path_param = path:match("{[%w_]+}$") or path:match("{[%w_]+}/[%w_-]+$")

    -- Action endpoints like /approve, /reject, /send
    local action_segment = path:match("/(%w+)$")
    local parent_param = path:match("{(%w+)}/(%w+)$")

    if method == "get" then
        if has_path_param then
            return "Get " .. resource
        else
            return "List " .. resource
        end
    elseif method == "post" then
        if action_segment and parent_param then
            return action_segment:sub(1,1):upper() .. action_segment:sub(2) .. " " .. resource
        elseif path:match("/from%-timesheet$") then
            return "Create invoice from timesheet"
        elseif path:match("/preview%-raw$") then
            return "Preview raw HTML template"
        elseif path:match("/clone$") then
            return "Clone template"
        elseif path:match("/set%-default$") then
            return "Set template as default"
        elseif path:match("/send$") then
            return "Send invoice"
        elseif path:match("/void$") then
            return "Void invoice"
        elseif path:match("/submit$") then
            return "Submit timesheet"
        elseif path:match("/approve$") then
            return "Approve timesheet"
        elseif path:match("/reject$") then
            return "Reject timesheet"
        elseif path:match("/reopen$") then
            return "Reopen timesheet"
        elseif path:match("/email$") then
            return "Email document"
        elseif path:match("/preview$") then
            return "Preview template"
        elseif path:match("/restore/") then
            return "Restore template version"
        elseif path:match("generate/invoice") then
            return "Generate invoice PDF"
        elseif path:match("generate/timesheet") then
            return "Generate timesheet PDF"
        else
            return "Create " .. resource
        end
    elseif method == "put" then
        return "Update " .. resource
    elseif method == "delete" then
        return "Delete " .. resource
    end
    return method:upper() .. " " .. resource
end

--- Determine the entity schema ref name based on tag and path.
local function infer_schema_ref(path, tag)
    if path:match("/crm/accounts") then return "CrmAccount" end
    if path:match("/crm/contacts") then return "CrmContact" end
    if path:match("/crm/deals") then return "CrmDeal" end
    if path:match("/crm/pipelines") then return "CrmPipeline" end
    if path:match("/crm/activities") then return "CrmActivity" end
    if path:match("/crm/dashboard") then return nil end
    if path:match("/timesheets/entries") or path:match("/timesheets/[^/]+/entries") then return "TimesheetEntry" end
    if path:match("/timesheets") then return "Timesheet" end
    if path:match("/invoices/tax%-rates") then return "TaxRate" end
    if path:match("/invoices/items") or path:match("/invoices/[^/]+/items") then return "InvoiceLineItem" end
    if path:match("/invoices/payments") or path:match("/invoices/[^/]+/payments") then return "InvoicePayment" end
    if path:match("/invoices") then return "Invoice" end
    if path:match("/templates/[^/]+/versions") then return nil end
    if path:match("/templates/variables") then return nil end
    if path:match("/templates/preview%-raw") then return nil end
    if path:match("/documents/generate") then return "GeneratedDocument" end
    if path:match("/documents") and not path:match("/document%-templates") then return "GeneratedDocument" end
    if path:match("/templates") or path:match("/document%-templates") then return "DocumentTemplate" end
    return nil
end

--- Build the request body schema for POST/PUT based on the entity.
local function build_request_body(method, path, tag)
    if method ~= "post" and method ~= "put" then return nil end

    -- Action endpoints typically have minimal or no body
    local action_paths = { "send", "void", "submit", "approve", "reopen", "clone", "set%-default" }
    for _, action in ipairs(action_paths) do
        if path:match("/" .. action .. "$") then
            -- Some actions accept optional body
            if action == "approve" or action == "reject" then
                return {
                    required = false,
                    content = {
                        ["application/json"] = {
                            schema = {
                                type = "object",
                                properties = {
                                    comments = { type = "string", description = "Optional comments" },
                                    reason = { type = "string", description = "Reason (required for rejection)" },
                                },
                            },
                        },
                    },
                }
            end
            return nil
        end
    end

    -- Reject requires reason
    if path:match("/reject$") then
        return {
            required = true,
            content = {
                ["application/json"] = {
                    schema = {
                        type = "object",
                        required = { "reason" },
                        properties = {
                            reason = { type = "string" },
                            comments = { type = "string" },
                        },
                    },
                },
            },
        }
    end

    -- Special: from-timesheet
    if path:match("/from%-timesheet$") then
        return {
            required = true,
            content = {
                ["application/json"] = {
                    schema = {
                        type = "object",
                        required = { "timesheet_id", "hourly_rate" },
                        properties = {
                            timesheet_id = { type = "integer", description = "Timesheet internal ID" },
                            hourly_rate = { type = "number", description = "Rate per hour" },
                        },
                    },
                },
            },
        }
    end

    -- Special: preview raw
    if path:match("/preview%-raw$") then
        return {
            required = true,
            content = {
                ["application/json"] = {
                    schema = {
                        type = "object",
                        properties = {
                            html_content = { type = "string" },
                            css_content = { type = "string" },
                            variables = { type = "object" },
                        },
                    },
                },
            },
        }
    end

    -- Special: preview
    if path:match("/preview$") then
        return {
            required = false,
            content = {
                ["application/json"] = {
                    schema = {
                        type = "object",
                        properties = {
                            sample_data = { type = "object", description = "Sample data for template preview" },
                        },
                    },
                },
            },
        }
    end

    -- Special: email document
    if path:match("/email$") then
        return {
            required = true,
            content = {
                ["application/json"] = {
                    schema = {
                        type = "object",
                        required = { "to" },
                        properties = {
                            to = { type = "string", format = "email" },
                            subject = { type = "string" },
                            message = { type = "string" },
                        },
                    },
                },
            },
        }
    end

    -- General entity-based request body
    local schema_ref = infer_schema_ref(path, tag)
    if schema_ref and ENTITY_SCHEMAS[schema_ref] then
        return {
            required = true,
            content = {
                ["application/json"] = {
                    schema = { ["$ref"] = "#/components/schemas/" .. schema_ref },
                },
            },
        }
    end

    -- Fallback: generic object
    return {
        required = true,
        content = {
            ["application/json"] = {
                schema = { type = "object" },
            },
        },
    }
end

--- Build the responses block.
local function build_responses(method, path, tag)
    local schema_ref = infer_schema_ref(path, tag)
    local is_list = method == "get" and not path:match("{[%w_]+}$")
        and not path:match("/stats$") and not path:match("/summary$")
        and not path:match("/variables/")

    local success_code = "200"
    if method == "post" then
        -- Actions on existing resources still return 200
        if not path:match("/$") and (path:match("{") or path:match("/from%-")
            or path:match("/preview") or path:match("/generate")) then
            success_code = "200"
        else
            success_code = "201"
        end
    end

    -- For POST that creates something new on a collection endpoint
    if method == "post" and not path:match("{") and not path:match("/send$")
       and not path:match("/void$") and not path:match("/submit$")
       and not path:match("/approve$") and not path:match("/reject$")
       and not path:match("/reopen$") and not path:match("/clone$")
       and not path:match("/set%-default$") and not path:match("/preview")
       and not path:match("/email$") then
        success_code = "201"
    end

    local data_schema
    if is_list and schema_ref then
        data_schema = {
            type = "array",
            items = { ["$ref"] = "#/components/schemas/" .. schema_ref },
        }
    elseif schema_ref then
        data_schema = { ["$ref"] = "#/components/schemas/" .. schema_ref }
    else
        data_schema = { type = "object" }
    end

    local success_schema = {
        type = "object",
        properties = {
            success = { type = "boolean", example = true },
            data = data_schema,
        },
    }

    if is_list then
        success_schema.properties.meta = {
            type = "object",
            properties = {
                total      = { type = "integer" },
                page       = { type = "integer" },
                per_page   = { type = "integer" },
                total_pages= { type = "integer" },
            },
        }
    end

    local responses = {
        [success_code] = {
            description = method == "delete" and "Successfully deleted" or "Successful operation",
            content = {
                ["application/json"] = {
                    schema = success_schema,
                },
            },
        },
        ["401"] = {
            description = "Unauthorized",
            content = {
                ["application/json"] = {
                    schema = { ["$ref"] = "#/components/schemas/Error" },
                },
            },
        },
    }

    -- Add 404 for single-resource endpoints
    if path:match("{[%w_]+}") then
        responses["404"] = {
            description = "Resource not found",
            content = {
                ["application/json"] = {
                    schema = { ["$ref"] = "#/components/schemas/Error" },
                },
            },
        }
    end

    -- Add 400 for write operations
    if method == "post" or method == "put" then
        responses["400"] = {
            description = "Bad request / validation error",
            content = {
                ["application/json"] = {
                    schema = { ["$ref"] = "#/components/schemas/Error" },
                },
            },
        }
    end

    return responses
end

--- Build a complete operation object for a discovered endpoint.
local function build_operation(method, path, tag)
    local openapi_path = lapis_to_openapi_path(path)
    local path_params = extract_path_params(path)
    local parameters = build_path_parameters(path_params)

    -- Add query params for GET list endpoints
    if method == "get" then
        local query_params = build_list_query_params(openapi_path, tag)
        for _, qp in ipairs(query_params) do
            table.insert(parameters, qp)
        end
    end

    local operation = {
        tags = { tag },
        summary = build_summary(method, openapi_path, tag),
        operationId = method .. "_" .. path:gsub("[/:-]", "_"):gsub("__+", "_"),
        parameters = #parameters > 0 and parameters or nil,
        requestBody = build_request_body(method, path, tag),
        responses = build_responses(method, path, tag),
    }

    -- Add security requirement unless public
    if not is_public_path(path) then
        operation.security = { { BearerAuth = {} } }
    end

    return operation
end

-- ============================================================
-- ROUTE DISCOVERY
-- ============================================================

local function discover_routes()
    -- Try container path first, then local development path
    local routes_dirs = { "/app/routes", "./routes" }
    local routes_dir = nil

    for _, dir in ipairs(routes_dirs) do
        local test = io.open(dir, "r")
        if test then
            test:close()
            routes_dir = dir
            break
        end
        -- Try with ls
        local h = io.popen("ls " .. dir .. "/*.lua 2>/dev/null | head -1")
        if h then
            local line = h:read("*l")
            h:close()
            if line and line ~= "" then
                routes_dir = dir
                break
            end
        end
    end

    if not routes_dir then
        routes_dir = "/app/routes" -- fallback default
    end

    local paths = {}
    local discovered_tags = {}

    local handle = io.popen("ls " .. routes_dir .. "/*.lua 2>/dev/null")
    if not handle then return paths, discovered_tags end

    for file in handle:lines() do
        local content = read_file(file)
        if content then
            local route_name = file:match(".*/(.*)%.lua$")
            local tag = route_name_to_tag(route_name)
            discovered_tags[tag] = true

            -- Parse app:method("path", ...) patterns
            -- Handle both quoted styles: app:get("/path" and app:get('/path'
            for method, route_path in content:gmatch('app:(%w+)%(["\']([^"\']+)["\']') do
                method = method:lower()
                if method == "get" or method == "post" or method == "put" or method == "delete" then
                    local openapi_path = lapis_to_openapi_path(route_path)
                    paths[openapi_path] = paths[openapi_path] or {}
                    paths[openapi_path][method] = build_operation(method, route_path, tag)
                end
            end
        end
    end

    handle:close()
    return paths, discovered_tags
end

-- ============================================================
-- MANUALLY DEFINED PATHS (for endpoints in app.lua and
-- auth endpoints with specific schemas)
-- ============================================================

local function get_manual_paths()
    local paths = {}

    -- Health/readiness/liveness
    paths["/health"] = {
        get = {
            tags = { "System" },
            summary = "Health check",
            operationId = "get_health",
            parameters = {
                {
                    name = "detailed",
                    ["in"] = "query",
                    required = false,
                    description = "Set to 'true' for comprehensive health check",
                    schema = { type = "string", enum = { "true", "false" } },
                },
            },
            responses = {
                ["200"] = {
                    description = "Service is healthy",
                    content = {
                        ["application/json"] = {
                            schema = {
                                type = "object",
                                properties = {
                                    status = { type = "string", enum = { "healthy", "degraded", "unhealthy" } },
                                    timestamp = { type = "integer" },
                                    checks = { type = "object" },
                                },
                            },
                        },
                    },
                },
                ["503"] = { description = "Service is unhealthy" },
            },
        },
    }

    paths["/ready"] = {
        get = {
            tags = { "System" },
            summary = "Kubernetes readiness probe",
            operationId = "get_ready",
            responses = {
                ["200"] = {
                    description = "Service is ready",
                    content = {
                        ["application/json"] = {
                            schema = {
                                type = "object",
                                properties = {
                                    ready = { type = "boolean" },
                                    timestamp = { type = "integer" },
                                },
                            },
                        },
                    },
                },
                ["503"] = { description = "Service is not ready" },
            },
        },
    }

    paths["/live"] = {
        get = {
            tags = { "System" },
            summary = "Kubernetes liveness probe",
            operationId = "get_live",
            responses = {
                ["200"] = {
                    description = "Service is alive",
                    content = {
                        ["application/json"] = {
                            schema = {
                                type = "object",
                                properties = {
                                    alive = { type = "boolean" },
                                    timestamp = { type = "integer" },
                                    uptime_seconds = { type = "number" },
                                },
                            },
                        },
                    },
                },
            },
        },
    }

    -- Auth: login
    paths["/auth/login"] = {
        post = {
            tags = { "Authentication" },
            summary = "Login with email and password",
            operationId = "post_auth_login",
            requestBody = {
                required = true,
                content = {
                    ["application/json"] = {
                        schema = {
                            type = "object",
                            required = { "email", "password" },
                            properties = {
                                email = { type = "string", format = "email" },
                                password = { type = "string", format = "password" },
                                device_info = { type = "string", description = "Device description for refresh token" },
                            },
                        },
                    },
                },
            },
            responses = {
                ["200"] = {
                    description = "Login successful",
                    content = {
                        ["application/json"] = {
                            schema = {
                                type = "object",
                                properties = {
                                    success = { type = "boolean" },
                                    user = { ["$ref"] = "#/components/schemas/User" },
                                    token = { type = "string", description = "JWT access token" },
                                    refresh_token = { type = "string", description = "Refresh token" },
                                    namespaces = { type = "array", items = { type = "object" } },
                                    default_namespace = { type = "object" },
                                },
                            },
                        },
                    },
                },
                ["401"] = { description = "Invalid credentials" },
                ["429"] = { description = "Rate limit exceeded" },
            },
        },
    }

    -- Auth: refresh
    paths["/auth/refresh"] = {
        post = {
            tags = { "Authentication" },
            summary = "Refresh JWT access token",
            operationId = "post_auth_refresh",
            requestBody = {
                required = true,
                content = {
                    ["application/json"] = {
                        schema = {
                            type = "object",
                            required = { "refresh_token" },
                            properties = {
                                refresh_token = { type = "string" },
                            },
                        },
                    },
                },
            },
            responses = {
                ["200"] = {
                    description = "Token refreshed",
                    content = {
                        ["application/json"] = {
                            schema = {
                                type = "object",
                                properties = {
                                    success = { type = "boolean" },
                                    token = { type = "string" },
                                    refresh_token = { type = "string" },
                                },
                            },
                        },
                    },
                },
                ["401"] = { description = "Invalid or expired refresh token" },
            },
        },
    }

    -- Auth: logout
    paths["/auth/logout"] = {
        post = {
            tags = { "Authentication" },
            summary = "Logout and revoke refresh token",
            operationId = "post_auth_logout",
            security = { { BearerAuth = {} } },
            requestBody = {
                required = false,
                content = {
                    ["application/json"] = {
                        schema = {
                            type = "object",
                            properties = {
                                refresh_token = { type = "string" },
                            },
                        },
                    },
                },
            },
            responses = {
                ["200"] = { description = "Logged out successfully" },
            },
        },
    }

    -- Auth: me
    paths["/auth/me"] = {
        get = {
            tags = { "Authentication" },
            summary = "Get current authenticated user",
            operationId = "get_auth_me",
            security = { { BearerAuth = {} } },
            responses = {
                ["200"] = {
                    description = "Current user profile",
                    content = {
                        ["application/json"] = {
                            schema = {
                                type = "object",
                                properties = {
                                    success = { type = "boolean" },
                                    data = { ["$ref"] = "#/components/schemas/User" },
                                },
                            },
                        },
                    },
                },
                ["401"] = { description = "Unauthorized" },
            },
        },
    }

    -- Auth: 2FA verify
    paths["/auth/2fa/verify"] = {
        post = {
            tags = { "Authentication" },
            summary = "Verify 2FA OTP code",
            operationId = "post_auth_2fa_verify",
            requestBody = {
                required = true,
                content = {
                    ["application/json"] = {
                        schema = {
                            type = "object",
                            required = { "otp", "session_token" },
                            properties = {
                                otp = { type = "string", description = "One-time password" },
                                session_token = { type = "string", description = "Session token from login" },
                            },
                        },
                    },
                },
            },
            responses = {
                ["200"] = { description = "2FA verification successful" },
                ["401"] = { description = "Invalid OTP" },
            },
        },
    }

    -- Auth: 2FA resend
    paths["/auth/2fa/resend"] = {
        post = {
            tags = { "Authentication" },
            summary = "Resend 2FA OTP code",
            operationId = "post_auth_2fa_resend",
            requestBody = {
                required = true,
                content = {
                    ["application/json"] = {
                        schema = {
                            type = "object",
                            required = { "session_token" },
                            properties = {
                                session_token = { type = "string" },
                            },
                        },
                    },
                },
            },
            responses = {
                ["200"] = { description = "OTP resent" },
                ["429"] = { description = "Rate limit exceeded" },
            },
        },
    }

    -- Auth: Google OAuth
    paths["/auth/google"] = {
        get = {
            tags = { "Authentication" },
            summary = "Initiate Google OAuth flow",
            operationId = "get_auth_google",
            responses = {
                ["302"] = { description = "Redirect to Google OAuth" },
            },
        },
    }

    paths["/auth/google/callback"] = {
        get = {
            tags = { "Authentication" },
            summary = "Google OAuth callback",
            operationId = "get_auth_google_callback",
            parameters = {
                { name = "code", ["in"] = "query", required = true, schema = { type = "string" } },
                { name = "state", ["in"] = "query", required = false, schema = { type = "string" } },
            },
            responses = {
                ["200"] = { description = "OAuth login successful" },
                ["401"] = { description = "OAuth authentication failed" },
            },
        },
    }

    -- Auth: OAuth validate
    paths["/auth/oauth/validate"] = {
        post = {
            tags = { "Authentication" },
            summary = "Validate OAuth token",
            operationId = "post_auth_oauth_validate",
            requestBody = {
                required = true,
                content = {
                    ["application/json"] = {
                        schema = {
                            type = "object",
                            required = { "token" },
                            properties = {
                                token = { type = "string" },
                                provider = { type = "string" },
                            },
                        },
                    },
                },
            },
            responses = {
                ["200"] = { description = "Token is valid" },
                ["401"] = { description = "Token is invalid" },
            },
        },
    }

    return paths
end

-- ============================================================
-- STATIC BASE SPEC
-- ============================================================

local function get_base_spec()
    return {
        openapi = "3.0.0",
        info = {
            title = "OpsAPI",
            description = "Multi-tenant Business API built with Lapis/OpenResty.\n\n"
                .. "**Authentication:** Most endpoints require a JWT Bearer token. "
                .. "Get your token by calling the `/auth/login` endpoint.\n\n"
                .. "**Namespaces:** Most data endpoints are scoped to the current namespace "
                .. "(set via `X-Namespace-ID` header or derived from your default namespace).\n\n"
                .. "**Features:** CRM, Invoicing, Timesheets, Document Templates, E-commerce, "
                .. "Kanban, Chat, Delivery, Tax Copilot, and more.",
            version = "2.0.0",
            contact = {
                name = "API Support",
                email = "support@opsapi.com",
            },
            license = {
                name = "MIT",
                url = "https://opensource.org/licenses/MIT",
            },
        },
        servers = {
            {
                url = "http://127.0.0.1:4010",
                description = "Local Development",
            },
            {
                url = "https://api.yourdomain.com",
                description = "Production",
            },
        },
        components = {
            securitySchemes = {
                BearerAuth = {
                    type = "http",
                    scheme = "bearer",
                    bearerFormat = "JWT",
                    description = "Enter JWT token obtained from /auth/login",
                },
            },
            schemas = {},
        },
        security = {
            { BearerAuth = {} },
        },
        paths = {},
        tags = {},
    }
end

-- ============================================================
-- CORE COMPONENT SCHEMAS (kept from original static spec)
-- ============================================================

local function get_core_schemas()
    return {
        User = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                email = { type = "string", format = "email" },
                first_name = { type = "string" },
                last_name = { type = "string" },
                phone = { type = "string" },
                created_at = { type = "string", format = "date-time" },
                updated_at = { type = "string", format = "date-time" },
            },
        },
        Group = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                name = { type = "string" },
                description = { type = "string" },
                type = { type = "string" },
                created_at = { type = "string", format = "date-time" },
            },
        },
        Role = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                name = { type = "string" },
                description = { type = "string" },
                permissions = { type = "array", items = { type = "string" } },
            },
        },
        Product = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                name = { type = "string" },
                description = { type = "string" },
                price = { type = "number", format = "double" },
                currency = { type = "string", default = "USD" },
                sku = { type = "string" },
                stock_quantity = { type = "integer" },
                category_id = { type = "string", format = "uuid" },
                images = { type = "array", items = { type = "string" } },
                is_active = { type = "boolean" },
                created_at = { type = "string", format = "date-time" },
            },
        },
        Category = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                name = { type = "string" },
                slug = { type = "string" },
                description = { type = "string" },
                parent_id = { type = "string", format = "uuid", nullable = true },
                image = { type = "string" },
            },
        },
        Order = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                user_id = { type = "string", format = "uuid" },
                status = { type = "string", enum = { "pending", "processing", "shipped", "delivered", "cancelled" } },
                total_amount = { type = "number", format = "double" },
                currency = { type = "string" },
                items = { type = "array", items = { ["$ref"] = "#/components/schemas/OrderItem" } },
                shipping_address = { type = "object" },
                created_at = { type = "string", format = "date-time" },
            },
        },
        OrderItem = {
            type = "object",
            properties = {
                product_id = { type = "string", format = "uuid" },
                quantity = { type = "integer" },
                price = { type = "number", format = "double" },
                subtotal = { type = "number", format = "double" },
            },
        },
        Cart = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                user_id = { type = "string", format = "uuid" },
                items = { type = "array", items = { ["$ref"] = "#/components/schemas/CartItem" } },
                total = { type = "number", format = "double" },
            },
        },
        CartItem = {
            type = "object",
            properties = {
                product_id = { type = "string", format = "uuid" },
                quantity = { type = "integer" },
                price = { type = "number", format = "double" },
            },
        },
        Payment = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                order_id = { type = "string", format = "uuid" },
                amount = { type = "number", format = "double" },
                currency = { type = "string" },
                status = { type = "string", enum = { "pending", "completed", "failed", "refunded" } },
                payment_method = { type = "string" },
                transaction_id = { type = "string" },
                created_at = { type = "string", format = "date-time" },
            },
        },
        Address = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                user_id = { type = "string", format = "uuid" },
                type = { type = "string", enum = { "billing", "shipping" } },
                street = { type = "string" },
                city = { type = "string" },
                state = { type = "string" },
                postal_code = { type = "string" },
                country = { type = "string" },
                is_default = { type = "boolean" },
            },
        },
        Tenant = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                name = { type = "string" },
                slug = { type = "string" },
                domain = { type = "string" },
                settings = { type = "object" },
                is_active = { type = "boolean" },
                created_at = { type = "string", format = "date-time" },
            },
        },
        Permission = {
            type = "object",
            properties = {
                id = { type = "string", format = "uuid" },
                name = { type = "string" },
                resource = { type = "string" },
                action = { type = "string" },
                description = { type = "string" },
            },
        },
        Error = {
            type = "object",
            properties = {
                success = { type = "boolean", example = false },
                error = { type = "string" },
            },
        },
        PaginatedResponse = {
            type = "object",
            properties = {
                success = { type = "boolean" },
                data = { type = "array", items = {} },
                meta = {
                    type = "object",
                    properties = {
                        total = { type = "integer" },
                        page = { type = "integer" },
                        per_page = { type = "integer" },
                        total_pages = { type = "integer" },
                    },
                },
            },
        },
        Namespace = {
            type = "object",
            properties = {
                id = { type = "integer" },
                uuid = { type = "string", format = "uuid" },
                name = { type = "string" },
                slug = { type = "string" },
                description = { type = "string" },
                status = { type = "string", enum = { "active", "inactive", "suspended" } },
                created_at = { type = "string", format = "date-time" },
                updated_at = { type = "string", format = "date-time" },
            },
        },
    }
end

-- ============================================================
-- TAG ORDERING
-- ============================================================

local TAG_ORDER = {
    "System",
    "Authentication",
    "Users",
    "Groups",
    "Roles",
    "Permissions",
    "Namespaces",
    "CRM",
    "Invoices",
    "Timesheets",
    "Document Templates",
    "Documents",
    "Templates",
    "Projects",
    "Kanban",
    "Chat",
    "Products",
    "Categories",
    "Cart",
    "Checkout",
    "Orders",
    "Order Items",
    "Payments",
    "Addresses",
    "Stores",
    "Store Products",
    "Public Store",
    "Customers",
    "Tenants",
    "Variants",
    "Delivery",
    "Notifications",
    "Email",
    "Enquiries",
    "Tags",
    "Secrets",
    "Secret Vault",
    "Modules",
    "Menu",
    "Pin",
    "Services",
    "Bank Transactions",
    "Tax Copilot",
    "Profile Builder",
    "Registration",
}

local TAG_DESCRIPTIONS = {
    ["System"]              = "Health checks, readiness probes, and system information",
    ["Authentication"]      = "Login, logout, token refresh, OAuth, and 2FA endpoints",
    ["Users"]               = "User management",
    ["Groups"]              = "Group management",
    ["Roles"]               = "Role management",
    ["Permissions"]         = "Permission management",
    ["Namespaces"]          = "Multi-tenant namespace management",
    ["CRM"]                 = "Customer Relationship Management: accounts, contacts, deals, pipelines, and activities",
    ["Invoices"]            = "Invoice management with line items, payments, tax rates, and workflow",
    ["Timesheets"]          = "Timesheet management with entries and approval workflow",
    ["Document Templates"]  = "Document template management, preview, and PDF generation",
    ["Documents"]           = "Generated document management",
    ["Templates"]           = "General content templates",
    ["Projects"]            = "Project management",
    ["Kanban"]              = "Kanban boards, tasks, sprints, labels, and analytics",
    ["Chat"]                = "Slack-like messaging: channels, messages, reactions, and mentions",
    ["Products"]            = "Product catalog management",
    ["Categories"]          = "Product category management",
    ["Cart"]                = "Shopping cart operations",
    ["Checkout"]            = "Checkout and order placement",
    ["Orders"]              = "Order management and tracking",
    ["Payments"]            = "Payment processing and webhooks",
    ["Delivery"]            = "Delivery partner management, assignments, and tracking",
    ["Notifications"]       = "Push notifications and device token management",
    ["Tax Copilot"]         = "UK tax return AI assistant: bank accounts, transactions, statements, and reports",
    ["Bank Transactions"]   = "Bank transaction management",
    ["Services"]            = "GitHub workflow integration and external services",
}

local function build_tags(discovered_tags)
    local tags = {}
    local seen = {}

    -- Add tags in preferred order
    for _, tag_name in ipairs(TAG_ORDER) do
        if discovered_tags[tag_name] then
            table.insert(tags, {
                name = tag_name,
                description = TAG_DESCRIPTIONS[tag_name] or tag_name,
            })
            seen[tag_name] = true
        end
    end

    -- Add any remaining discovered tags not in the preferred order
    local remaining = {}
    for tag_name in pairs(discovered_tags) do
        if not seen[tag_name] then
            table.insert(remaining, tag_name)
        end
    end
    table.sort(remaining)
    for _, tag_name in ipairs(remaining) do
        table.insert(tags, {
            name = tag_name,
            description = TAG_DESCRIPTIONS[tag_name] or tag_name,
        })
    end

    return tags
end

-- ============================================================
-- MAIN GENERATE FUNCTION
-- ============================================================

function _M.generate()
    -- Return cached spec if still valid
    local now = os.time()
    if cached_spec and (now - cache_timestamp) < CACHE_TTL then
        return cached_spec
    end

    -- Build the spec
    local spec = get_base_spec()

    -- 1. Merge core schemas
    local core_schemas = get_core_schemas()
    for name, schema in pairs(core_schemas) do
        spec.components.schemas[name] = schema
    end

    -- 2. Merge entity schemas (CRM, Invoices, Timesheets, etc.)
    for name, schema in pairs(ENTITY_SCHEMAS) do
        spec.components.schemas[name] = schema
    end

    -- 3. Discover routes from files
    local discovered_paths, discovered_tags = discover_routes()

    -- 4. Get manually defined paths
    local manual_paths = get_manual_paths()

    -- Add "System" tag from manual paths
    discovered_tags["System"] = true

    -- 5. Merge manual paths first (they take priority for auth endpoints)
    for path, methods in pairs(manual_paths) do
        spec.paths[path] = spec.paths[path] or {}
        for method, operation in pairs(methods) do
            spec.paths[path][method] = operation
            -- Track tags
            if operation.tags then
                for _, t in ipairs(operation.tags) do
                    discovered_tags[t] = true
                end
            end
        end
    end

    -- 6. Merge discovered paths (skip if manual already defined)
    for path, methods in pairs(discovered_paths) do
        spec.paths[path] = spec.paths[path] or {}
        for method, operation in pairs(methods) do
            if not spec.paths[path][method] then
                spec.paths[path][method] = operation
            end
        end
    end

    -- 7. Build ordered tags
    spec.tags = build_tags(discovered_tags)

    -- Cache the result
    cached_spec = spec
    cache_timestamp = now

    return spec
end

--- Force clear the cache (useful for development/testing).
function _M.clear_cache()
    cached_spec = nil
    cache_timestamp = 0
end

return _M
