-- Department CRUD routes
-- Mounted at: /api/v2/hospital-patient-manager/departments

local db = require("lapis.db")

return function(app)

    -- GET /departments — List departments
    app:get("/departments", function(self)
        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return { status = 400, json = { error = "Namespace required" } }
        end

        local departments = db.select(
            "* FROM hpm_departments WHERE namespace_id = ? ORDER BY name ASC",
            namespace_id
        )

        return { status = 200, json = { data = departments, total = #departments } }
    end)

    -- GET /departments/:id — Get single department
    app:get("/departments/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local departments = db.select(
            "* FROM hpm_departments WHERE id = ? AND namespace_id = ? LIMIT 1",
            self.params.id, namespace_id
        )

        if #departments == 0 then
            return { status = 404, json = { error = "Department not found" } }
        end

        -- Include patient count
        local count_result = db.select(
            "COUNT(*) as patient_count FROM hpm_patients WHERE department_id = ? AND status = 'active'",
            self.params.id
        )
        departments[1].patient_count = count_result[1] and count_result[1].patient_count or 0

        return { status = 200, json = { data = departments[1] } }
    end)

    -- POST /departments — Create department
    app:post("/departments", function(self)
        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return { status = 400, json = { error = "Namespace required" } }
        end

        local params = self.params
        if not params.name then
            return { status = 400, json = { error = "name is required" } }
        end

        local department = db.insert("hpm_departments", {
            namespace_id = namespace_id,
            name = params.name,
            code = params.code or db.NULL,
            description = params.description or db.NULL,
            head_of_department = params.head_of_department or db.NULL,
            phone = params.phone or db.NULL,
            email = params.email or db.NULL,
            floor = params.floor or db.NULL,
            building = params.building or db.NULL,
            status = params.status or "active",
        }, "id", "uuid", "name", "code", "status", "created_at")

        return { status = 201, json = { data = department, message = "Department created" } }
    end)

    -- PUT /departments/:id — Update department
    app:put("/departments/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local departments = db.select(
            "* FROM hpm_departments WHERE id = ? AND namespace_id = ? LIMIT 1",
            self.params.id, namespace_id
        )

        if #departments == 0 then
            return { status = 404, json = { error = "Department not found" } }
        end

        local params = self.params
        local updates = {}
        local allowed_fields = {
            "name", "code", "description", "head_of_department",
            "phone", "email", "floor", "building", "status",
        }

        for _, field in ipairs(allowed_fields) do
            if params[field] ~= nil then
                updates[field] = params[field]
            end
        end

        if next(updates) then
            updates.updated_at = db.raw("NOW()")
            db.update("hpm_departments", updates, { id = self.params.id, namespace_id = namespace_id })
        end

        local updated = db.select("* FROM hpm_departments WHERE id = ? LIMIT 1", self.params.id)
        return { status = 200, json = { data = updated[1], message = "Department updated" } }
    end)

    -- DELETE /departments/:id — Deactivate department
    app:delete("/departments/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local departments = db.select(
            "* FROM hpm_departments WHERE id = ? AND namespace_id = ? LIMIT 1",
            self.params.id, namespace_id
        )

        if #departments == 0 then
            return { status = 404, json = { error = "Department not found" } }
        end

        db.update("hpm_departments", {
            status = "inactive",
            updated_at = db.raw("NOW()"),
        }, { id = self.params.id })

        return { status = 200, json = { message = "Department deactivated" } }
    end)
end
