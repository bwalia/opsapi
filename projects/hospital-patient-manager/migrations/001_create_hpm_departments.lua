-- Create departments table
return function(schema, db)
    local types = schema.types

    schema.create_table("hpm_departments", {
        { "id", types.serial },
        { "uuid", "UUID DEFAULT gen_random_uuid() UNIQUE" },
        { "namespace_id", types.integer },
        { "name", types.varchar },
        { "code", "VARCHAR(50)" },
        { "description", "TEXT" },
        { "head_of_department", types.varchar({ null = true }) },
        { "phone", "VARCHAR(50)" },
        { "email", "VARCHAR(255)" },
        { "floor", "VARCHAR(20)" },
        { "building", "VARCHAR(100)" },
        { "status", "VARCHAR(20) DEFAULT 'active'" },
        { "created_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()" },
        { "updated_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()" },
        "PRIMARY KEY (id)"
    })

    schema.create_index("hpm_departments", "namespace_id")
    schema.create_index("hpm_departments", "code")
    schema.create_index("hpm_departments", "status")

    print("[hospital_patient_manager] Created hpm_departments table")
end
