local PatientModel = require("models.PatientModel")
local PatientHealthRecordModel = require("models.PatientHealthRecordModel")
local PatientAppointmentModel = require("models.PatientAppointmentModel")
local PatientDocumentModel = require("models.PatientDocumentModel")
local PatientAssignmentModel = require("models.PatientAssignmentModel")
local Global = require("helper.global")

return function(app)
    ----------------- Patient Routes --------------------

    -- Get all patients
    app:get("/patients", function(self)
        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 20
        local offset = (page - 1) * per_page
        local hospital_id = self.params.hospital_id
        
        local patients
        if hospital_id then
            patients = PatientModel:select("WHERE hospital_id = ? ORDER BY last_name ASC, first_name ASC LIMIT ? OFFSET ?", 
                hospital_id, per_page, offset)
        else
            patients = PatientModel:select("ORDER BY last_name ASC, first_name ASC LIMIT ? OFFSET ?", per_page, offset)
        end
        
        -- Parse JSON fields for each patient
        for _, patient in ipairs(patients) do
            if patient.allergies then
                local ok, parsed = pcall(cJson.decode, patient.allergies)
                if ok then patient.allergies = parsed end
            end
            if patient.medical_conditions then
                local ok, parsed = pcall(cJson.decode, patient.medical_conditions)
                if ok then patient.medical_conditions = parsed end
            end
            if patient.medications then
                local ok, parsed = pcall(cJson.decode, patient.medications)
                if ok then patient.medications = parsed end
            end
        end
        
        local total
        if hospital_id then
            total = PatientModel:count("WHERE hospital_id = ?", hospital_id)
        else
            total = PatientModel:count()
        end
        
        return {
            json = {
                patients = patients,
                pagination = {
                    page = page,
                    per_page = per_page,
                    total = total,
                    total_pages = math.ceil(total / per_page)
                }
            }
        }
    end)

    -- Get patient by ID
    app:get("/patients/:id", function(self)
        local patient = PatientModel:getWithParsedData(self.params.id)
        
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        return {
            json = {
                patient = patient
            }
        }
    end)

    -- Create new patient
    app:post("/patients", function(self)
        local data = self.params
        
        -- Validate required fields
        if not data.hospital_id or not data.patient_id or not data.first_name or not data.last_name or not data.date_of_birth or not data.gender then
            return {
                status = 400,
                json = {
                    error = "Missing required fields: hospital_id, patient_id, first_name, last_name, date_of_birth, gender"
                }
            }
        end
        
        -- Check if patient ID already exists in the hospital
        local existing = PatientModel:select("WHERE hospital_id = ? AND patient_id = ?", data.hospital_id, data.patient_id)
        if #existing > 0 then
            return {
                status = 400,
                json = {
                    error = "Patient with this ID already exists in this hospital"
                }
            }
        end
        
        local patient = PatientModel:create(data)
        
        if patient then
            return {
                status = 201,
                json = {
                    message = "Patient created successfully",
                    patient = patient
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to create patient"
                }
            }
        end
    end)

    -- Update patient
    app:put("/patients/:id", function(self)
        local patient_id = self.params.id
        local data = self.params
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        -- Check if patient ID is being changed and if it already exists
        if data.patient_id and data.patient_id ~= patient.patient_id then
            local existing = PatientModel:select("WHERE hospital_id = ? AND patient_id = ? AND id != ?", 
                patient.hospital_id, data.patient_id, patient_id)
            if #existing > 0 then
                return {
                    status = 400,
                    json = {
                        error = "Patient with this ID already exists in this hospital"
                    }
                }
            end
        end
        
        local updated_patient = PatientModel:update(patient_id, data)
        
        if updated_patient then
            return {
                json = {
                    message = "Patient updated successfully",
                    patient = updated_patient
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to update patient"
                }
            }
        end
    end)

    -- Delete patient
    app:delete("/patients/:id", function(self)
        local patient_id = self.params.id
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local deleted = PatientModel:delete(patient_id)
        
        if deleted then
            return {
                json = {
                    message = "Patient deleted successfully"
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to delete patient"
                }
            }
        end
    end)

    -- Search patients
    app:get("/patients/search", function(self)
        local criteria = {
            hospital_id = self.params.hospital_id,
            patient_id = self.params.patient_id,
            first_name = self.params.first_name,
            last_name = self.params.last_name,
            room_number = self.params.room_number,
            status = self.params.status,
            admission_date_from = self.params.admission_date_from,
            admission_date_to = self.params.admission_date_to
        }
        
        local patients = PatientModel:search(criteria)
        
        return {
            json = {
                patients = patients
            }
        }
    end)

    -- Get patients by hospital
    app:get("/patients/hospital/:hospital_id", function(self)
        local patients = PatientModel:getByHospital(self.params.hospital_id)
        
        return {
            json = {
                patients = patients
            }
        }
    end)

    -- Get active patients
    app:get("/patients/active", function(self)
        local hospital_id = self.params.hospital_id
        local patients = PatientModel:getActive(hospital_id)
        
        return {
            json = {
                patients = patients
            }
        }
    end)

    -- Get patients by room
    app:get("/patients/room/:hospital_id/:room_number", function(self)
        local patients = PatientModel:getByRoom(self.params.hospital_id, self.params.room_number)
        
        return {
            json = {
                patients = patients
            }
        }
    end)

    -- Get patient statistics
    app:get("/patients/:id/statistics", function(self)
        local patient_id = self.params.id
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local stats = PatientModel:getStatistics(patient.hospital_id)
        local age = PatientModel:calculateAge(patient_id)
        
        return {
            json = {
                statistics = stats,
                patient_age = age
            }
        }
    end)

    -- Get patient health records
    app:get("/patients/:id/health-records", function(self)
        local patient_id = self.params.id
        local limit = tonumber(self.params.limit) or 50
        local offset = tonumber(self.params.offset) or 0
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local records = PatientHealthRecordModel:getByPatient(patient_id, limit, offset)
        
        return {
            json = {
                health_records = records
            }
        }
    end)

    -- Create health record
    app:post("/patients/:id/health-records", function(self)
        local patient_id = self.params.id
        local data = self.params
        data.patient_id = patient_id
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        -- Validate required fields
        if not data.record_type or not data.record_date then
            return {
                status = 400,
                json = {
                    error = "Missing required fields: record_type, record_date"
                }
            }
        end
        
        local record = PatientHealthRecordModel:create(data)
        
        if record then
            return {
                status = 201,
                json = {
                    message = "Health record created successfully",
                    health_record = record
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to create health record"
                }
            }
        end
    end)

    -- Get patient appointments
    app:get("/patients/:id/appointments", function(self)
        local patient_id = self.params.id
        local limit = tonumber(self.params.limit) or 50
        local offset = tonumber(self.params.offset) or 0
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local appointments = PatientAppointmentModel:getByPatient(patient_id, limit, offset)
        
        return {
            json = {
                appointments = appointments
            }
        }
    end)

    -- Create appointment
    app:post("/patients/:id/appointments", function(self)
        local patient_id = self.params.id
        local data = self.params
        data.patient_id = patient_id
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        -- Validate required fields
        if not data.staff_id or not data.appointment_type or not data.appointment_date or not data.appointment_time then
            return {
                status = 400,
                json = {
                    error = "Missing required fields: staff_id, appointment_type, appointment_date, appointment_time"
                }
            }
        end
        
        local appointment = PatientAppointmentModel:create(data)
        
        if appointment then
            return {
                status = 201,
                json = {
                    message = "Appointment created successfully",
                    appointment = appointment
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to create appointment"
                }
            }
        end
    end)

    -- Get patient documents
    app:get("/patients/:id/documents", function(self)
        local patient_id = self.params.id
        local limit = tonumber(self.params.limit) or 50
        local offset = tonumber(self.params.offset) or 0
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local documents = PatientDocumentModel:getByPatient(patient_id, limit, offset)
        
        return {
            json = {
                documents = documents
            }
        }
    end)

    -- Create patient document
    app:post("/patients/:id/documents", function(self)
        local patient_id = self.params.id
        local data = self.params
        data.patient_id = patient_id
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        -- Validate required fields
        if not data.document_type or not data.title or not data.file_path then
            return {
                status = 400,
                json = {
                    error = "Missing required fields: document_type, title, file_path"
                }
            }
        end
        
        local document = PatientDocumentModel:create(data)
        
        if document then
            return {
                status = 201,
                json = {
                    message = "Document created successfully",
                    document = document
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to create document"
                }
            }
        end
    end)

    -- Get patient assignments
    app:get("/patients/:id/assignments", function(self)
        local patient_id = self.params.id
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local assignments = PatientAssignmentModel:getByPatient(patient_id)
        
        return {
            json = {
                assignments = assignments
            }
        }
    end)

    -- Create patient assignment
    app:post("/patients/:id/assignments", function(self)
        local patient_id = self.params.id
        local data = self.params
        data.patient_id = patient_id
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        -- Validate required fields
        if not data.staff_id or not data.assignment_type or not data.start_date then
            return {
                status = 400,
                json = {
                    error = "Missing required fields: staff_id, assignment_type, start_date"
                }
            }
        end
        
        local assignment = PatientAssignmentModel:create(data)
        
        if assignment then
            return {
                status = 201,
                json = {
                    message = "Patient assignment created successfully",
                    assignment = assignment
                }
            }
        else
            return {
                status = 500,
                json = {
                    error = "Failed to create patient assignment"
                }
            }
        end
    end)

    -- Get daily summary for patient
    app:get("/patients/:id/daily-summary/:date", function(self)
        local patient_id = self.params.id
        local date = self.params.date
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local summary = PatientHealthRecordModel:getDailySummary(patient_id, date)
        
        return {
            json = {
                daily_summary = summary
            }
        }
    end)

    -- Get latest vital signs for patient
    app:get("/patients/:id/vitals", function(self)
        local patient_id = self.params.id
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local vitals = PatientHealthRecordModel:getLatestVitals(patient_id)
        
        return {
            json = {
                vital_signs = vitals
            }
        }
    end)

    -- Get medication history for patient
    app:get("/patients/:id/medications", function(self)
        local patient_id = self.params.id
        local limit = tonumber(self.params.limit) or 20
        
        local patient = PatientModel:find(patient_id)
        if not patient then
            return {
                status = 404,
                json = {
                    error = "Patient not found"
                }
            }
        end
        
        local medications = PatientHealthRecordModel:getMedicationHistory(patient_id, limit)
        
        return {
            json = {
                medications = medications
            }
        }
    end)
end
