--[[
    OpsAPI agent tools
    ==================

    The set of actions the chat agent can take on the user's behalf, wired to the
    same queries the real routes use, and executed WITH the user's namespace +
    RBAC (each tool declares the permission its real route requires; the executor
    checks it before running). The agent NEVER escapes the tenant or the user's
    permissions — a denied tool returns an error the model relays to the user.

    Extending: add a `register{ ... }` block. `parameters` is a JSON schema the
    model sees; `perms` is a list of {module, action} (ANY grants access; omit
    for actions any namespace member may do); `handler(ctx, args)` runs it.
    ctx = { namespace_id, user_uuid, has_permission(module, action) }.
]]

local db = require("lapis.db")
local CustomerQueries = require("queries.CustomerQueries")
local EmployeeQueries = require("queries.EmployeeQueries")
local TimesheetQueries = require("queries.TimesheetQueries")

-- Lazily required: modules that may not be deployed for every PROJECT_CODE.
-- A missing module surfaces as a tool error the model relays, not a boot crash.
local function q(name)
    return require("queries." .. name)
end

local Tools = {}
local registry = {}
local order = {}

local function register(spec)
    registry[spec.name] = spec
    order[#order + 1] = spec.name
end

local function allowed(ctx, perms)
    if not perms or #perms == 0 then
        return true
    end
    for _, p in ipairs(perms) do
        if ctx.has_permission(p[1], p[2]) then
            return true
        end
    end
    return false
end

local function today()
    return os.date("!%Y-%m-%d")
end

-- Keep tool results small so they don't blow up the model's context.
local function take(list, n)
    local out = {}
    for i = 1, math.min(#(list or {}), n) do
        out[i] = list[i]
    end
    return out
end

-- ========================= tools =========================

-- Clarifying question. Handled specially by the agent loop (it ends the turn and
-- shows the question) — declared here so the model has a sanctioned way to ask.
register({
    name = "ask_user",
    description = "Ask the user a clarifying question when required information is missing. "
        .. "Never guess or invent values — ask instead.",
    parameters = {
        type = "object",
        properties = {
            question = { type = "string", description = "The question to ask the user." },
        },
        required = { "question" },
    },
})

register({
    name = "create_customer",
    description = "Create a new customer / client in the current workspace.",
    perms = { { "customers", "create" } },
    parameters = {
        type = "object",
        properties = {
            first_name = { type = "string", description = "Customer first name (or company name)." },
            last_name = { type = "string", description = "Customer last name (optional)." },
            email = { type = "string", description = "Email address (optional)." },
            phone = { type = "string", description = "Phone number (optional)." },
            notes = { type = "string", description = "Any notes (optional)." },
        },
        required = { "first_name" },
    },
    handler = function(ctx, a)
        local rec = CustomerQueries.create({
            namespace_id = ctx.namespace_id,
            first_name = a.first_name,
            last_name = a.last_name,
            email = a.email,
            phone = a.phone,
            notes = a.notes,
        })
        if not rec then
            return nil, "Failed to create the customer."
        end
        return {
            uuid = rec.uuid,
            first_name = rec.first_name,
            last_name = rec.last_name,
            email = rec.email,
        }
    end,
})

register({
    name = "list_customers",
    description = "List customers in the current workspace (most recent first).",
    perms = { { "customers", "read" } },
    parameters = {
        type = "object",
        properties = {
            limit = { type = "integer", description = "Max customers to return (default 10)." },
        },
    },
    handler = function(ctx, a)
        local result = CustomerQueries.all({
            namespace_id = ctx.namespace_id,
            page = 1,
            perPage = math.min(tonumber(a.limit) or 10, 25),
        })
        local rows = {}
        for _, c in ipairs(take(result and result.data, 25)) do
            rows[#rows + 1] = {
                uuid = c.uuid,
                name = ((c.first_name or "") .. " " .. (c.last_name or "")):gsub("^%s+", ""):gsub("%s+$", ""),
                email = c.email,
                phone = c.phone,
            }
        end
        return { total = result and result.total or #rows, customers = rows }
    end,
})

register({
    name = "find_customer",
    description = "Search customers in the current workspace by name or email. Use this to look up a "
        .. "customer before acting on one.",
    perms = { { "customers", "read" } },
    parameters = {
        type = "object",
        properties = {
            query = { type = "string", description = "Part of the customer's name or email." },
        },
        required = { "query" },
    },
    handler = function(ctx, a)
        local term = tostring(a.query or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if term == "" then
            return nil, "Please give a name or email to search for."
        end
        local like = "%" .. term .. "%"
        local rows = db.query([[
            SELECT uuid, first_name, last_name, email, phone
            FROM customers
            WHERE namespace_id = ?
              AND (first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ?
                   OR (COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')) ILIKE ?)
            ORDER BY created_at DESC
            LIMIT 10
        ]], ctx.namespace_id, like, like, like, like)
        local out = {}
        for _, c in ipairs(rows or {}) do
            out[#out + 1] = {
                uuid = c.uuid,
                name = ((c.first_name or "") .. " " .. (c.last_name or "")):gsub("^%s+", ""):gsub("%s+$", ""),
                email = c.email,
                phone = c.phone,
            }
        end
        return { matches = out, count = #out }
    end,
})

register({
    name = "add_team_member",
    description = "Add a new team member / employee to the workspace (provisions their login "
        .. "and membership). Use this to 'create an employee' or 'add a user'.",
    perms = { { "users", "create" } },
    parameters = {
        type = "object",
        properties = {
            first_name = { type = "string", description = "Person's first name." },
            last_name = { type = "string", description = "Person's last name (optional)." },
            email = { type = "string", description = "Their email address (used for their login)." },
            role_name = { type = "string", description = "Workspace role, e.g. 'member' or 'admin' (default 'member')." },
            job_title = { type = "string", description = "Job title (optional)." },
        },
        required = { "first_name", "email" },
    },
    handler = function(ctx, a)
        local rec = EmployeeQueries.createTeamMember(ctx.namespace_id, ctx.user_uuid, {
            first_name = a.first_name,
            last_name = a.last_name,
            email = a.email,
            role_name = a.role_name or "member",
            job_title = a.job_title,
        })
        if not rec then
            return nil, "Failed to add the team member."
        end
        return { added = true, email = a.email, name = a.first_name .. " " .. (a.last_name or "") }
    end,
})

register({
    name = "list_employees",
    description = "List employees / team members in the current workspace.",
    perms = { { "employees", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" } },
    parameters = {
        type = "object",
        properties = {
            limit = { type = "integer", description = "Max to return (default 10)." },
        },
    },
    handler = function(ctx, a)
        local result = EmployeeQueries.listEmployees(ctx.namespace_id, {
            page = 1,
            per_page = math.min(tonumber(a.limit) or 10, 25),
        })
        local rows = {}
        for _, e in ipairs(take(result and result.items, 25)) do
            rows[#rows + 1] = {
                uuid = e.uuid,
                name = e.user_name,
                email = e.user_email,
                job_title = e.job_title,
                is_active = e.is_active,
            }
        end
        return { employees = rows }
    end,
})

register({
    name = "create_timesheet",
    description = "Log a timesheet entry for work the current user did on a task. "
        .. "Requires the task/description and the hours spent; ask the user for hours if not given.",
    -- Any namespace member can log their own timesheet (matches the route).
    parameters = {
        type = "object",
        properties = {
            task = { type = "string", description = "What the work was (task or description)." },
            hours = { type = "number", description = "Hours spent (e.g. 2.5)." },
            work_date = { type = "string", description = "Date worked, YYYY-MM-DD (defaults to today)." },
            task_uuid = { type = "string", description = "Optional: uuid of a real project task (from list_my_tasks) to link this entry to." },
            customer_uuid = { type = "string", description = "Optional: uuid of the customer this work was for (from find_customer)." },
            is_billable = { type = "boolean", description = "Whether the time is billable (default true)." },
            notes = { type = "string", description = "Additional notes (optional)." },
        },
        required = { "task", "hours" },
    },
    handler = function(ctx, a)
        local hours = tonumber(a.hours)
        if not hours or hours <= 0 or hours > 24 then
            return nil, "Please provide hours between 0 and 24."
        end
        local rec = TimesheetQueries.create({
            namespace_id = ctx.namespace_id,
            user_uuid = ctx.user_uuid,
            task = a.task,
            task_uuid = a.task_uuid,
            customer_uuid = a.customer_uuid,
            work_date = a.work_date or today(),
            total_hours = hours,
            notes = a.notes,
            is_billable = a.is_billable ~= false,
        })
        if not rec then
            return nil, "Failed to create the timesheet."
        end
        return {
            uuid = rec.uuid,
            task = a.task,
            hours = hours,
            work_date = a.work_date or today(),
            status = rec.status,
        }
    end,
})

register({
    name = "list_timesheets",
    description = "List the current user's own recent timesheet entries.",
    parameters = {
        type = "object",
        properties = {
            limit = { type = "integer", description = "Max to return (default 10)." },
        },
    },
    handler = function(ctx, a)
        local result = TimesheetQueries.getMyTimesheets(ctx.namespace_id, ctx.user_uuid, {
            page = 1,
            per_page = math.min(tonumber(a.limit) or 10, 25),
        })
        local rows = {}
        for _, t in ipairs(take(result and result.data, 25)) do
            rows[#rows + 1] = {
                uuid = t.uuid,
                task = t.task,
                hours = t.total_hours,
                work_date = t.work_date,
                status = t.status,
            }
        end
        return { timesheets = rows }
    end,
})

-- ========================= CRM =========================
-- The real CRM routes gate on namespace membership only (no permission string),
-- so these tools do the same — any member may use them.

local function items_of(result)
    if type(result) ~= "table" then return {} end
    return result.items or result.data or result
end

register({
    name = "create_crm_account",
    description = "Create a CRM account (a company / organisation you do business with).",
    parameters = {
        type = "object",
        properties = {
            name = { type = "string", description = "Company name." },
            industry = { type = "string" },
            website = { type = "string" },
            email = { type = "string" },
            phone = { type = "string" },
            city = { type = "string" },
            country = { type = "string" },
        },
        required = { "name" },
    },
    handler = function(ctx, a)
        if not a.name or a.name == "" then return nil, "An account name is required." end
        local rec = q("CrmQueries").createAccount({
            namespace_id = ctx.namespace_id,
            name = a.name,
            industry = a.industry,
            website = a.website,
            email = a.email,
            phone = a.phone,
            city = a.city,
            country = a.country,
            status = "active",
            owner_user_uuid = ctx.user_uuid,
            metadata = "{}",
        })
        if not rec then return nil, "Failed to create the account." end
        return { uuid = rec.uuid, name = rec.name }
    end,
})

register({
    name = "list_crm_accounts",
    description = "List or search CRM accounts (companies) in the workspace.",
    parameters = {
        type = "object",
        properties = {
            search = { type = "string", description = "Optional name/email filter." },
            limit = { type = "integer" },
        },
    },
    handler = function(ctx, a)
        local r = q("CrmQueries").getAccounts(ctx.namespace_id, {
            page = 1, per_page = math.min(tonumber(a.limit) or 10, 25), search = a.search,
        })
        local rows = {}
        for _, x in ipairs(take(items_of(r), 25)) do
            rows[#rows + 1] = { uuid = x.uuid, name = x.name, industry = x.industry, email = x.email, status = x.status }
        end
        return { accounts = rows }
    end,
})

register({
    name = "create_lead",
    description = "Create a sales lead (a prospective customer). Needs at least a first name or an email.",
    parameters = {
        type = "object",
        properties = {
            first_name = { type = "string" },
            last_name = { type = "string" },
            email = { type = "string" },
            phone = { type = "string" },
            company_name = { type = "string" },
            job_title = { type = "string" },
            priority = { type = "string", description = "low | medium | high (default medium)." },
            notes = { type = "string" },
        },
    },
    handler = function(ctx, a)
        if (not a.first_name or a.first_name == "") and (not a.email or a.email == "") then
            return nil, "A lead needs at least a first name or an email."
        end
        local rec = q("CrmLeadQueries").createLead({
            namespace_id = ctx.namespace_id,
            first_name = a.first_name or "",
            last_name = a.last_name,
            email = a.email,
            phone = a.phone,
            company_name = a.company_name,
            job_title = a.job_title,
            source = "ai_assistant",
            status = "new",
            score = 0,
            priority = a.priority or "medium",
            notes = a.notes,
            owner_user_uuid = ctx.user_uuid,
            metadata = "{}",
        })
        if not rec then return nil, "Failed to create the lead." end
        return { uuid = rec.uuid, first_name = rec.first_name, email = rec.email, status = rec.status }
    end,
})

register({
    name = "list_leads",
    description = "List or search sales leads.",
    parameters = {
        type = "object",
        properties = {
            search = { type = "string", description = "Optional name/email/company filter." },
            status = { type = "string", description = "Optional status filter, e.g. new, contacted, qualified." },
            limit = { type = "integer" },
        },
    },
    handler = function(ctx, a)
        local r = q("CrmLeadQueries").getLeads(ctx.namespace_id, {
            page = 1, per_page = math.min(tonumber(a.limit) or 10, 25), search = a.search, status = a.status,
        })
        local rows = {}
        for _, x in ipairs(take(items_of(r), 25)) do
            rows[#rows + 1] = {
                uuid = x.uuid,
                name = ((x.first_name or "") .. " " .. (x.last_name or "")):gsub("^%s+", ""):gsub("%s+$", ""),
                email = x.email, company = x.company_name, status = x.status, priority = x.priority,
            }
        end
        return { leads = rows }
    end,
})

register({
    name = "create_contact",
    description = "Create a CRM contact (a person, optionally at a CRM account).",
    parameters = {
        type = "object",
        properties = {
            first_name = { type = "string" },
            last_name = { type = "string" },
            email = { type = "string" },
            phone = { type = "string" },
            job_title = { type = "string" },
            account_uuid = { type = "string", description = "Optional: uuid of the CRM account (from list_crm_accounts)." },
        },
        required = { "first_name" },
    },
    handler = function(ctx, a)
        if not a.first_name or a.first_name == "" then return nil, "A first name is required." end
        local Crm = q("CrmQueries")
        local account_id
        if a.account_uuid and a.account_uuid ~= "" then
            local acc = Crm.getAccount(ctx.namespace_id, a.account_uuid)
            if not acc then return nil, "That CRM account wasn't found in this workspace." end
            account_id = acc.id
        end
        local rec = Crm.createContact({
            namespace_id = ctx.namespace_id,
            account_id = account_id,
            first_name = a.first_name,
            last_name = a.last_name,
            email = a.email,
            phone = a.phone,
            job_title = a.job_title,
            status = "active",
            owner_user_uuid = ctx.user_uuid,
            metadata = "{}",
        })
        if not rec then return nil, "Failed to create the contact." end
        return { uuid = rec.uuid, first_name = rec.first_name, email = rec.email }
    end,
})

register({
    name = "create_deal",
    description = "Create a sales deal / opportunity.",
    parameters = {
        type = "object",
        properties = {
            name = { type = "string", description = "Deal name." },
            value = { type = "number", description = "Deal value (default 0)." },
            currency = { type = "string", description = "ISO currency, e.g. GBP, USD (default USD)." },
            stage = { type = "string", description = "Pipeline stage (default new)." },
            expected_close_date = { type = "string", description = "YYYY-MM-DD (optional)." },
            account_uuid = { type = "string", description = "Optional: CRM account uuid." },
        },
        required = { "name" },
    },
    handler = function(ctx, a)
        if not a.name or a.name == "" then return nil, "A deal name is required." end
        local Crm = q("CrmQueries")
        local account_id
        if a.account_uuid and a.account_uuid ~= "" then
            local acc = Crm.getAccount(ctx.namespace_id, a.account_uuid)
            if not acc then return nil, "That CRM account wasn't found in this workspace." end
            account_id = acc.id
        end
        local rec = Crm.createDeal({
            namespace_id = ctx.namespace_id,
            account_id = account_id,
            name = a.name,
            value = tonumber(a.value) or 0,
            currency = a.currency or "USD",
            stage = a.stage or "new",
            probability = 0,
            expected_close_date = a.expected_close_date,
            status = "open",
            owner_user_uuid = ctx.user_uuid,
            metadata = "{}",
        })
        if not rec then return nil, "Failed to create the deal." end
        return { uuid = rec.uuid, name = rec.name, value = rec.value, stage = rec.stage }
    end,
})

register({
    name = "list_deals",
    description = "List sales deals / opportunities.",
    parameters = {
        type = "object",
        properties = {
            stage = { type = "string" },
            status = { type = "string", description = "open | won | lost" },
            limit = { type = "integer" },
        },
    },
    handler = function(ctx, a)
        local r = q("CrmQueries").getDeals(ctx.namespace_id, {
            page = 1, per_page = math.min(tonumber(a.limit) or 10, 25), stage = a.stage, status = a.status,
        })
        local rows = {}
        for _, x in ipairs(take(items_of(r), 25)) do
            rows[#rows + 1] = {
                uuid = x.uuid, name = x.name, value = x.value, currency = x.currency,
                stage = x.stage, status = x.status, account = x.account_name,
            }
        end
        return { deals = rows }
    end,
})

-- ========================= Projects & tasks =========================

register({
    name = "list_projects",
    description = "List the projects the user is a member of.",
    perms = { { "projects", "read" } },
    parameters = {
        type = "object",
        properties = {
            search = { type = "string" },
            limit = { type = "integer" },
        },
    },
    handler = function(ctx, a)
        local r = q("KanbanProjectQueries").getByUser(ctx.user_uuid, ctx.namespace_id, {
            page = 1, perPage = math.min(tonumber(a.limit) or 10, 25), search = a.search,
        })
        local rows = {}
        for _, p in ipairs(take(items_of(r), 25)) do
            rows[#rows + 1] = { uuid = p.uuid, name = p.name, status = p.status, task_count = p.task_count }
        end
        return { projects = rows }
    end,
})

register({
    name = "create_project",
    description = "Create a new project (with a default board and columns).",
    perms = { { "projects", "create" } },
    parameters = {
        type = "object",
        properties = {
            name = { type = "string" },
            description = { type = "string" },
            due_date = { type = "string", description = "YYYY-MM-DD (optional)." },
        },
        required = { "name" },
    },
    handler = function(ctx, a)
        if not a.name or a.name == "" then return nil, "A project name is required." end
        local rec = q("KanbanProjectQueries").create({
            namespace_id = ctx.namespace_id,
            name = a.name,
            description = a.description,
            due_date = a.due_date,
            status = "active",
            visibility = "private",
            owner_user_uuid = ctx.user_uuid,
            settings = "{}",
            metadata = "{}",
        })
        if not rec then return nil, "Failed to create the project." end
        return { uuid = rec.uuid, name = rec.name }
    end,
})

register({
    name = "list_my_tasks",
    description = "List open tasks assigned to the user (with their project). Use to find a task "
        .. "to log time against.",
    perms = { { "projects", "read" } },
    parameters = {
        type = "object",
        properties = { limit = { type = "integer" } },
    },
    handler = function(ctx, a)
        local r = q("KanbanTaskQueries").getByAssignee(ctx.user_uuid, ctx.namespace_id, {
            page = 1, perPage = math.min(tonumber(a.limit) or 10, 25),
        })
        local rows = {}
        for _, t in ipairs(take(items_of(r), 25)) do
            rows[#rows + 1] = {
                uuid = t.uuid, title = t.title, status = t.status, priority = t.priority,
                project = t.project_name, column = t.column_name, due_date = t.due_date,
            }
        end
        return { tasks = rows }
    end,
})

register({
    name = "create_task",
    description = "Create a task in a project (lands in the project's first column). Requires an "
        .. "editor role on the project. Get the project uuid from list_projects.",
    parameters = {
        type = "object",
        properties = {
            project_uuid = { type = "string", description = "uuid of the project." },
            title = { type = "string" },
            description = { type = "string" },
            priority = { type = "string", description = "critical | high | medium | low | none (default medium)." },
            due_date = { type = "string", description = "YYYY-MM-DD (optional)." },
        },
        required = { "project_uuid", "title" },
    },
    handler = function(ctx, a)
        if not a.title or a.title == "" then return nil, "A task title is required." end
        local valid_priority = { critical = true, high = true, medium = true, low = true, none = true }
        if a.priority and not valid_priority[a.priority] then
            return nil, "Priority must be critical, high, medium, low or none."
        end
        -- Tenant-scoped: resolve the project's first board inside THIS namespace.
        local rows = db.query([[
            SELECT b.uuid AS board_uuid FROM kanban_boards b
            JOIN kanban_projects p ON p.id = b.project_id
            WHERE p.uuid = ? AND p.namespace_id = ?
            ORDER BY b.id LIMIT 1
        ]], a.project_uuid, ctx.namespace_id)
        if not rows or not rows[1] then
            return nil, "That project wasn't found in this workspace."
        end
        local board = q("KanbanBoardQueries").show(rows[1].board_uuid)
        if not board then return nil, "The project has no board." end
        local Projects = q("KanbanProjectQueries")
        -- Same gates as the real task route: member AND editor.
        if not Projects.isMember(board.project_id, ctx.user_uuid) then
            return nil, "You're not a member of that project."
        end
        if not Projects.isEditor(board.project_id, ctx.user_uuid) then
            return nil, "You have read-only access to that project."
        end
        local column_id = board.columns and board.columns[1] and board.columns[1].id or nil
        local rec = q("KanbanTaskQueries").create({
            board_id = board.id,
            column_id = column_id,
            title = a.title,
            description = a.description,
            status = "open",
            priority = a.priority or "medium",
            due_date = a.due_date,
            reporter_user_uuid = ctx.user_uuid,
            metadata = "{}",
        })
        if not rec then return nil, "Failed to create the task." end
        return { uuid = rec.uuid, title = rec.title, task_number = rec.task_number }
    end,
})

-- ========================= Team: invitations =========================

register({
    name = "invite_member",
    description = "Invite someone to join this workspace by email (they get a pending invitation).",
    perms = { { "users", "create" } },
    parameters = {
        type = "object",
        properties = {
            email = { type = "string" },
            message = { type = "string", description = "Optional personal note." },
        },
        required = { "email" },
    },
    handler = function(ctx, a)
        local email = tostring(a.email or "")
        if not email:match("^[%w%._%+-]+@[%w%.%-]+%.[%w]+$") then
            return nil, "That doesn't look like a valid email address."
        end
        local Members = q("NamespaceMemberQueries")
        local Invites = q("NamespaceInvitationQueries")
        -- Same member cap as the real route.
        local members = Members.count(ctx.namespace_id, "active") or 0
        local pending = Invites.count(ctx.namespace_id, "pending") or 0
        local cap = (ctx.namespace and ctx.namespace.max_users) or 10
        if (members + pending) >= cap then
            return nil, "This workspace has reached its member limit."
        end
        local inviter = db.select("id FROM users WHERE uuid = ?", ctx.user_uuid)
        if not inviter or not inviter[1] then return nil, "Could not identify you as the inviter." end
        local ok, inv = pcall(Invites.create, {
            namespace_id = ctx.namespace_id,
            email = email,
            message = a.message,
            invited_by = inviter[1].id,
        })
        if not ok then
            local msg = tostring(inv)
            if msg:match("already a member") then return nil, "That person is already a member." end
            if msg:match("already pending") then return nil, "An invitation is already pending for that email." end
            return nil, "Failed to create the invitation."
        end
        return { invited = email, status = "pending" }
    end,
})

-- ========================= Invoices =========================

register({
    name = "list_invoices",
    description = "List or search invoices (optionally by status: draft, sent, paid, overdue).",
    perms = { { "invoices", "read" } },
    parameters = {
        type = "object",
        properties = {
            status = { type = "string" },
            search = { type = "string", description = "Customer name, email or invoice number." },
            limit = { type = "integer" },
        },
    },
    handler = function(ctx, a)
        local r = q("InvoiceQueries").list(ctx.namespace_id, {
            page = 1, perPage = math.min(tonumber(a.limit) or 10, 25), status = a.status, search = a.search,
        })
        local rows = {}
        for _, i in ipairs(take(items_of(r), 25)) do
            rows[#rows + 1] = {
                uuid = i.id, number = i.invoice_number, customer = i.customer_name, status = i.status,
                total = i.total_amount, balance_due = i.balance_due, currency = i.currency, due_date = i.due_date,
            }
        end
        return { invoices = rows, total = r and r.total }
    end,
})

register({
    name = "create_invoice",
    description = "Create a DRAFT invoice for a customer, optionally with line items. Confirm the "
        .. "line items and amounts with the user before creating.",
    perms = { { "invoices", "create" } },
    parameters = {
        type = "object",
        properties = {
            customer_name = { type = "string" },
            customer_email = { type = "string" },
            due_date = { type = "string", description = "YYYY-MM-DD (optional)." },
            currency = { type = "string", description = "ISO currency (default GBP)." },
            notes = { type = "string" },
            line_items = {
                type = "array",
                description = "Items to bill.",
                items = {
                    type = "object",
                    properties = {
                        description = { type = "string" },
                        quantity = { type = "number" },
                        unit_price = { type = "number" },
                        tax_rate = { type = "number", description = "Percent, e.g. 20." },
                    },
                    required = { "description", "quantity", "unit_price" },
                },
            },
        },
        required = { "customer_name" },
    },
    handler = function(ctx, a)
        if not a.customer_name or a.customer_name == "" then return nil, "A customer name is required." end
        local items
        if a.line_items ~= nil then
            if type(a.line_items) ~= "table" then return nil, "line_items must be a list." end
            items = {}
            for _, it in ipairs(a.line_items) do
                if type(it) ~= "table" then return nil, "Each line item must be an object." end
                items[#items + 1] = {
                    description = it.description,
                    quantity = tonumber(it.quantity) or 1,
                    unit_price = tonumber(it.unit_price) or 0,
                    tax_rate = tonumber(it.tax_rate) or 0,
                }
            end
        end
        local ok, r = pcall(q("InvoiceQueries").create, {
            namespace_id = ctx.namespace_id,
            owner_user_uuid = ctx.user_uuid,
            customer_name = a.customer_name,
            customer_email = a.customer_email,
            due_date = a.due_date,
            currency = a.currency,
            notes = a.notes,
            line_items = items,
        })
        if not ok or not r then
            return nil, "Could not create the invoice — check the dates and amounts."
        end
        local inv = r.data or r
        return {
            uuid = inv.id or inv.uuid, number = inv.invoice_number, status = inv.status,
            total = inv.total_amount, currency = inv.currency,
        }
    end,
})

-- ========================= public API =========================

--- Ollama tool definitions (function schemas) for every registered tool.
function Tools.definitions()
    local defs = {}
    for _, name in ipairs(order) do
        local spec = registry[name]
        defs[#defs + 1] = {
            type = "function",
            ["function"] = {
                name = spec.name,
                description = spec.description,
                parameters = spec.parameters,
            },
        }
    end
    return defs
end

--- Execute a tool by name with RBAC. Returns (result_table|nil, err_string|nil).
function Tools.execute(ctx, name, args)
    local spec = registry[name]
    if not spec then
        return nil, "Unknown tool: " .. tostring(name)
    end
    if not spec.handler then
        return nil, "Tool " .. name .. " cannot be executed directly."
    end
    if not allowed(ctx, spec.perms) then
        return nil, "You don't have permission to do that (" .. name .. ") in this workspace."
    end
    local ok, res, err = pcall(spec.handler, ctx, args or {})
    if not ok then
        return nil, "Tool error: " .. tostring(res)
    end
    if err then
        return nil, err
    end
    return res
end

return Tools
