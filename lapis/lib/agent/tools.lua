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

local CustomerQueries = require("queries.CustomerQueries")
local EmployeeQueries = require("queries.EmployeeQueries")
local TimesheetQueries = require("queries.TimesheetQueries")

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
            notes = { type = "string", description = "Additional notes (optional)." },
        },
        required = { "task", "hours" },
    },
    handler = function(ctx, a)
        local hours = tonumber(a.hours)
        if not hours or hours <= 0 then
            return nil, "Please provide a positive number of hours."
        end
        local rec = TimesheetQueries.create({
            namespace_id = ctx.namespace_id,
            user_uuid = ctx.user_uuid,
            task = a.task,
            work_date = a.work_date or today(),
            total_hours = hours,
            notes = a.notes,
            is_billable = true,
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
