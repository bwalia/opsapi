--[[
    Hospital & Care Home Patient Management System - Extended Migrations

    Adds comprehensive care management tables for:
    - Facility structure (departments, wards, rooms/beds)
    - Care plans and care logs
    - Dedicated medications tracking
    - Patient-controlled access (GDPR/HIPAA-ready)
    - Family member portal
    - Dementia & elderly care assessments
    - Daily care logs
    - Alerts & notifications
    - Full audit trail

    These tables extend the existing hospital-crm.lua schema.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

-- Guard: hospital-crm migrations (47-53) create `hospitals` but sort AFTER
-- these (442-453) lexicographically. If `hospitals` isn't there yet, skip so
-- the migrator doesn't abort on the FK — hospital-crm will run next, and a
-- subsequent deploy (or PROJECT_CODE=all on a clean DB) brings these in.
local function require_hospitals(fn)
    return function(...)
        if not table_exists("hospitals") then
            print("[hospital-care-management] `hospitals` table missing — skipping (hospital-crm not yet run)")
            return
        end
        return fn(...)
    end
end

local migrations = {
    -- =========================================================================
    -- [1] Departments
    -- =========================================================================
    [1] = function()
        schema.create_table("departments", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "hospital_id", types.foreign_key },
            { "name",        types.varchar },
            { "code",        types.varchar({ null = true }) },
            { "description", types.text({ null = true }) },
            { "head_of_department", types.varchar({ null = true }) },
            { "phone",       types.varchar({ null = true }) },
            { "email",       types.varchar({ null = true }) },
            { "floor",       types.varchar({ null = true }) },
            { "capacity",    types.integer({ default = 0 }) },
            { "specialties", types.text({ null = true }) },       -- JSON array
            { "operating_hours", types.text({ null = true }) },   -- JSON object
            { "status",      types.varchar({ default = "active" }) }, -- active, inactive, closed
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (hospital_id) REFERENCES hospitals(id) ON DELETE CASCADE"
        })

        schema.create_index("departments", "hospital_id")
        schema.create_index("departments", "status")
        schema.create_index("departments", "code")
    end,

    -- =========================================================================
    -- [2] Wards
    -- =========================================================================
    [2] = function()
        schema.create_table("wards", {
            { "id",            types.serial },
            { "uuid",          types.varchar({ unique = true }) },
            { "hospital_id",   types.foreign_key },
            { "department_id", types.foreign_key({ null = true }) },
            { "name",          types.varchar },
            { "code",          types.varchar({ null = true }) },
            { "ward_type",     types.varchar({ null = true }) }, -- general, icu, maternity, dementia, palliative
            { "floor",         types.varchar({ null = true }) },
            { "capacity",      types.integer({ default = 0 }) },
            { "current_occupancy", types.integer({ default = 0 }) },
            { "nurse_station_phone", types.varchar({ null = true }) },
            { "visiting_hours", types.text({ null = true }) },   -- JSON object
            { "restrictions",  types.text({ null = true }) },     -- JSON array
            { "status",        types.varchar({ default = "active" }) }, -- active, closed, maintenance
            { "created_at",    types.time({ null = true }) },
            { "updated_at",    types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (hospital_id) REFERENCES hospitals(id) ON DELETE CASCADE"
        })

        schema.create_index("wards", "hospital_id")
        schema.create_index("wards", "department_id")
        schema.create_index("wards", "ward_type")
        schema.create_index("wards", "status")
    end,

    -- =========================================================================
    -- [3] Rooms & Beds
    -- =========================================================================
    [3] = function()
        schema.create_table("rooms_beds", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "hospital_id", types.foreign_key },
            { "ward_id",     types.foreign_key },
            { "room_number", types.varchar },
            { "bed_number",  types.varchar({ null = true }) },
            { "room_type",   types.varchar({ null = true }) }, -- single, double, shared, isolation
            { "floor",       types.varchar({ null = true }) },
            { "has_oxygen",  types.boolean({ default = false }) },
            { "has_suction", types.boolean({ default = false }) },
            { "has_monitor", types.boolean({ default = false }) },
            { "has_bathroom", types.boolean({ default = false }) },
            { "equipment",   types.text({ null = true }) },    -- JSON array
            { "patient_id",  types.foreign_key({ null = true }) }, -- current occupant
            { "status",      types.varchar({ default = "available" }) }, -- available, occupied, maintenance, reserved
            { "notes",       types.text({ null = true }) },
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (hospital_id) REFERENCES hospitals(id) ON DELETE CASCADE",
            "FOREIGN KEY (ward_id) REFERENCES wards(id) ON DELETE CASCADE"
        })

        schema.create_index("rooms_beds", "hospital_id")
        schema.create_index("rooms_beds", "ward_id")
        schema.create_index("rooms_beds", "status")
        schema.create_index("rooms_beds", "patient_id")
        schema.create_index("rooms_beds", "room_number")
    end,

    -- =========================================================================
    -- [4] Care Plans
    -- =========================================================================
    [4] = function()
        schema.create_table("care_plans", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "patient_id",  types.foreign_key },
            { "hospital_id", types.foreign_key },
            { "plan_type",   types.varchar },  -- general, medication, rehabilitation, dementia, palliative, nutrition
            { "title",       types.varchar },
            { "description", types.text({ null = true }) },
            { "goals",       types.text({ null = true }) },          -- JSON array of goals
            { "interventions", types.text({ null = true }) },        -- JSON array of interventions
            { "medication_schedule", types.text({ null = true }) },  -- JSON array of scheduled meds
            { "daily_routines", types.text({ null = true }) },       -- JSON object of routines by time
            { "risk_assessments", types.text({ null = true }) },     -- JSON: falls, wandering, pressure_sores
            { "dietary_requirements", types.text({ null = true }) }, -- JSON: allergies, preferences, restrictions
            { "mobility_aids", types.text({ null = true }) },        -- JSON array
            { "communication_needs", types.text({ null = true }) },  -- JSON: language, hearing, vision
            { "created_by",  types.varchar({ null = true }) },
            { "approved_by", types.varchar({ null = true }) },
            { "review_date", types.date({ null = true }) },
            { "start_date",  types.date },
            { "end_date",    types.date({ null = true }) },
            { "status",      types.varchar({ default = "active" }) }, -- draft, active, completed, cancelled
            { "priority",    types.varchar({ default = "normal" }) }, -- low, normal, high, urgent
            { "notes",       types.text({ null = true }) },
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE",
            "FOREIGN KEY (hospital_id) REFERENCES hospitals(id) ON DELETE CASCADE"
        })

        schema.create_index("care_plans", "patient_id")
        schema.create_index("care_plans", "hospital_id")
        schema.create_index("care_plans", "plan_type")
        schema.create_index("care_plans", "status")
        schema.create_index("care_plans", "review_date")
        schema.create_index("care_plans", "priority")
    end,

    -- =========================================================================
    -- [5] Care Logs (shift-based staff updates)
    -- =========================================================================
    [5] = function()
        schema.create_table("care_logs", {
            { "id",           types.serial },
            { "uuid",         types.varchar({ unique = true }) },
            { "patient_id",   types.foreign_key },
            { "care_plan_id", types.foreign_key({ null = true }) },
            { "staff_id",     types.foreign_key({ null = true }) },
            { "log_type",     types.varchar },  -- feeding, medication, personal_care, observation, incident, handover
            { "log_date",     types.date },
            { "log_time",     types.time({ null = true }) },
            { "shift",        types.varchar({ null = true }) },  -- morning, afternoon, night
            { "summary",      types.text },
            { "details",      types.text({ null = true }) },     -- JSON: structured data per log_type
            -- Medication administration
            { "medication_name", types.varchar({ null = true }) },
            { "medication_dose", types.varchar({ null = true }) },
            { "medication_administered", types.boolean({ null = true }) },
            { "medication_refused_reason", types.text({ null = true }) },
            -- Feeding
            { "meal_type",    types.varchar({ null = true }) },  -- breakfast, lunch, dinner, snack, fluids
            { "intake_amount", types.varchar({ null = true }) }, -- all, most, half, little, none
            { "fluid_intake_ml", types.integer({ null = true }) },
            -- Mood & behaviour
            { "mood",         types.varchar({ null = true }) },  -- happy, calm, anxious, agitated, confused, distressed
            { "behaviour_notes", types.text({ null = true }) },
            -- Personal care
            { "personal_care_type", types.varchar({ null = true }) }, -- bathing, dressing, toileting, oral_care
            { "assistance_level", types.varchar({ null = true }) },  -- independent, minimal, moderate, full
            -- Incident
            { "incident_type", types.varchar({ null = true }) },     -- fall, injury, wandering, aggression, medical_emergency
            { "incident_severity", types.varchar({ null = true }) }, -- minor, moderate, severe
            { "action_taken", types.text({ null = true }) },
            { "follow_up_required", types.boolean({ default = false }) },
            { "follow_up_notes", types.text({ null = true }) },
            { "status",       types.varchar({ default = "completed" }) }, -- draft, completed, reviewed, flagged
            { "reviewed_by",  types.varchar({ null = true }) },
            { "reviewed_at",  types.time({ null = true }) },
            { "created_at",   types.time({ null = true }) },
            { "updated_at",   types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE"
        })

        schema.create_index("care_logs", "patient_id")
        schema.create_index("care_logs", "care_plan_id")
        schema.create_index("care_logs", "staff_id")
        schema.create_index("care_logs", "log_type")
        schema.create_index("care_logs", "log_date")
        schema.create_index("care_logs", "shift")
        schema.create_index("care_logs", "status")
    end,

    -- =========================================================================
    -- [6] Medications (dedicated tracking)
    -- =========================================================================
    [6] = function()
        schema.create_table("medications", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "patient_id",  types.foreign_key },
            { "care_plan_id", types.foreign_key({ null = true }) },
            { "name",        types.varchar },
            { "generic_name", types.varchar({ null = true }) },
            { "dosage",      types.varchar },
            { "unit",        types.varchar({ null = true }) },          -- mg, ml, tablet, etc.
            { "route",       types.varchar({ null = true }) },          -- oral, iv, topical, inhaled, injection
            { "frequency",   types.varchar },                           -- once_daily, twice_daily, as_needed, etc.
            { "schedule_times", types.text({ null = true }) },          -- JSON array: ["08:00","20:00"]
            { "instructions", types.text({ null = true }) },
            { "purpose",     types.varchar({ null = true }) },
            { "prescriber",  types.varchar({ null = true }) },
            { "pharmacy",    types.varchar({ null = true }) },
            { "start_date",  types.date },
            { "end_date",    types.date({ null = true }) },
            { "is_prn",      types.boolean({ default = false }) },      -- as-needed medication
            { "max_daily_doses", types.integer({ null = true }) },
            { "side_effects", types.text({ null = true }) },            -- JSON array
            { "interactions", types.text({ null = true }) },            -- JSON array
            { "allergies_check", types.boolean({ default = false }) },  -- confirmed no allergy
            { "status",      types.varchar({ default = "active" }) },   -- active, paused, discontinued, completed
            { "discontinued_reason", types.text({ null = true }) },
            { "notes",       types.text({ null = true }) },
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE"
        })

        schema.create_index("medications", "patient_id")
        schema.create_index("medications", "care_plan_id")
        schema.create_index("medications", "status")
        schema.create_index("medications", "name")
        schema.create_index("medications", "start_date")
    end,

    -- =========================================================================
    -- [7] Patient Access Controls (patient-controlled sharing)
    -- =========================================================================
    [7] = function()
        schema.create_table("patient_access_controls", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "patient_id",  types.foreign_key },
            { "granted_to",  types.varchar },                           -- email or user identifier
            { "granted_to_user_id", types.foreign_key({ null = true }) },
            { "role",        types.varchar },                           -- family_member, caregiver, doctor, specialist, social_worker
            { "relationship", types.varchar({ null = true }) },         -- daughter, son, spouse, gp, consultant
            { "access_level", types.varchar({ default = "read" }) },    -- read, read_write, emergency_only
            { "scope",       types.text({ null = true }) },             -- JSON array: ["medications","appointments","care_plans","all"]
            { "data_categories", types.text({ null = true }) },         -- JSON: granular category permissions
            { "granted_by",  types.varchar({ null = true }) },          -- who granted (patient or admin)
            { "granted_by_user_id", types.foreign_key({ null = true }) },
            { "share_token", types.varchar({ null = true }) },          -- JWT-based secure sharing token
            { "token_expires_at", types.time({ null = true }) },
            { "requires_2fa", types.boolean({ default = false }) },
            { "ip_whitelist", types.text({ null = true }) },            -- JSON array of allowed IPs
            { "last_accessed_at", types.time({ null = true }) },
            { "access_count", types.integer({ default = 0 }) },
            { "expires_at",  types.time({ null = true }) },
            { "revoked_at",  types.time({ null = true }) },
            { "revoked_reason", types.text({ null = true }) },
            { "status",      types.varchar({ default = "active" }) },   -- pending, active, expired, revoked, suspended
            { "consent_given", types.boolean({ default = false }) },
            { "consent_date", types.date({ null = true }) },
            { "notes",       types.text({ null = true }) },
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE"
        })

        schema.create_index("patient_access_controls", "patient_id")
        schema.create_index("patient_access_controls", "granted_to")
        schema.create_index("patient_access_controls", "granted_to_user_id")
        schema.create_index("patient_access_controls", "role")
        schema.create_index("patient_access_controls", "status")
        schema.create_index("patient_access_controls", "expires_at")
        schema.create_index("patient_access_controls", "share_token")
    end,

    -- =========================================================================
    -- [8] Family Members
    -- =========================================================================
    [8] = function()
        schema.create_table("family_members", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "patient_id",  types.foreign_key },
            { "user_id",     types.foreign_key({ null = true }) },  -- linked user account if registered
            { "first_name",  types.varchar },
            { "last_name",   types.varchar },
            { "relationship", types.varchar },                       -- spouse, daughter, son, sibling, parent, guardian, other
            { "is_next_of_kin", types.boolean({ default = false }) },
            { "is_emergency_contact", types.boolean({ default = false }) },
            { "is_power_of_attorney", types.boolean({ default = false }) },
            { "phone",       types.varchar({ null = true }) },
            { "email",       types.varchar({ null = true }) },
            { "address",     types.text({ null = true }) },
            { "preferred_contact_method", types.varchar({ null = true }) }, -- phone, email, sms
            { "preferred_language", types.varchar({ null = true }) },
            { "notification_preferences", types.text({ null = true }) }, -- JSON: what alerts to receive
            { "can_make_decisions", types.boolean({ default = false }) },
            { "decision_scope", types.text({ null = true }) },           -- JSON: medical, financial, all
            { "verified",    types.boolean({ default = false }) },
            { "verified_at", types.time({ null = true }) },
            { "verified_by", types.varchar({ null = true }) },
            { "status",      types.varchar({ default = "active" }) },    -- active, inactive, removed
            { "notes",       types.text({ null = true }) },
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE"
        })

        schema.create_index("family_members", "patient_id")
        schema.create_index("family_members", "user_id")
        schema.create_index("family_members", "relationship")
        schema.create_index("family_members", "is_next_of_kin")
        schema.create_index("family_members", "is_emergency_contact")
        schema.create_index("family_members", "status")
    end,

    -- =========================================================================
    -- [9] Dementia Assessments
    -- =========================================================================
    [9] = function()
        schema.create_table("dementia_assessments", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "patient_id",  types.foreign_key },
            { "assessor",    types.varchar },
            { "assessment_type", types.varchar },  -- mmse, moca, adl, behavioural, cognitive, capacity
            { "assessment_date", types.date },
            { "score",       types.integer({ null = true }) },
            { "max_score",   types.integer({ null = true }) },
            { "severity_level", types.varchar({ null = true }) },  -- mild, moderate, severe
            { "cognitive_domains", types.text({ null = true }) },  -- JSON: memory, orientation, language, attention
            { "behavioural_symptoms", types.text({ null = true }) }, -- JSON: agitation, wandering, sundowning, aggression
            { "functional_abilities", types.text({ null = true }) }, -- JSON: eating, dressing, bathing, mobility
            { "wandering_risk", types.varchar({ null = true }) },  -- none, low, moderate, high
            { "fall_risk",   types.varchar({ null = true }) },     -- none, low, moderate, high
            { "communication_ability", types.varchar({ null = true }) }, -- verbal, limited_verbal, non_verbal, gestures
            { "recognition_ability", types.text({ null = true }) }, -- JSON: recognises_family, recognises_staff, recognises_environment
            { "sleep_pattern", types.text({ null = true }) },      -- JSON: quality, disturbances, sundowning
            { "recommendations", types.text({ null = true }) },    -- JSON array
            { "memory_prompts", types.text({ null = true }) },     -- JSON: personalised memory aids
            { "routine_preferences", types.text({ null = true }) }, -- JSON: preferred routines and triggers
            { "triggers_to_avoid", types.text({ null = true }) },  -- JSON array
            { "calming_strategies", types.text({ null = true }) }, -- JSON array
            { "next_assessment_date", types.date({ null = true }) },
            { "status",      types.varchar({ default = "completed" }) }, -- scheduled, in_progress, completed, cancelled
            { "notes",       types.text({ null = true }) },
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE"
        })

        schema.create_index("dementia_assessments", "patient_id")
        schema.create_index("dementia_assessments", "assessment_type")
        schema.create_index("dementia_assessments", "assessment_date")
        schema.create_index("dementia_assessments", "severity_level")
        schema.create_index("dementia_assessments", "wandering_risk")
        schema.create_index("dementia_assessments", "fall_risk")
    end,

    -- =========================================================================
    -- [10] Daily Logs (comprehensive daily tracking)
    -- =========================================================================
    [10] = function()
        schema.create_table("daily_logs", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "patient_id",  types.foreign_key },
            { "log_date",    types.date },
            { "shift",       types.varchar({ null = true }) },          -- morning, afternoon, night
            { "recorded_by", types.varchar },
            -- Sleep
            { "sleep_quality", types.varchar({ null = true }) },        -- good, fair, poor, disturbed
            { "sleep_hours",  types.double({ null = true }) },
            { "sleep_notes",  types.text({ null = true }) },
            -- Nutrition
            { "breakfast_intake", types.varchar({ null = true }) },     -- all, most, half, little, none
            { "lunch_intake",    types.varchar({ null = true }) },
            { "dinner_intake",   types.varchar({ null = true }) },
            { "snack_intake",    types.varchar({ null = true }) },
            { "fluid_intake_ml", types.integer({ null = true }) },
            { "nutrition_notes", types.text({ null = true }) },
            -- Medication
            { "medications_given", types.text({ null = true }) },       -- JSON array of administered meds
            { "medications_refused", types.text({ null = true }) },     -- JSON array
            { "medication_notes", types.text({ null = true }) },
            -- Activity
            { "activities",   types.text({ null = true }) },            -- JSON array of activities
            { "mobility_level", types.varchar({ null = true }) },       -- independent, assisted, wheelchair, bedbound
            { "exercise_completed", types.boolean({ null = true }) },
            { "activity_notes", types.text({ null = true }) },
            -- Mood & Behaviour
            { "overall_mood", types.varchar({ null = true }) },         -- happy, calm, anxious, agitated, confused, distressed
            { "mood_changes", types.text({ null = true }) },            -- JSON array of mood events
            { "behavioural_incidents", types.text({ null = true }) },   -- JSON array
            { "social_interactions", types.text({ null = true }) },     -- JSON: visitors, group_activities
            -- Personal Care
            { "personal_care_completed", types.text({ null = true }) }, -- JSON: bathing, dressing, oral_care
            { "continence_notes", types.text({ null = true }) },
            -- Overall
            { "general_wellbeing", types.varchar({ null = true }) },    -- excellent, good, fair, poor, declining
            { "pain_level",  types.integer({ null = true }) },          -- 0-10
            { "weight",      types.double({ null = true }) },
            { "concerns",    types.text({ null = true }) },
            { "family_notified", types.boolean({ default = false }) },
            { "family_visit", types.boolean({ default = false }) },
            { "family_visit_notes", types.text({ null = true }) },
            { "status",      types.varchar({ default = "completed" }) },
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE"
        })

        schema.create_index("daily_logs", "patient_id")
        schema.create_index("daily_logs", "log_date")
        schema.create_index("daily_logs", "shift")
        schema.create_index("daily_logs", "overall_mood")
        schema.create_index("daily_logs", "general_wellbeing")
    end,

    -- =========================================================================
    -- [11] Alerts & Notifications
    -- =========================================================================
    [11] = function()
        schema.create_table("patient_alerts", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "patient_id",  types.foreign_key },
            { "hospital_id", types.foreign_key },
            { "alert_type",  types.varchar },  -- medication_reminder, emergency, fall, wandering, missed_care, vital_sign, appointment, family_notification
            { "severity",    types.varchar({ default = "info" }) }, -- info, warning, critical, emergency
            { "title",       types.varchar },
            { "message",     types.text },
            { "details",     types.text({ null = true }) },        -- JSON: additional context
            { "triggered_by", types.varchar({ null = true }) },    -- system, staff_id, sensor
            { "triggered_rule", types.text({ null = true }) },     -- JSON: the rule that triggered this
            { "assigned_to", types.varchar({ null = true }) },     -- staff member responsible
            { "escalation_level", types.integer({ default = 0 }) },
            { "escalated_to", types.varchar({ null = true }) },
            { "acknowledged_by", types.varchar({ null = true }) },
            { "acknowledged_at", types.time({ null = true }) },
            { "resolved_by", types.varchar({ null = true }) },
            { "resolved_at", types.time({ null = true }) },
            { "resolution_notes", types.text({ null = true }) },
            { "notify_family", types.boolean({ default = false }) },
            { "family_notified_at", types.time({ null = true }) },
            { "notification_channels", types.text({ null = true }) }, -- JSON: ["email","sms","push"]
            { "status",      types.varchar({ default = "active" }) }, -- active, acknowledged, resolved, dismissed, escalated
            { "created_at",  types.time({ null = true }) },
            { "updated_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (patient_id) REFERENCES patients(id) ON DELETE CASCADE",
            "FOREIGN KEY (hospital_id) REFERENCES hospitals(id) ON DELETE CASCADE"
        })

        schema.create_index("patient_alerts", "patient_id")
        schema.create_index("patient_alerts", "hospital_id")
        schema.create_index("patient_alerts", "alert_type")
        schema.create_index("patient_alerts", "severity")
        schema.create_index("patient_alerts", "status")
        schema.create_index("patient_alerts", "assigned_to")
        schema.create_index("patient_alerts", "created_at")
    end,

    -- =========================================================================
    -- [12] Audit Logs (GDPR/HIPAA compliance trail)
    -- =========================================================================
    [12] = function()
        schema.create_table("patient_audit_logs", {
            { "id",          types.serial },
            { "uuid",        types.varchar({ unique = true }) },
            { "patient_id",  types.foreign_key },
            { "user_id",     types.foreign_key({ null = true }) },
            { "action",      types.varchar },             -- view, create, update, delete, export, share, access_granted, access_revoked, login, consent
            { "resource_type", types.varchar },            -- patient, care_plan, medication, document, access_control, etc.
            { "resource_id", types.integer({ null = true }) },
            { "resource_uuid", types.varchar({ null = true }) },
            { "changes",     types.text({ null = true }) }, -- JSON: {field: {old: x, new: y}}
            { "ip_address",  types.varchar({ null = true }) },
            { "user_agent",  types.text({ null = true }) },
            { "session_id",  types.varchar({ null = true }) },
            { "access_context", types.varchar({ null = true }) }, -- direct, delegated, emergency, api
            { "consent_reference", types.varchar({ null = true }) },
            { "data_categories_accessed", types.text({ null = true }) }, -- JSON array
            { "request_id",  types.varchar({ null = true }) },
            { "status",      types.varchar({ default = "success" }) }, -- success, failure, denied
            { "failure_reason", types.text({ null = true }) },
            { "created_at",  types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        schema.create_index("patient_audit_logs", "patient_id")
        schema.create_index("patient_audit_logs", "user_id")
        schema.create_index("patient_audit_logs", "action")
        schema.create_index("patient_audit_logs", "resource_type")
        schema.create_index("patient_audit_logs", "created_at")
        schema.create_index("patient_audit_logs", "ip_address")
        schema.create_index("patient_audit_logs", "access_context")
    end
}

for i, fn in pairs(migrations) do
    migrations[i] = require_hospitals(fn)
end

return migrations
