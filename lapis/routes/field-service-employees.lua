--[[
    Employee (staff directory) routes

    Endpoints:
    - GET    /api/v2/field-service/employees        - List (?is_engineer=&is_active=&search=&page=&per_page=)
    - POST   /api/v2/field-service/employees        - Create (links an existing member by user_uuid)
    - GET    /api/v2/field-service/employees/:uuid  - Get
    - PUT    /api/v2/field-service/employees/:uuid  - Update
    - DELETE /api/v2/field-service/employees/:uuid  - Soft delete (profile only; login untouched)
]]

local Http = require("helper.field-service-http")
local EmployeeQueries = require("queries.EmployeeQueries")

return function(app)
    -- Managers assigning work need the engineer list, so job/visit readers may read too.
    local READERS = { { "employees", "read" }, { "fs_jobs", "read" }, { "fs_visits", "read" } }

    app:get("/api/v2/field-service/employees", Http.guard_any(READERS, function(self)
        local result = EmployeeQueries.listEmployees(self.namespace.id, {
            is_engineer = self.params.is_engineer,
            is_active = self.params.is_active,
            search = self.params.search,
            page = self.params.page,
            per_page = self.params.per_page,
        })
        return Http.ok(result.items, 200, result.meta)
    end))

    app:post("/api/v2/field-service/employees", Http.guard("employees", "create", function(self)
        local emp, err = EmployeeQueries.createEmployee(self.namespace.id, Http.actor(self), Http.body(self))
        return Http.result(emp, err, 201)
    end))

    -- One-step "add team member": provision a login + workspace membership + role
    -- (+ engineer profile) in a single call. Creating a login is a users.create
    -- action (owner/admin), so it's gated there rather than on employees.
    app:post("/api/v2/field-service/team-members", Http.guard("users", "create", function(self)
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
                "<p>An account has been created for you on ", company, "'s field service system.</p>",
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
    end))

    app:get("/api/v2/field-service/employees/:uuid", Http.guard_any(READERS, function(self)
        local emp = EmployeeQueries.getEmployee(self.namespace.id, self.params.uuid)
        if not emp then return Http.fail(404, "Employee not found") end
        return Http.ok(emp)
    end))

    app:put("/api/v2/field-service/employees/:uuid", Http.guard("employees", "update", function(self)
        return Http.result(EmployeeQueries.updateEmployee(self.namespace.id, self.params.uuid, Http.body(self)))
    end))

    app:delete("/api/v2/field-service/employees/:uuid", Http.guard("employees", "delete", function(self)
        local ok, err = EmployeeQueries.deleteEmployee(self.namespace.id, self.params.uuid)
        if not ok then return Http.from_error(err) end
        return Http.ok({ message = "Employee removed" })
    end))
end
