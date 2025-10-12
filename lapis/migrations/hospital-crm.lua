local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local Global = require "helper.global"

return {
    -- Hospitals table
    [1] = function()
        schema.create_table("hospitals", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "name", types.varchar },
            { "type", types.varchar }, -- hospital, care_home, clinic
            { "license_number", types.varchar({ unique = true }) },
            { "address", types.text },
            { "city", types.varchar },
            { "state", types.varchar },
            { "postal_code", types.varchar },
            { "country", types.varchar },
            { "phone", types.varchar },
            { "email", types.varchar },
            { "website", types.varchar({ null = true }) },
            { "capacity", types.integer({ default = 0 }) },
            { "specialties", types.text({ null = true }) }, -- JSON array of specialties
            { "services", types.text({ null = true }) }, -- JSON array of services
            { "facilities", types.text({ null = true }) }, -- JSON array of facilities
            { "emergency_services", types.boolean({ default = false }) },
            { "operating_hours", types.text({ null = true }) }, -- JSON object with hours
            { "contact_person", types.varchar({ null = true }) },
            { "contact_phone", types.varchar({ null = true }) },
            { "status", types.varchar({ default = "active" }) }, -- active, inactive, suspended
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })
        
        -- Create indexes for performance
        schema.create_index("hospitals", "type")
        schema.create_index("hospitals", "city")
        schema.create_index("hospitals", "state")
        schema.create_index("hospitals", "status")
    end,

    -- Patients table
    [2] = function()
        schema.create_table("patients", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "hospital_id", types.foreign_key },
            { "patient_id", types.varchar }, -- Hospital's internal patient ID
            { "first_name", types.varchar },
            { "last_name", types.varchar },
            { "date_of_birth", types.date },
            { "gender", types.varchar }, -- male, female, other
            { "phone", types.varchar({ null = true }) },
            { "email", types.varchar({ null = true }) },
            { "address", types.text({ null = true }) },
            { "city", types.varchar({ null = true }) },
            { "state", types.varchar({ null = true }) },
            { "postal_code", types.varchar({ null = true }) },
            { "country", types.varchar({ null = true }) },
            { "emergency_contact_name", types.varchar({ null = true }) },
            { "emergency_contact_phone", types.varchar({ null = true }) },
            { "emergency_contact_relation", types.varchar({ null = true }) },
            { "blood_type", types.varchar({ null = true }) },
            { "allergies", types.text({ null = true }) }, -- JSON array of allergies
            { "medical_conditions", types.text({ null = true }) }, -- JSON array of conditions
            { "medications", types.text({ null = true }) }, -- JSON array of current medications
            { "insurance_provider", types.varchar({ null = true }) },
            { "insurance_number", types.varchar({ null = true }) },
            { "admission_date", types.date({ null = true }) },
            { "discharge_date", types.date({ null = true }) },
            { "room_number", types.varchar({ null = true }) },
            { "bed_number", types.varchar({ null = true }) },
            { "status", types.varchar({ default = "active" }) }, -- active, discharged, transferred, deceased
            { "notes", types.text({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (hospital_id) REFERENCES hospitals(id) ON DELETE CASCADE"
        })
        
        -- Create indexes for performance
        schema.create_index("patients", "hospital_id")
        schema.create_index("patients", "patient_id")
        schema.create_index("patients", "status")
        schema.create_index("patients", "admission_date")
        schema.create_index("patients", "room_number")
    end,

    -- Patient Health Records table for daily routines and health monitoring
    [3] = function()
        schema.create_table("patient_health_records", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "patient_id", types.foreign_key },
            { "record_type", types.varchar }, -- vital_signs, medication, meal, activity, note, procedure
            { "record_date", types.date },
            { "record_time", types.time({ null = true }) },
            { "recorded_by", types.varchar({ null = true }) }, -- Staff member who recorded
            { "temperature", types.double({ null = true }) },
            { "blood_pressure_systolic", types.integer({ null = true }) },
            { "blood_pressure_diastolic", types.integer({ null = true }) },
            { "heart_rate", types.integer({ null = true }) },
            { "respiratory_rate", types.integer({ null = true }) },
            { "oxygen_saturation", types.double({ null = true }) },
            { "weight", types.double({ null = true }) },
            { "height", types.double({ null = true }) },
            { "pain_level", types.integer({ null = true }) }, -- 1-10 scale
            { "medication_name", types.varchar({ null = true }) },
            { "medication_dose", types.varchar({ null = true }) },
            { "medication_time", types.time({ null = true }) },
            { "medication_notes", types.text({ null = true }) },
            { "meal_type", types.varchar({ null = true }) }, -- breakfast, lunch, dinner, snack
            { "meal_intake", types.varchar({ null = true }) }, -- full, partial, refused
            { "meal_notes", types.text({ null = true }) },
            { "activity_type", types.varchar({ null = true }) }, -- walking, physiotherapy, etc.
            { "activity_duration", types.integer({ null = true }) }, -- in minutes
            { "activity_notes", types.text({ null = true }) },
            { "procedure_name", types.varchar({ null = true }) },
            { "procedure_notes", types.text({ null = true }) },
            { "general_notes", types.text({ null = true }) },
            { "follow_up_required", types.boolean({ default = false }) },
            { "follow_up_date", types.date({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE"
        })
        
        -- Create indexes for performance
        schema.create_index("patient_health_records", "patient_id")
        schema.create_index("patient_health_records", "record_type")
        schema.create_index("patient_health_records", "record_date")
        schema.create_index("patient_health_records", "recorded_by")
    end,

    -- Staff table for hospital employees
    [4] = function()
        schema.create_table("hospital_staff", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "hospital_id", types.foreign_key },
            { "user_id", types.foreign_key }, -- Link to users table
            { "employee_id", types.varchar }, -- Hospital's internal employee ID
            { "department", types.varchar }, -- nursing, medical, administration, etc.
            { "position", types.varchar }, -- doctor, nurse, administrator, etc.
            { "specialization", types.varchar({ null = true }) },
            { "license_number", types.varchar({ null = true }) },
            { "shift", types.varchar({ null = true }) }, -- day, night, rotating
            { "phone", types.varchar({ null = true }) },
            { "email", types.varchar({ null = true }) },
            { "hire_date", types.date({ null = true }) },
            { "status", types.varchar({ default = "active" }) }, -- active, inactive, terminated
            { "notes", types.text({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (hospital_id) REFERENCES hospitals(id) ON DELETE CASCADE",
            "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"
        })
        
        -- Create indexes for performance
        schema.create_index("hospital_staff", "hospital_id")
        schema.create_index("hospital_staff", "user_id")
        schema.create_index("hospital_staff", "department")
        schema.create_index("hospital_staff", "position")
        schema.create_index("hospital_staff", "status")
    end,

    -- Patient Assignments table to track which staff are assigned to which patients
    [5] = function()
        schema.create_table("patient_assignments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "patient_id", types.foreign_key },
            { "staff_id", types.foreign_key },
            { "assignment_type", types.varchar }, -- primary, secondary, on_call
            { "start_date", types.date },
            { "end_date", types.date({ null = true }) },
            { "shift", types.varchar({ null = true }) }, -- day, night, rotating
            { "notes", types.text({ null = true }) },
            { "status", types.varchar({ default = "active" }) }, -- active, completed, cancelled
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE",
            "FOREIGN KEY (staff_id) REFERENCES hospital_staff(id) ON DELETE CASCADE"
        })
        
        -- Create indexes for performance
        schema.create_index("patient_assignments", "patient_id")
        schema.create_index("patient_assignments", "staff_id")
        schema.create_index("patient_assignments", "assignment_type")
        schema.create_index("patient_assignments", "status")
    end,

    -- Patient Appointments table
    [6] = function()
        schema.create_table("patient_appointments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "patient_id", types.foreign_key },
            { "staff_id", types.foreign_key },
            { "appointment_type", types.varchar }, -- consultation, procedure, checkup, therapy
            { "appointment_date", types.date },
            { "appointment_time", types.time },
            { "duration", types.integer({ default = 30 }) }, -- in minutes
            { "location", types.varchar({ null = true }) }, -- room, department
            { "status", types.varchar({ default = "scheduled" }) }, -- scheduled, confirmed, completed, cancelled, no_show
            { "notes", types.text({ null = true }) },
            { "follow_up_required", types.boolean({ default = false }) },
            { "follow_up_date", types.date({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE",
            "FOREIGN KEY (staff_id) REFERENCES hospital_staff(id) ON DELETE CASCADE"
        })
        
        -- Create indexes for performance
        schema.create_index("patient_appointments", "patient_id")
        schema.create_index("patient_appointments", "staff_id")
        schema.create_index("patient_appointments", "appointment_date")
        schema.create_index("patient_appointments", "status")
    end,

    -- Patient Documents table for medical records, reports, etc.
    [7] = function()
        schema.create_table("patient_documents", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "patient_id", types.foreign_key },
            { "document_type", types.varchar }, -- medical_report, lab_result, xray, prescription, etc.
            { "title", types.varchar },
            { "description", types.text({ null = true }) },
            { "file_path", types.text },
            { "file_size", types.integer({ null = true }) },
            { "file_type", types.varchar({ null = true }) },
            { "uploaded_by", types.varchar({ null = true }) },
            { "document_date", types.date({ null = true }) },
            { "is_confidential", types.boolean({ default = false }) },
            { "status", types.varchar({ default = "active" }) }, -- active, archived, deleted
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE"
        })
        
        -- Create indexes for performance
        schema.create_index("patient_documents", "patient_id")
        schema.create_index("patient_documents", "document_type")
        schema.create_index("patient_documents", "status")
    end
}
