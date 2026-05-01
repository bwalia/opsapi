-- Create patients table
return function(schema, db)
    local types = schema.types

    schema.create_table("hpm_patients", {
        { "id", types.serial },
        { "uuid", "UUID DEFAULT gen_random_uuid() UNIQUE" },
        { "namespace_id", types.integer },
        { "department_id", "INTEGER REFERENCES hpm_departments(id) ON DELETE SET NULL" },
        { "first_name", types.varchar },
        { "last_name", types.varchar },
        { "date_of_birth", "DATE" },
        { "gender", "VARCHAR(20)" },
        { "email", "VARCHAR(255)" },
        { "phone", "VARCHAR(50)" },
        { "address_line1", "VARCHAR(255)" },
        { "address_line2", "VARCHAR(255)" },
        { "city", "VARCHAR(100)" },
        { "postcode", "VARCHAR(20)" },
        { "country", "VARCHAR(100) DEFAULT 'United Kingdom'" },
        { "nhs_number", "VARCHAR(20)" },
        { "blood_type", "VARCHAR(5)" },
        { "allergies", "TEXT" },
        { "medical_notes", "TEXT" },
        { "emergency_contact_name", "VARCHAR(255)" },
        { "emergency_contact_phone", "VARCHAR(50)" },
        { "emergency_contact_relation", "VARCHAR(100)" },
        { "status", "VARCHAR(20) DEFAULT 'active'" },
        { "admitted_at", "TIMESTAMP WITH TIME ZONE" },
        { "discharged_at", "TIMESTAMP WITH TIME ZONE" },
        { "created_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()" },
        { "updated_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()" },
        "PRIMARY KEY (id)"
    })

    schema.create_index("hpm_patients", "namespace_id")
    schema.create_index("hpm_patients", "department_id")
    schema.create_index("hpm_patients", "status")
    schema.create_index("hpm_patients", "nhs_number")
    schema.create_index("hpm_patients", "last_name")

    print("[hospital_patient_manager] Created hpm_patients table")
end
