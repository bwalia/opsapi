return {
    code = "hospital_patient_manager",
    name = "Hospital Patient Manager",
    version = "1.0.0",
    description = "Patient management system for hospitals and care homes",
    enabled = true,

    -- Features this project depends on from core OPSAPI
    depends = { "core", "menu", "notifications" },

    -- Feature code this project registers
    feature = "hospital_patient_manager",

    -- RBAC modules
    modules = {
        { machine_name = "hpm_patients", name = "Patients", description = "Patient registration and records", category = "Hospital" },
        { machine_name = "hpm_appointments", name = "Appointments", description = "Appointment scheduling", category = "Hospital" },
        { machine_name = "hpm_departments", name = "Departments", description = "Department management", category = "Hospital" },
    },

    -- Dashboard configuration
    dashboard = {
        menu_items = {
            { label = "Patients", icon = "users", path = "/patients" },
            { label = "Appointments", icon = "calendar", path = "/appointments" },
            { label = "Departments", icon = "building", path = "/departments" },
        },
    },

    -- Theme
    theme = "default",
}
