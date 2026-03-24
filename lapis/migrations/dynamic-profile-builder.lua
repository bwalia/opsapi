--[[
  Dynamic Profile Builder System Migrations

  Database schema for a configurable, database-driven user profile builder.
  Admins define profile categories, questions, answer types, rules, and tags.
  End users fill in dynamic profiles rendered from DB configuration.

  These migrations are only executed when PROJECT_CODE includes 'tax_copilot'.

  Tables created:
  - profile_categories            : Top-level profile sections (Personal, Business, etc.)
  - profile_questions             : Dynamic questions within categories
  - profile_question_versions     : Version history when questions are edited
  - profile_question_options      : Predefined answer options for select-type questions
  - profile_question_rules        : Conditional display/visibility rules
  - profile_lookup_tables         : Named lookup/reference tables
  - profile_lookup_values         : Values within lookup tables
  - user_profile_answers          : Current user answers (latest state)
  - user_profile_answer_history   : Full audit trail of answer changes
  - profile_tags                  : Tag definitions for user segmentation
  - user_profile_tags             : Many-to-many user<->tag assignments
  - profile_tag_rules             : Auto-tagging rules based on answers
  - profile_completion_status     : Per-user per-category completion tracking
  - profile_touchpoints           : Touchpoint/campaign definitions (onboarding, review, etc.)
  - profile_question_touchpoints  : Links questions to touchpoints
  - profile_audit_logs            : Audit trail for admin config changes
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local MigrationUtils = require "helper.migration-utils"

return {
    -- ==========================================================================
    -- 1. profile_categories
    -- ==========================================================================
    [1] = function()
        schema.create_table("profile_categories", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer({ null = true }) },
            { "name", types.varchar },
            { "slug", types.varchar({ unique = true }) },
            { "description", types.text({ null = true }) },
            { "icon", types.varchar({ null = true }) },
            { "display_order", types.integer({ default = 0 }) },
            { "parent_id", types.integer({ null = true }) },
            { "is_active", types.boolean({ default = true }) },
            { "is_archived", types.boolean({ default = false }) },
            { "visibility_rule_json", types.text({ null = true }) },
            { "completion_rule_json", types.text({ null = true }) },
            { "created_by", types.integer({ null = true }) },
            { "updated_by", types.integer({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
    end,

    [2] = function()
        schema.create_index("profile_categories", "namespace_id")
        schema.create_index("profile_categories", "slug")
        schema.create_index("profile_categories", "parent_id")
        schema.create_index("profile_categories", "is_active")
        schema.create_index("profile_categories", "display_order")
    end,

    -- ==========================================================================
    -- 3. profile_questions
    -- ==========================================================================
    [3] = function()
        schema.create_table("profile_questions", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer({ null = true }) },
            { "category_id", types.integer },
            { "question_key", types.varchar },
            { "label", types.varchar },
            { "description", types.text({ null = true }) },
            { "help_text", types.text({ null = true }) },
            { "placeholder", types.varchar({ null = true }) },
            { "question_type", types.varchar },
            { "is_required", types.boolean({ default = false }) },
            { "is_multi_value", types.boolean({ default = false }) },
            { "is_editable_by_user", types.boolean({ default = true }) },
            { "display_order", types.integer({ default = 0 }) },
            { "validation_json", types.text({ null = true }) },
            { "default_value", types.text({ null = true }) },
            { "config_json", types.text({ null = true }) },
            { "lookup_table_id", types.integer({ null = true }) },
            { "version", types.integer({ default = 1 }) },
            { "is_active", types.boolean({ default = true }) },
            { "is_archived", types.boolean({ default = false }) },
            { "created_by", types.integer({ null = true }) },
            { "updated_by", types.integer({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE profile_questions ADD CONSTRAINT fk_pq_category FOREIGN KEY (category_id) REFERENCES profile_categories(id) ON DELETE CASCADE")
    end,

    [4] = function()
        schema.create_index("profile_questions", "namespace_id")
        schema.create_index("profile_questions", "category_id")
        schema.create_index("profile_questions", "question_key")
        schema.create_index("profile_questions", "question_type")
        schema.create_index("profile_questions", "is_active")
        schema.create_index("profile_questions", "display_order")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_pq_key_ns ON profile_questions (question_key, namespace_id) WHERE namespace_id IS NOT NULL")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_pq_key_global ON profile_questions (question_key) WHERE namespace_id IS NULL")
    end,

    -- question_type CHECK constraint
    [5] = function()
        pcall(function()
            db.query([[
                ALTER TABLE profile_questions ADD CONSTRAINT chk_question_type
                CHECK (question_type IN (
                    'short_text', 'long_text', 'number', 'currency', 'percentage',
                    'date', 'year', 'boolean', 'single_select', 'multi_select',
                    'radio', 'checkbox_group', 'file_upload', 'searchable_select',
                    'relational_select', 'repeating_group', 'tag_selector',
                    'address', 'phone', 'email'
                ))
            ]])
        end)
    end,

    -- ==========================================================================
    -- 6. profile_question_versions (history when question config changes)
    -- ==========================================================================
    [6] = function()
        schema.create_table("profile_question_versions", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "question_id", types.integer },
            { "version", types.integer },
            { "label", types.varchar },
            { "description", types.text({ null = true }) },
            { "question_type", types.varchar },
            { "is_required", types.boolean },
            { "validation_json", types.text({ null = true }) },
            { "config_json", types.text({ null = true }) },
            { "changed_by", types.integer({ null = true }) },
            { "change_reason", types.text({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE profile_question_versions ADD CONSTRAINT fk_pqv_question FOREIGN KEY (question_id) REFERENCES profile_questions(id) ON DELETE CASCADE")
        schema.create_index("profile_question_versions", "question_id")
        schema.create_index("profile_question_versions", "version")
    end,

    -- ==========================================================================
    -- 7. profile_question_options (predefined answers for select-type questions)
    -- ==========================================================================
    [7] = function()
        schema.create_table("profile_question_options", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "question_id", types.integer },
            { "label", types.varchar },
            { "value", types.varchar },
            { "description", types.text({ null = true }) },
            { "display_order", types.integer({ default = 0 }) },
            { "is_default", types.boolean({ default = false }) },
            { "is_active", types.boolean({ default = true }) },
            { "parent_option_id", types.integer({ null = true }) },
            { "metadata_json", types.text({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE profile_question_options ADD CONSTRAINT fk_pqo_question FOREIGN KEY (question_id) REFERENCES profile_questions(id) ON DELETE CASCADE")
        db.query("ALTER TABLE profile_question_options ADD CONSTRAINT fk_pqo_parent FOREIGN KEY (parent_option_id) REFERENCES profile_question_options(id) ON DELETE SET NULL")
        schema.create_index("profile_question_options", "question_id")
        schema.create_index("profile_question_options", "parent_option_id")
        schema.create_index("profile_question_options", "is_active")
        schema.create_index("profile_question_options", "display_order")
    end,

    -- ==========================================================================
    -- 8. profile_lookup_tables
    -- ==========================================================================
    [8] = function()
        schema.create_table("profile_lookup_tables", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer({ null = true }) },
            { "name", types.varchar },
            { "slug", types.varchar({ unique = true }) },
            { "description", types.text({ null = true }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("profile_lookup_tables", "slug")
        schema.create_index("profile_lookup_tables", "namespace_id")
    end,

    -- ==========================================================================
    -- 9. profile_lookup_values
    -- ==========================================================================
    [9] = function()
        schema.create_table("profile_lookup_values", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "lookup_table_id", types.integer },
            { "label", types.varchar },
            { "value", types.varchar },
            { "display_order", types.integer({ default = 0 }) },
            { "parent_value_id", types.integer({ null = true }) },
            { "is_active", types.boolean({ default = true }) },
            { "metadata_json", types.text({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE profile_lookup_values ADD CONSTRAINT fk_plv_table FOREIGN KEY (lookup_table_id) REFERENCES profile_lookup_tables(id) ON DELETE CASCADE")
        schema.create_index("profile_lookup_values", "lookup_table_id")
        schema.create_index("profile_lookup_values", "is_active")
    end,

    -- ==========================================================================
    -- 10. profile_question_rules (conditional display logic)
    -- ==========================================================================
    [10] = function()
        schema.create_table("profile_question_rules", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "question_id", types.integer },
            { "rule_name", types.varchar({ null = true }) },
            { "rule_type", types.varchar },
            { "operator", types.varchar },
            { "logic_group", types.varchar },
            { "source_question_id", types.integer({ null = true }) },
            { "source_field", types.varchar({ null = true }) },
            { "expected_value", types.text({ null = true }) },
            { "expected_values_json", types.text({ null = true }) },
            { "priority", types.integer({ default = 0 }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_by", types.integer({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        -- Set proper defaults via raw SQL (Lapis types.varchar double-escapes quoted defaults)
        db.query("ALTER TABLE profile_question_rules ALTER COLUMN rule_type SET DEFAULT 'visibility'")
        db.query("ALTER TABLE profile_question_rules ALTER COLUMN logic_group SET DEFAULT 'AND'")
        db.query("ALTER TABLE profile_question_rules ADD CONSTRAINT fk_pqr_question FOREIGN KEY (question_id) REFERENCES profile_questions(id) ON DELETE CASCADE")
        db.query("ALTER TABLE profile_question_rules ADD CONSTRAINT fk_pqr_source FOREIGN KEY (source_question_id) REFERENCES profile_questions(id) ON DELETE SET NULL")
        schema.create_index("profile_question_rules", "question_id")
        schema.create_index("profile_question_rules", "source_question_id")
        schema.create_index("profile_question_rules", "is_active")

        pcall(function()
            db.query([[
                ALTER TABLE profile_question_rules ADD CONSTRAINT chk_rule_type
                CHECK (rule_type IN ('visibility', 'requirement', 'validation', 'skip', 'auto_fill'))
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE profile_question_rules ADD CONSTRAINT chk_operator
                CHECK (operator IN (
                    'equals', 'not_equals', 'greater_than', 'less_than',
                    'greater_than_or_equal', 'less_than_or_equal',
                    'contains', 'not_contains', 'in_list', 'not_in_list',
                    'is_empty', 'is_not_empty', 'starts_with', 'ends_with',
                    'matches_regex', 'between',
                    'category_complete', 'category_incomplete',
                    'has_tag', 'not_has_tag'
                ))
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE profile_question_rules ADD CONSTRAINT chk_logic_group
                CHECK (logic_group IN ('AND', 'OR'))
            ]])
        end)
    end,

    -- ==========================================================================
    -- 11. user_profile_answers (current state of each user's answers)
    -- ==========================================================================
    [11] = function()
        schema.create_table("user_profile_answers", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_id", types.integer },
            { "user_uuid", types.varchar },
            { "namespace_id", types.integer({ null = true }) },
            { "question_id", types.integer },
            { "question_version", types.integer({ default = 1 }) },
            { "answer_text", types.text({ null = true }) },
            { "answer_number", types.numeric({ null = true }) },
            { "answer_boolean", types.boolean({ null = true }) },
            { "answer_date", types.date({ null = true }) },
            { "answer_json", types.text({ null = true }) },
            { "answer_file_url", types.text({ null = true }) },
            { "is_draft", types.boolean({ default = false }) },
            { "answered_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE user_profile_answers ADD CONSTRAINT fk_upa_question FOREIGN KEY (question_id) REFERENCES profile_questions(id)")
        schema.create_index("user_profile_answers", "user_id")
        schema.create_index("user_profile_answers", "user_uuid")
        schema.create_index("user_profile_answers", "namespace_id")
        schema.create_index("user_profile_answers", "question_id")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_upa_user_question ON user_profile_answers (user_id, question_id)")
    end,

    -- ==========================================================================
    -- 12. user_profile_answer_history (audit trail of all answer changes)
    -- ==========================================================================
    [12] = function()
        schema.create_table("user_profile_answer_history", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "answer_id", types.integer },
            { "user_id", types.integer },
            { "question_id", types.integer },
            { "question_version", types.integer },
            { "old_answer_text", types.text({ null = true }) },
            { "old_answer_number", types.numeric({ null = true }) },
            { "old_answer_boolean", types.boolean({ null = true }) },
            { "old_answer_date", types.date({ null = true }) },
            { "old_answer_json", types.text({ null = true }) },
            { "new_answer_text", types.text({ null = true }) },
            { "new_answer_number", types.numeric({ null = true }) },
            { "new_answer_boolean", types.boolean({ null = true }) },
            { "new_answer_date", types.date({ null = true }) },
            { "new_answer_json", types.text({ null = true }) },
            { "changed_by", types.integer },
            { "change_source", types.varchar({ default = "'user'" }) },
            { "change_reason", types.text({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("user_profile_answer_history", "answer_id")
        schema.create_index("user_profile_answer_history", "user_id")
        schema.create_index("user_profile_answer_history", "question_id")
        schema.create_index("user_profile_answer_history", "created_at")
    end,

    -- ==========================================================================
    -- 13. profile_tags (tag definitions)
    -- ==========================================================================
    [13] = function()
        schema.create_table("profile_tags", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer({ null = true }) },
            { "name", types.varchar },
            { "slug", types.varchar },
            { "description", types.text({ null = true }) },
            { "color", types.varchar({ default = "'#6366f1'" }) },
            { "tag_type", types.varchar({ default = "'manual'" }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_by", types.integer({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("profile_tags", "namespace_id")
        schema.create_index("profile_tags", "slug")
        schema.create_index("profile_tags", "tag_type")
        schema.create_index("profile_tags", "is_active")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_pt_slug_ns ON profile_tags (slug, namespace_id) WHERE namespace_id IS NOT NULL")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_pt_slug_global ON profile_tags (slug) WHERE namespace_id IS NULL")

        pcall(function()
            db.query([[
                ALTER TABLE profile_tags ADD CONSTRAINT chk_tag_type
                CHECK (tag_type IN ('manual', 'auto', 'system', 'category'))
            ]])
        end)
    end,

    -- ==========================================================================
    -- 14. user_profile_tags (many-to-many user<->tag)
    -- ==========================================================================
    [14] = function()
        schema.create_table("user_profile_tags", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_id", types.integer },
            { "user_uuid", types.varchar },
            { "tag_id", types.integer },
            { "assigned_by", types.integer({ null = true }) },
            { "assignment_source", types.varchar({ default = "'manual'" }) },
            { "assignment_reason", types.text({ null = true }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE user_profile_tags ADD CONSTRAINT fk_upt_tag FOREIGN KEY (tag_id) REFERENCES profile_tags(id) ON DELETE CASCADE")
        schema.create_index("user_profile_tags", "user_id")
        schema.create_index("user_profile_tags", "user_uuid")
        schema.create_index("user_profile_tags", "tag_id")
        schema.create_index("user_profile_tags", "is_active")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_upt_user_tag ON user_profile_tags (user_id, tag_id)")
    end,

    -- ==========================================================================
    -- 15. profile_tag_rules (auto-tagging rules based on answers)
    -- ==========================================================================
    [15] = function()
        schema.create_table("profile_tag_rules", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "tag_id", types.integer },
            { "rule_name", types.varchar },
            { "description", types.text({ null = true }) },
            { "source_question_id", types.integer({ null = true }) },
            { "source_field", types.varchar({ null = true }) },
            { "operator", types.varchar },
            { "expected_value", types.text({ null = true }) },
            { "expected_values_json", types.text({ null = true }) },
            { "logic_group", types.varchar({ default = "'AND'" }) },
            { "priority", types.integer({ default = 0 }) },
            { "is_active", types.boolean({ default = true }) },
            { "created_by", types.integer({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE profile_tag_rules ADD CONSTRAINT fk_ptr_tag FOREIGN KEY (tag_id) REFERENCES profile_tags(id) ON DELETE CASCADE")
        db.query("ALTER TABLE profile_tag_rules ADD CONSTRAINT fk_ptr_source FOREIGN KEY (source_question_id) REFERENCES profile_questions(id) ON DELETE SET NULL")
        schema.create_index("profile_tag_rules", "tag_id")
        schema.create_index("profile_tag_rules", "source_question_id")
        schema.create_index("profile_tag_rules", "is_active")
    end,

    -- ==========================================================================
    -- 16. profile_completion_status (per user per category)
    -- ==========================================================================
    [16] = function()
        schema.create_table("profile_completion_status", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_id", types.integer },
            { "user_uuid", types.varchar },
            { "category_id", types.integer },
            { "total_questions", types.integer({ default = 0 }) },
            { "answered_questions", types.integer({ default = 0 }) },
            { "required_questions", types.integer({ default = 0 }) },
            { "required_answered", types.integer({ default = 0 }) },
            { "completion_percent", types.numeric({ default = 0 }) },
            { "status", types.varchar({ default = "'not_started'" }) },
            { "last_updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE profile_completion_status ADD CONSTRAINT fk_pcs_category FOREIGN KEY (category_id) REFERENCES profile_categories(id) ON DELETE CASCADE")
        schema.create_index("profile_completion_status", "user_id")
        schema.create_index("profile_completion_status", "user_uuid")
        schema.create_index("profile_completion_status", "category_id")
        schema.create_index("profile_completion_status", "status")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_pcs_user_cat ON profile_completion_status (user_id, category_id)")

        pcall(function()
            db.query([[
                ALTER TABLE profile_completion_status ADD CONSTRAINT chk_status
                CHECK (status IN ('not_started', 'in_progress', 'complete', 'needs_review'))
            ]])
        end)
    end,

    -- ==========================================================================
    -- 17. profile_touchpoints (onboarding, annual review, targeted campaigns)
    -- ==========================================================================
    [17] = function()
        schema.create_table("profile_touchpoints", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer({ null = true }) },
            { "name", types.varchar },
            { "slug", types.varchar({ unique = true }) },
            { "description", types.text({ null = true }) },
            { "touchpoint_type", types.varchar },
            { "is_active", types.boolean({ default = true }) },
            { "config_json", types.text({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            { "updated_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("profile_touchpoints", "slug")
        schema.create_index("profile_touchpoints", "touchpoint_type")

        pcall(function()
            db.query([[
                ALTER TABLE profile_touchpoints ADD CONSTRAINT chk_touchpoint_type
                CHECK (touchpoint_type IN ('onboarding', 'profile_completion', 'annual_review', 'targeted_campaign', 'enrichment'))
            ]])
        end)
    end,

    -- ==========================================================================
    -- 18. profile_question_touchpoints (links questions to touchpoints)
    -- ==========================================================================
    [18] = function()
        schema.create_table("profile_question_touchpoints", {
            { "id", types.serial },
            { "question_id", types.integer },
            { "touchpoint_id", types.integer },
            { "display_order", types.integer({ default = 0 }) },
            { "is_required_in_touchpoint", types.boolean({ default = false }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        db.query("ALTER TABLE profile_question_touchpoints ADD CONSTRAINT fk_pqt_question FOREIGN KEY (question_id) REFERENCES profile_questions(id) ON DELETE CASCADE")
        db.query("ALTER TABLE profile_question_touchpoints ADD CONSTRAINT fk_pqt_touchpoint FOREIGN KEY (touchpoint_id) REFERENCES profile_touchpoints(id) ON DELETE CASCADE")
        schema.create_index("profile_question_touchpoints", "question_id")
        schema.create_index("profile_question_touchpoints", "touchpoint_id")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_pqt_q_tp ON profile_question_touchpoints (question_id, touchpoint_id)")
    end,

    -- ==========================================================================
    -- 19. profile_audit_logs (admin config changes)
    -- ==========================================================================
    [19] = function()
        schema.create_table("profile_audit_logs", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.integer({ null = true }) },
            { "user_id", types.integer },
            { "action", types.varchar },
            { "entity_type", types.varchar },
            { "entity_id", types.integer({ null = true }) },
            { "entity_uuid", types.varchar({ null = true }) },
            { "old_data_json", types.text({ null = true }) },
            { "new_data_json", types.text({ null = true }) },
            { "ip_address", types.varchar({ null = true }) },
            { "user_agent", types.text({ null = true }) },
            { "created_at", types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("profile_audit_logs", "user_id")
        schema.create_index("profile_audit_logs", "entity_type")
        schema.create_index("profile_audit_logs", "entity_id")
        schema.create_index("profile_audit_logs", "created_at")
        schema.create_index("profile_audit_logs", "action")
    end,

    -- ==========================================================================
    -- 20. Seed default touchpoints
    -- ==========================================================================
    [20] = function()
        local touchpoints = {
            { name = "Onboarding", slug = "onboarding", touchpoint_type = "onboarding", description = "Initial user onboarding questionnaire" },
            { name = "Profile Completion", slug = "profile-completion", touchpoint_type = "profile_completion", description = "Progressive profile completion prompts" },
            { name = "Annual Review", slug = "annual-review", touchpoint_type = "annual_review", description = "Yearly profile revalidation" },
            { name = "Enrichment", slug = "enrichment", touchpoint_type = "enrichment", description = "Additional data collection for existing users" },
        }
        for _, tp in ipairs(touchpoints) do
            local exists = db.select("id FROM profile_touchpoints WHERE slug = ?", tp.slug)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_touchpoints (uuid, name, slug, description, touchpoint_type, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), tp.name, tp.slug, tp.description, tp.touchpoint_type)
            end
        end
    end,

    -- ==========================================================================
    -- 21. Seed sample profile categories
    -- ==========================================================================
    [21] = function()
        local categories = {
            { name = "Personal Information", slug = "personal-information", description = "Basic personal details", icon = "user", display_order = 1 },
            { name = "Contact Details", slug = "contact-details", description = "Phone, email and address information", icon = "phone", display_order = 2 },
            { name = "Education", slug = "education", description = "Educational qualifications and certifications", icon = "graduation-cap", display_order = 3 },
            { name = "Employment", slug = "employment", description = "Employment status and history", icon = "briefcase", display_order = 4 },
            { name = "Business Profile", slug = "business-profile", description = "Business and self-employment details", icon = "building", display_order = 5 },
            { name = "Property / Rental Profile", slug = "property-rental", description = "Property ownership and rental income", icon = "home", display_order = 6 },
            { name = "Financial / Tax Information", slug = "financial-tax", description = "Tax and financial profile", icon = "pound-sign", display_order = 7 },
            { name = "Compliance", slug = "compliance", description = "Regulatory compliance information", icon = "shield", display_order = 8 },
            { name = "Preferences", slug = "preferences", description = "Communication and service preferences", icon = "settings", display_order = 9 },
        }
        for _, cat in ipairs(categories) do
            local exists = db.select("id FROM profile_categories WHERE slug = ?", cat.slug)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_categories (uuid, name, slug, description, icon, display_order, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), cat.name, cat.slug, cat.description, cat.icon, cat.display_order)
            end
        end
    end,

    -- ==========================================================================
    -- 22. Seed sample questions: Business Profile
    -- ==========================================================================
    [22] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'business-profile'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "is_self_employed", label = "Are you self-employed?",
                question_type = "boolean", is_required = true, display_order = 1,
                help_text = "Select yes if you earn income from self-employment"
            },
            {
                question_key = "business_type", label = "Business type",
                question_type = "single_select", is_required = true, display_order = 2,
                help_text = "Select the legal structure of your business"
            },
            {
                question_key = "business_name", label = "Business name",
                question_type = "short_text", is_required = false, display_order = 3,
                placeholder = "Enter your business trading name"
            },
            {
                question_key = "num_employees", label = "Number of employees",
                question_type = "number", is_required = false, display_order = 4,
                help_text = "Total number of people you employ"
            },
            {
                question_key = "annual_turnover_band", label = "Annual turnover range",
                question_type = "single_select", is_required = false, display_order = 5
            },
            {
                question_key = "vat_registered", label = "Are you VAT registered?",
                question_type = "boolean", is_required = false, display_order = 6
            },
            {
                question_key = "industry_sector", label = "Industry sector",
                question_type = "searchable_select", is_required = false, display_order = 7
            },
        }

        for _, q in ipairs(questions) do
            local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_questions (uuid, category_id, question_key, label, description, help_text, placeholder, question_type, is_required, display_order, is_active, version, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, 1, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label, q.description or "", q.help_text or "", q.placeholder or "", q.question_type, q.is_required, q.display_order)
            end
        end
    end,

    -- ==========================================================================
    -- 23. Seed sample options for Business Profile questions
    -- ==========================================================================
    [23] = function()
        -- Business type options
        local bt = db.select("id FROM profile_questions WHERE question_key = 'business_type'")
        if bt and #bt > 0 then
            local bt_id = bt[1].id
            local options = {
                { label = "Sole Trader", value = "sole_trader", display_order = 1 },
                { label = "Limited Company", value = "limited_company", display_order = 2 },
                { label = "Partnership", value = "partnership", display_order = 3 },
                { label = "LLP", value = "llp", display_order = 4 },
                { label = "Other", value = "other", display_order = 5 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", bt_id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), bt_id, opt.label, opt.value, opt.display_order)
                end
            end
        end

        -- Annual turnover band options
        local at = db.select("id FROM profile_questions WHERE question_key = 'annual_turnover_band'")
        if at and #at > 0 then
            local at_id = at[1].id
            local options = {
                { label = "Under £10,000", value = "under_10k", display_order = 1 },
                { label = "£10,000 - £50,000", value = "10k_50k", display_order = 2 },
                { label = "£50,000 - £100,000", value = "50k_100k", display_order = 3 },
                { label = "£100,000 - £500,000", value = "100k_500k", display_order = 4 },
                { label = "£500,000 - £1,000,000", value = "500k_1m", display_order = 5 },
                { label = "Over £1,000,000", value = "over_1m", display_order = 6 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", at_id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), at_id, opt.label, opt.value, opt.display_order)
                end
            end
        end
    end,

    -- ==========================================================================
    -- 24. Seed sample questions: Property / Rental Profile
    -- ==========================================================================
    [24] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'property-rental'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "rents_properties", label = "Do you rent out any properties?",
                question_type = "boolean", is_required = true, display_order = 1,
                help_text = "Select yes if you receive rental income from any property"
            },
            {
                question_key = "num_rental_properties", label = "How many properties do you rent?",
                question_type = "number", is_required = true, display_order = 2,
                help_text = "Total number of properties you rent out"
            },
            {
                question_key = "property_ownership_type", label = "Property ownership type",
                question_type = "single_select", is_required = false, display_order = 3
            },
            {
                question_key = "rental_income_band", label = "Annual rental income range",
                question_type = "single_select", is_required = false, display_order = 4
            },
        }

        for _, q in ipairs(questions) do
            local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_questions (uuid, category_id, question_key, label, description, help_text, placeholder, question_type, is_required, display_order, is_active, version, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, 1, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label, q.description or "", q.help_text or "", q.placeholder or "", q.question_type, q.is_required, q.display_order)
            end
        end

        -- Options for property_ownership_type
        local pot = db.select("id FROM profile_questions WHERE question_key = 'property_ownership_type'")
        if pot and #pot > 0 then
            local pot_id = pot[1].id
            local options = {
                { label = "Sole ownership", value = "sole", display_order = 1 },
                { label = "Joint ownership", value = "joint", display_order = 2 },
                { label = "Company-owned", value = "company", display_order = 3 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", pot_id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), pot_id, opt.label, opt.value, opt.display_order)
                end
            end
        end

        -- Options for rental_income_band
        local rib = db.select("id FROM profile_questions WHERE question_key = 'rental_income_band'")
        if rib and #rib > 0 then
            local rib_id = rib[1].id
            local options = {
                { label = "Under £5,000", value = "under_5k", display_order = 1 },
                { label = "£5,000 - £15,000", value = "5k_15k", display_order = 2 },
                { label = "£15,000 - £50,000", value = "15k_50k", display_order = 3 },
                { label = "£50,000 - £100,000", value = "50k_100k", display_order = 4 },
                { label = "Over £100,000", value = "over_100k", display_order = 5 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", rib_id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), rib_id, opt.label, opt.value, opt.display_order)
                end
            end
        end
    end,

    -- ==========================================================================
    -- 25. Seed sample questions: Education
    -- ==========================================================================
    [25] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'education'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "highest_qualification", label = "Highest education qualification",
                question_type = "single_select", is_required = false, display_order = 1
            },
            {
                question_key = "professional_certs", label = "Professional certifications",
                question_type = "multi_select", is_required = false, display_order = 2,
                help_text = "Select all that apply"
            },
            {
                question_key = "field_of_study", label = "Field of study",
                question_type = "short_text", is_required = false, display_order = 3,
                placeholder = "e.g. Computer Science, Accounting"
            },
        }

        for _, q in ipairs(questions) do
            local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_questions (uuid, category_id, question_key, label, description, help_text, placeholder, question_type, is_required, display_order, is_active, version, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, 1, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label, q.description or "", q.help_text or "", q.placeholder or "", q.question_type, q.is_required, q.display_order)
            end
        end

        -- Options for highest_qualification
        local hq = db.select("id FROM profile_questions WHERE question_key = 'highest_qualification'")
        if hq and #hq > 0 then
            local hq_id = hq[1].id
            local options = {
                { label = "GCSE", value = "gcse", display_order = 1 },
                { label = "A-Level", value = "a_level", display_order = 2 },
                { label = "Diploma", value = "diploma", display_order = 3 },
                { label = "Bachelor's Degree", value = "bachelors", display_order = 4 },
                { label = "Master's Degree", value = "masters", display_order = 5 },
                { label = "PhD / Doctorate", value = "phd", display_order = 6 },
                { label = "Professional Qualification", value = "professional", display_order = 7 },
                { label = "Other", value = "other", display_order = 8 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", hq_id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), hq_id, opt.label, opt.value, opt.display_order)
                end
            end
        end
    end,

    -- ==========================================================================
    -- 26. Seed conditional rules
    -- ==========================================================================
    [26] = function()
        -- Rule: Show "How many properties do you rent?" only if "Do you rent out any properties?" = true
        local source_q = db.select("id FROM profile_questions WHERE question_key = 'rents_properties'")
        local target_q = db.select("id FROM profile_questions WHERE question_key = 'num_rental_properties'")
        if source_q and #source_q > 0 and target_q and #target_q > 0 then
            local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", target_q[1].id, source_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, 'visibility', 'equals', 'AND', ?, 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), target_q[1].id, "Show if rents properties", source_q[1].id)
            end
        end

        -- Rule: Show property_ownership_type only if rents_properties = true
        local pot_q = db.select("id FROM profile_questions WHERE question_key = 'property_ownership_type'")
        if source_q and #source_q > 0 and pot_q and #pot_q > 0 then
            local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", pot_q[1].id, source_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, 'visibility', 'equals', 'AND', ?, 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), pot_q[1].id, "Show if rents properties", source_q[1].id)
            end
        end

        -- Rule: Show rental_income_band only if rents_properties = true
        local rib_q = db.select("id FROM profile_questions WHERE question_key = 'rental_income_band'")
        if source_q and #source_q > 0 and rib_q and #rib_q > 0 then
            local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", rib_q[1].id, source_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, 'visibility', 'equals', 'AND', ?, 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), rib_q[1].id, "Show if rents properties", source_q[1].id)
            end
        end

        -- Rule: Show "Business type" only if "Are you self-employed?" = true
        local se_q = db.select("id FROM profile_questions WHERE question_key = 'is_self_employed'")
        local bt_q = db.select("id FROM profile_questions WHERE question_key = 'business_type'")
        if se_q and #se_q > 0 and bt_q and #bt_q > 0 then
            local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", bt_q[1].id, se_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, 'visibility', 'equals', 'AND', ?, 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), bt_q[1].id, "Show if self-employed", se_q[1].id)
            end
        end

        -- Rule: Show business_name, num_employees, annual_turnover, vat_registered, industry_sector only if self-employed
        local dependent_keys = { "business_name", "num_employees", "annual_turnover_band", "vat_registered", "industry_sector" }
        if se_q and #se_q > 0 then
            for _, key in ipairs(dependent_keys) do
                local dep_q = db.select("id FROM profile_questions WHERE question_key = ?", key)
                if dep_q and #dep_q > 0 then
                    local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", dep_q[1].id, se_q[1].id)
                    if not exists or #exists == 0 then
                        db.query([[
                            INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, source_question_id, expected_value, is_active, created_at, updated_at)
                            VALUES (?, ?, ?, 'visibility', 'equals', ?, 'true', true, NOW(), NOW())
                        ]], MigrationUtils.generateUUID(), dep_q[1].id, "Show if self-employed", se_q[1].id)
                    end
                end
            end
        end
    end,

    -- ==========================================================================
    -- 27. Seed auto-tagging rules
    -- ==========================================================================
    [27] = function()
        -- Create default tags
        local tags = {
            { name = "Landlord", slug = "landlord", color = "#10b981", tag_type = "auto", description = "User rents out properties" },
            { name = "Self-Employed", slug = "self-employed", color = "#6366f1", tag_type = "auto", description = "User is self-employed" },
            { name = "Business Owner", slug = "business-owner", color = "#8b5cf6", tag_type = "auto", description = "User owns a business" },
            { name = "Limited Company", slug = "limited-company", color = "#3b82f6", tag_type = "auto", description = "User has a limited company" },
            { name = "VAT Registered", slug = "vat-registered", color = "#f59e0b", tag_type = "auto", description = "User is VAT registered" },
            { name = "High Value Customer", slug = "high-value-customer", color = "#ef4444", tag_type = "manual", description = "Manually tagged high-value customer" },
            { name = "Incomplete Profile", slug = "incomplete-profile", color = "#9ca3af", tag_type = "system", description = "Profile has required categories incomplete" },
            { name = "Student", slug = "student", color = "#14b8a6", tag_type = "auto", description = "User is a student" },
            { name = "Property Investor", slug = "property-investor", color = "#f97316", tag_type = "auto", description = "User rents multiple properties" },
        }

        for _, tag in ipairs(tags) do
            local exists = db.select("id FROM profile_tags WHERE slug = ?", tag.slug)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_tags (uuid, name, slug, description, color, tag_type, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), tag.name, tag.slug, tag.description, tag.color, tag.tag_type)
            end
        end

        -- Auto-tag rule: Assign "landlord" if rents_properties = true
        local landlord_tag = db.select("id FROM profile_tags WHERE slug = 'landlord'")
        local rents_q = db.select("id FROM profile_questions WHERE question_key = 'rents_properties'")
        if landlord_tag and #landlord_tag > 0 and rents_q and #rents_q > 0 then
            local exists = db.select("id FROM profile_tag_rules WHERE tag_id = ? AND source_question_id = ?", landlord_tag[1].id, rents_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_tag_rules (uuid, tag_id, rule_name, source_question_id, operator, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'equals', 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), landlord_tag[1].id, "Auto-tag landlord", rents_q[1].id)
            end
        end

        -- Auto-tag rule: Assign "self-employed" if is_self_employed = true
        local se_tag = db.select("id FROM profile_tags WHERE slug = 'self-employed'")
        local se_q = db.select("id FROM profile_questions WHERE question_key = 'is_self_employed'")
        if se_tag and #se_tag > 0 and se_q and #se_q > 0 then
            local exists = db.select("id FROM profile_tag_rules WHERE tag_id = ? AND source_question_id = ?", se_tag[1].id, se_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_tag_rules (uuid, tag_id, rule_name, source_question_id, operator, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'equals', 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), se_tag[1].id, "Auto-tag self-employed", se_q[1].id)
            end
        end

        -- Auto-tag rule: Assign "limited-company" if business_type = limited_company
        local lc_tag = db.select("id FROM profile_tags WHERE slug = 'limited-company'")
        local bt_q = db.select("id FROM profile_questions WHERE question_key = 'business_type'")
        if lc_tag and #lc_tag > 0 and bt_q and #bt_q > 0 then
            local exists = db.select("id FROM profile_tag_rules WHERE tag_id = ? AND source_question_id = ?", lc_tag[1].id, bt_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_tag_rules (uuid, tag_id, rule_name, source_question_id, operator, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'equals', 'limited_company', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), lc_tag[1].id, "Auto-tag limited company", bt_q[1].id)
            end
        end

        -- Auto-tag rule: Assign "vat-registered" if vat_registered = true
        local vat_tag = db.select("id FROM profile_tags WHERE slug = 'vat-registered'")
        local vat_q = db.select("id FROM profile_questions WHERE question_key = 'vat_registered'")
        if vat_tag and #vat_tag > 0 and vat_q and #vat_q > 0 then
            local exists = db.select("id FROM profile_tag_rules WHERE tag_id = ? AND source_question_id = ?", vat_tag[1].id, vat_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_tag_rules (uuid, tag_id, rule_name, source_question_id, operator, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'equals', 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), vat_tag[1].id, "Auto-tag VAT registered", vat_q[1].id)
            end
        end

        -- Auto-tag rule: Assign "property-investor" if num_rental_properties > 1
        local pi_tag = db.select("id FROM profile_tags WHERE slug = 'property-investor'")
        local nrp_q = db.select("id FROM profile_questions WHERE question_key = 'num_rental_properties'")
        if pi_tag and #pi_tag > 0 and nrp_q and #nrp_q > 0 then
            local exists = db.select("id FROM profile_tag_rules WHERE tag_id = ? AND source_question_id = ?", pi_tag[1].id, nrp_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_tag_rules (uuid, tag_id, rule_name, source_question_id, operator, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'greater_than', '1', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), pi_tag[1].id, "Auto-tag property investor", nrp_q[1].id)
            end
        end
    end,
}
