-- Appointment CRUD routes
-- Mounted at: /api/v2/hospital-patient-manager/appointments

local db = require("lapis.db")

return function(app)

    -- GET /appointments — List appointments
    app:get("/appointments", function(self)
        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return { status = 400, json = { error = "Namespace required" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 25
        local offset = (page - 1) * per_page
        local status_filter = self.params.status
        local patient_id = tonumber(self.params.patient_id)
        local department_id = tonumber(self.params.department_id)
        local date_from = self.params.date_from
        local date_to = self.params.date_to

        local where_clauses = { "a.namespace_id = " .. db.escape_literal(namespace_id) }

        if status_filter then
            table.insert(where_clauses, "a.status = " .. db.escape_literal(status_filter))
        end
        if patient_id then
            table.insert(where_clauses, "a.patient_id = " .. db.escape_literal(patient_id))
        end
        if department_id then
            table.insert(where_clauses, "a.department_id = " .. db.escape_literal(department_id))
        end
        if date_from then
            table.insert(where_clauses, "a.scheduled_at >= " .. db.escape_literal(date_from))
        end
        if date_to then
            table.insert(where_clauses, "a.scheduled_at <= " .. db.escape_literal(date_to))
        end

        local where = table.concat(where_clauses, " AND ")

        local appointments = db.select([[
            a.*, p.first_name as patient_first_name, p.last_name as patient_last_name,
            d.name as department_name
            FROM hpm_appointments a
            LEFT JOIN hpm_patients p ON a.patient_id = p.id
            LEFT JOIN hpm_departments d ON a.department_id = d.id
            WHERE ]] .. where .. [[ ORDER BY a.scheduled_at ASC LIMIT ? OFFSET ?]],
            per_page, offset)

        local count_result = db.select("COUNT(*) as total FROM hpm_appointments a WHERE " .. where)
        local total = count_result[1] and count_result[1].total or 0

        return {
            status = 200,
            json = {
                data = appointments,
                total = total,
                page = page,
                per_page = per_page,
                total_pages = math.ceil(total / per_page),
            }
        }
    end)

    -- GET /appointments/:id — Get single appointment
    app:get("/appointments/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local appointments = db.select([[
            a.*, p.first_name as patient_first_name, p.last_name as patient_last_name,
            d.name as department_name
            FROM hpm_appointments a
            LEFT JOIN hpm_patients p ON a.patient_id = p.id
            LEFT JOIN hpm_departments d ON a.department_id = d.id
            WHERE a.id = ? AND a.namespace_id = ? LIMIT 1]],
            self.params.id, namespace_id)

        if #appointments == 0 then
            return { status = 404, json = { error = "Appointment not found" } }
        end

        return { status = 200, json = { data = appointments[1] } }
    end)

    -- POST /appointments — Create appointment
    app:post("/appointments", function(self)
        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return { status = 400, json = { error = "Namespace required" } }
        end

        local params = self.params

        if not params.patient_id or not params.scheduled_at then
            return { status = 400, json = { error = "patient_id and scheduled_at are required" } }
        end

        -- Verify patient exists in this namespace
        local patient = db.select("id FROM hpm_patients WHERE id = ? AND namespace_id = ? LIMIT 1",
            params.patient_id, namespace_id)
        if #patient == 0 then
            return { status = 404, json = { error = "Patient not found" } }
        end

        local appointment = db.insert("hpm_appointments", {
            namespace_id = namespace_id,
            patient_id = tonumber(params.patient_id),
            department_id = tonumber(params.department_id) or db.NULL,
            doctor_name = params.doctor_name or db.NULL,
            appointment_type = params.appointment_type or "consultation",
            scheduled_at = params.scheduled_at,
            duration_minutes = tonumber(params.duration_minutes) or 30,
            status = "scheduled",
            notes = params.notes or db.NULL,
            reason = params.reason or db.NULL,
            created_by = self.current_user and self.current_user.id or db.NULL,
        }, "id", "uuid", "scheduled_at", "status", "created_at")

        return { status = 201, json = { data = appointment, message = "Appointment created" } }
    end)

    -- PUT /appointments/:id — Update appointment
    app:put("/appointments/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local appointments = db.select("* FROM hpm_appointments WHERE id = ? AND namespace_id = ? LIMIT 1",
            self.params.id, namespace_id)

        if #appointments == 0 then
            return { status = 404, json = { error = "Appointment not found" } }
        end

        local params = self.params
        local updates = {}
        local allowed_fields = {
            "doctor_name", "appointment_type", "scheduled_at",
            "duration_minutes", "status", "notes", "reason",
            "diagnosis", "prescription", "follow_up_required",
            "follow_up_date", "department_id",
        }

        for _, field in ipairs(allowed_fields) do
            if params[field] ~= nil then
                updates[field] = params[field]
            end
        end

        -- Handle cancellation
        if params.status == "cancelled" then
            updates.cancelled_at = db.raw("NOW()")
            updates.cancellation_reason = params.cancellation_reason or db.NULL
        end

        if next(updates) then
            updates.updated_at = db.raw("NOW()")
            db.update("hpm_appointments", updates, { id = self.params.id, namespace_id = namespace_id })
        end

        local updated = db.select("* FROM hpm_appointments WHERE id = ? LIMIT 1", self.params.id)
        return { status = 200, json = { data = updated[1], message = "Appointment updated" } }
    end)

    -- DELETE /appointments/:id — Cancel appointment
    app:delete("/appointments/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local appointments = db.select("* FROM hpm_appointments WHERE id = ? AND namespace_id = ? LIMIT 1",
            self.params.id, namespace_id)

        if #appointments == 0 then
            return { status = 404, json = { error = "Appointment not found" } }
        end

        db.update("hpm_appointments", {
            status = "cancelled",
            cancelled_at = db.raw("NOW()"),
            cancellation_reason = self.params.reason or "Cancelled via API",
            updated_at = db.raw("NOW()"),
        }, { id = self.params.id })

        return { status = 200, json = { message = "Appointment cancelled" } }
    end)
end
