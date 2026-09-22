--[[
    Employees — staff directory (CORE module, available to any namespace)

    A generic staff directory: team members, their workspace logins, roles and
    skills. NOT field-service-specific (field service builds engineer profiles on
    top of the same `employees` table). Loaded under `core`, so every namespace
    has it.

    Canonical endpoints:
    - GET    /api/v2/employees              - List (?is_engineer=&is_active=&search=&page=&per_page=)
    - POST   /api/v2/employees              - Create (links an existing member by user_uuid)
    - GET    /api/v2/employees/candidates   - Workspace members for the "add employee" picker
    - POST   /api/v2/employees/team-members - One-step: provision login + membership + role (+ profile)
    - GET    /api/v2/employees/:uuid        - Get
    - PUT    /api/v2/employees/:uuid        - Update
    - DELETE /api/v2/employees/:uuid        - Soft delete (profile only; login untouched)

    Backward compatibility: the same handlers are also mounted at the old
    /api/v2/field-service/employees* (+ /field-service/team-members) paths so the
    existing field-service UI keeps working until it migrates.
]]

local Http = require("helper.field-service-http")
local EmployeeQueries = require("queries.EmployeeQueries")

return function(app)
    -- Managers assigning work need the staff list, so job/visit readers may read too.
    local READERS = { { "employees", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" } }

    -- Register a handler at the canonical /api/v2/employees path AND the legacy
    -- /api/v2/field-service/employees path, so nothing that still calls the old
    -- endpoint breaks.
    local function mount(method, suffix, handler)
        app[method](app, "/api/v2/employees" .. suffix, handler)
        app[method](app, "/api/v2/field-service/employees" .. suffix, handler)
    end

    -- List
    mount("get", "", Http.guard_any(READERS, function(self)
        local result = EmployeeQueries.listEmployees(self.namespace.id, {
            is_engineer = self.params.is_engineer,
            is_active = self.params.is_active,
            search = self.params.search,
            page = self.params.page,
            per_page = self.params.per_page,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    -- Create (links an existing workspace member by user_uuid)
    mount("post", "", Http.guard("employees", "create", function(self)
        local emp, err = EmployeeQueries.createEmployee(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(emp, err, 201)
    end))

    -- Member picker: active workspace members for the "add employee" form.
    -- (Legacy field-service UI keeps using /api/v2/field-service/engineers, which
    -- lives in field-service-config.lua and adds an fs_visits open-count.)
    local candidates = Http.guard_any(READERS, function(self)
        return Http.ok(EmployeeQueries.listMembers(self.namespace.id, { search = self.params.search }))
    end)
    app:get("/api/v2/employees/candidates", candidates)

    -- One-step "add team member": provision a login + workspace membership + role
    -- (+ profile) in a single call. Creating a login is a users.create action
    -- (owner/admin), so it's gated there rather than on employees.
    local team_member = Http.guard("users", "create", function(self)
        local body = Http.body(self)
        local result, err = EmployeeQueries.createTeamMember(self.namespace.id, Http.actor(self), body)
        if not result then return Http.from_error(err) end

        -- Welcome email: confirms the account + how to sign in. The temporary
        -- password is NOT emailed — the admin hands it over (returned below).
        pcall(function()
            local company = self.namespace.name or "our team"
            local login_url = (body.login_url ~= nil and body.login_url ~= "" and body.login_url) or nil
            local html = table.concat({
                "<p>Hi ", (result.name ~= "" and result.name or "there"), ",</p>",
                "<p>An account has been created for you on ", company, "'s workspace.</p>",
                "<p>Your sign-in email is <strong>", result.email, "</strong>.",
                login_url and (" Sign in at <a href=\"" .. login_url .. "\">" .. login_url .. "</a>.") or "",
                "</p>",
                "<p>Your administrator will give you a temporary password — please change it once you've signed in.</p>",
                "<p>Thanks,<br>", company, "</p>",
            })
            require("helper.mail").send({ to = result.email, subject = "Your account for " .. company, html = html })
        end)

        return Http.ok({
            email = result.email, name = result.name, role = result.role_name,
            temp_password = result.temp_password, user_uuid = result.user_uuid,
        }, 201)
    end)
    app:post("/api/v2/employees/team-members", team_member)
    app:post("/api/v2/field-service/team-members", team_member)

    -- Get one
    mount("get", "/:uuid", Http.guard_any(READERS, function(self)
        local emp = EmployeeQueries.getEmployee(self.namespace.id, self.params.uuid)
        if not emp then return Http.fail(404, "Employee not found") end
        return Http.ok(emp)
    end))

    -- Update
    mount("put", "/:uuid", Http.guard("employees", "update", function(self)
        return Http.result(EmployeeQueries.updateEmployee(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    -- Delete (soft; profile only, login untouched)
    mount("delete", "/:uuid", Http.guard("employees", "delete", function(self)
        local ok, err = EmployeeQueries.deleteEmployee(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Employee removed" })
    end))
end
