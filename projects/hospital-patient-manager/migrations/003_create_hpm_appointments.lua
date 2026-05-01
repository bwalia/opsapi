-- Create appointments table
return function(schema, db)
    local types = schema.types

    schema.create_table("hpm_appointments", {
        { "id", types.serial },
        { "uuid", "UUID DEFAULT gen_random_uuid() UNIQUE" },
        { "namespace_id", types.integer },
        { "patient_id", "INTEGER REFERENCES hpm_patients(id) ON DELETE CASCADE" },
        { "department_id", "INTEGER REFERENCES hpm_departments(id) ON DELETE SET NULL" },
        { "doctor_name", types.varchar },
        { "appointment_type", "VARCHAR(50) DEFAULT 'consultation'" },
        { "scheduled_at", "TIMESTAMP WITH TIME ZONE NOT NULL" },
        { "duration_minutes", "INTEGER DEFAULT 30" },
        { "status", "VARCHAR(20) DEFAULT 'scheduled'" },
        { "notes", "TEXT" },
        { "reason", "TEXT" },
        { "diagnosis", "TEXT" },
        { "prescription", "TEXT" },
        { "follow_up_required", "BOOLEAN DEFAULT FALSE" },
        { "follow_up_date", "DATE" },
        { "cancelled_at", "TIMESTAMP WITH TIME ZONE" },
        { "cancellation_reason", "TEXT" },
        { "created_by", types.integer({ null = true }) },
        { "created_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()" },
        { "updated_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()" },
        "PRIMARY KEY (id)"
    })

    schema.create_index("hpm_appointments", "namespace_id")
    schema.create_index("hpm_appointments", "patient_id")
    schema.create_index("hpm_appointments", "department_id")
    schema.create_index("hpm_appointments", "scheduled_at")
    schema.create_index("hpm_appointments", "status")

    print("[hospital_patient_manager] Created hpm_appointments table")
end
