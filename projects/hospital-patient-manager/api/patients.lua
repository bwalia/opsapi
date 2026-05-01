-- Patient CRUD routes
-- Mounted at: /api/v2/hospital-patient-manager/patients

local respond_to = require("lapis.application").respond_to
local db = require("lapis.db")
local cjson = require("cjson")

return function(app)

    -- GET /patients — List patients (scoped by namespace)
    app:get("/patients", function(self)
        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return { status = 400, json = { error = "Namespace required" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 25
        local offset = (page - 1) * per_page
        local status_filter = self.params.status
        local search = self.params.search
        local department_id = tonumber(self.params.department_id)

        local where_clauses = { "namespace_id = " .. db.escape_literal(namespace_id) }

        if status_filter then
            table.insert(where_clauses, "status = " .. db.escape_literal(status_filter))
        end
        if department_id then
            table.insert(where_clauses, "department_id = " .. db.escape_literal(department_id))
        end
        if search and #search > 0 then
            local escaped = db.escape_literal("%" .. search .. "%")
            table.insert(where_clauses, "(first_name ILIKE " .. escaped .. " OR last_name ILIKE " .. escaped .. " OR nhs_number ILIKE " .. escaped .. ")")
        end

        local where = table.concat(where_clauses, " AND ")

        local patients = db.select("* FROM hpm_patients WHERE " .. where .. " ORDER BY created_at DESC LIMIT ? OFFSET ?", per_page, offset)
        local count_result = db.select("COUNT(*) as total FROM hpm_patients WHERE " .. where)
        local total = count_result[1] and count_result[1].total or 0

        return {
            status = 200,
            json = {
                data = patients,
                total = total,
                page = page,
                per_page = per_page,
                total_pages = math.ceil(total / per_page),
            }
        }
    end)

    -- GET /patients/:id — Get single patient
    app:get("/patients/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local patients = db.select("* FROM hpm_patients WHERE id = ? AND namespace_id = ? LIMIT 1",
            self.params.id, namespace_id)

        if #patients == 0 then
            return { status = 404, json = { error = "Patient not found" } }
        end

        return { status = 200, json = { data = patients[1] } }
    end)

    -- POST /patients — Create patient
    app:post("/patients", function(self)
        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return { status = 400, json = { error = "Namespace required" } }
        end

        local params = self.params

        if not params.first_name or not params.last_name then
            return { status = 400, json = { error = "first_name and last_name are required" } }
        end

        local patient = db.insert("hpm_patients", {
            namespace_id = namespace_id,
            department_id = tonumber(params.department_id) or db.NULL,
            first_name = params.first_name,
            last_name = params.last_name,
            date_of_birth = params.date_of_birth or db.NULL,
            gender = params.gender or db.NULL,
            email = params.email or db.NULL,
            phone = params.phone or db.NULL,
            address_line1 = params.address_line1 or db.NULL,
            address_line2 = params.address_line2 or db.NULL,
            city = params.city or db.NULL,
            postcode = params.postcode or db.NULL,
            country = params.country or "United Kingdom",
            nhs_number = params.nhs_number or db.NULL,
            blood_type = params.blood_type or db.NULL,
            allergies = params.allergies or db.NULL,
            medical_notes = params.medical_notes or db.NULL,
            emergency_contact_name = params.emergency_contact_name or db.NULL,
            emergency_contact_phone = params.emergency_contact_phone or db.NULL,
            emergency_contact_relation = params.emergency_contact_relation or db.NULL,
            status = params.status or "active",
        }, "id", "uuid", "first_name", "last_name", "status", "created_at")

        return { status = 201, json = { data = patient, message = "Patient created" } }
    end)

    -- PUT /patients/:id — Update patient
    app:put("/patients/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local patients = db.select("* FROM hpm_patients WHERE id = ? AND namespace_id = ? LIMIT 1",
            self.params.id, namespace_id)

        if #patients == 0 then
            return { status = 404, json = { error = "Patient not found" } }
        end

        local params = self.params
        local updates = {}
        local allowed_fields = {
            "first_name", "last_name", "date_of_birth", "gender",
            "email", "phone", "address_line1", "address_line2",
            "city", "postcode", "country", "nhs_number",
            "blood_type", "allergies", "medical_notes",
            "emergency_contact_name", "emergency_contact_phone",
            "emergency_contact_relation", "status", "department_id",
        }

        for _, field in ipairs(allowed_fields) do
            if params[field] ~= nil then
                updates[field] = params[field]
            end
        end

        if next(updates) then
            updates.updated_at = db.raw("NOW()")
            db.update("hpm_patients", updates, { id = self.params.id, namespace_id = namespace_id })
        end

        local updated = db.select("* FROM hpm_patients WHERE id = ? LIMIT 1", self.params.id)
        return { status = 200, json = { data = updated[1], message = "Patient updated" } }
    end)

    -- DELETE /patients/:id — Delete (soft) patient
    app:delete("/patients/:id", function(self)
        local namespace_id = self.namespace and self.namespace.id
        local patients = db.select("* FROM hpm_patients WHERE id = ? AND namespace_id = ? LIMIT 1",
            self.params.id, namespace_id)

        if #patients == 0 then
            return { status = 404, json = { error = "Patient not found" } }
        end

        db.update("hpm_patients", {
            status = "inactive",
            updated_at = db.raw("NOW()"),
        }, { id = self.params.id })

        return { status = 200, json = { message = "Patient deactivated" } }
    end)
end
