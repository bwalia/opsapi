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
                            INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, expected_value, is_active, created_at, updated_at)
                            VALUES (?, ?, ?, 'visibility', 'equals', 'AND', ?, 'true', true, NOW(), NOW())
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

    -- ==========================================================================
    -- 28. Seed questions: Personal Information
    -- ==========================================================================
    [28] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'personal-information'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "title", label = "Title",
                question_type = "single_select", is_required = false, display_order = 1,
                help_text = "How would you like to be addressed?"
            },
            {
                question_key = "first_name", label = "First name",
                question_type = "short_text", is_required = true, display_order = 2,
                placeholder = "Enter your first name"
            },
            {
                question_key = "middle_name", label = "Middle name(s)",
                question_type = "short_text", is_required = false, display_order = 3,
                placeholder = "Enter your middle name(s) if any"
            },
            {
                question_key = "last_name", label = "Last name",
                question_type = "short_text", is_required = true, display_order = 4,
                placeholder = "Enter your last name"
            },
            {
                question_key = "date_of_birth", label = "Date of birth",
                question_type = "date", is_required = true, display_order = 5,
                help_text = "Used for tax year calculations and HMRC submissions"
            },
            {
                question_key = "gender", label = "Gender",
                question_type = "single_select", is_required = false, display_order = 6
            },
            {
                question_key = "marital_status", label = "Marital status",
                question_type = "single_select", is_required = false, display_order = 7,
                help_text = "This may affect your tax allowances"
            },
            {
                question_key = "nationality", label = "Nationality",
                question_type = "short_text", is_required = false, display_order = 8,
                placeholder = "e.g. British, Irish"
            },
            {
                question_key = "nino", label = "National Insurance Number (NINO)",
                question_type = "short_text", is_required = false, display_order = 9,
                help_text = "Format: AA 12 34 56 A. Required for HMRC submissions.",
                placeholder = "e.g. QQ 12 34 56 C"
            },
            {
                question_key = "utr_number", label = "Unique Taxpayer Reference (UTR)",
                question_type = "short_text", is_required = false, display_order = 10,
                help_text = "10-digit number from HMRC. Required for Self Assessment.",
                placeholder = "e.g. 1234567890"
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

        -- Title options
        local title_q = db.select("id FROM profile_questions WHERE question_key = 'title'")
        if title_q and #title_q > 0 then
            local options = {
                { label = "Mr", value = "mr", display_order = 1 },
                { label = "Mrs", value = "mrs", display_order = 2 },
                { label = "Miss", value = "miss", display_order = 3 },
                { label = "Ms", value = "ms", display_order = 4 },
                { label = "Dr", value = "dr", display_order = 5 },
                { label = "Other", value = "other", display_order = 6 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", title_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), title_q[1].id, opt.label, opt.value, opt.display_order)
                end
            end
        end

        -- Gender options
        local gender_q = db.select("id FROM profile_questions WHERE question_key = 'gender'")
        if gender_q and #gender_q > 0 then
            local options = {
                { label = "Male", value = "male", display_order = 1 },
                { label = "Female", value = "female", display_order = 2 },
                { label = "Non-binary", value = "non_binary", display_order = 3 },
                { label = "Prefer not to say", value = "prefer_not_to_say", display_order = 4 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", gender_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), gender_q[1].id, opt.label, opt.value, opt.display_order)
                end
            end
        end

        -- Marital status options
        local ms_q = db.select("id FROM profile_questions WHERE question_key = 'marital_status'")
        if ms_q and #ms_q > 0 then
            local options = {
                { label = "Single", value = "single", display_order = 1 },
                { label = "Married", value = "married", display_order = 2 },
                { label = "Civil Partnership", value = "civil_partnership", display_order = 3 },
                { label = "Divorced", value = "divorced", display_order = 4 },
                { label = "Widowed", value = "widowed", display_order = 5 },
                { label = "Separated", value = "separated", display_order = 6 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", ms_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), ms_q[1].id, opt.label, opt.value, opt.display_order)
                end
            end
        end
    end,

    -- ==========================================================================
    -- 29. Seed questions: Contact Details
    -- ==========================================================================
    [29] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'contact-details'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "email_address", label = "Email address",
                question_type = "email", is_required = true, display_order = 1,
                placeholder = "you@example.com"
            },
            {
                question_key = "phone_mobile", label = "Mobile phone number",
                question_type = "phone", is_required = true, display_order = 2,
                placeholder = "e.g. 07700 900000"
            },
            {
                question_key = "phone_home", label = "Home phone number",
                question_type = "phone", is_required = false, display_order = 3,
                placeholder = "e.g. 020 7946 0958"
            },
            {
                question_key = "address_line_1", label = "Address line 1",
                question_type = "short_text", is_required = true, display_order = 4,
                placeholder = "House number and street"
            },
            {
                question_key = "address_line_2", label = "Address line 2",
                question_type = "short_text", is_required = false, display_order = 5,
                placeholder = "Flat, apartment, suite (optional)"
            },
            {
                question_key = "city", label = "City / Town",
                question_type = "short_text", is_required = true, display_order = 6,
                placeholder = "e.g. London"
            },
            {
                question_key = "county", label = "County",
                question_type = "short_text", is_required = false, display_order = 7,
                placeholder = "e.g. Greater London"
            },
            {
                question_key = "postcode", label = "Postcode",
                question_type = "short_text", is_required = true, display_order = 8,
                placeholder = "e.g. SW1A 1AA"
            },
            {
                question_key = "country", label = "Country",
                question_type = "single_select", is_required = true, display_order = 9
            },
            {
                question_key = "preferred_contact_method", label = "Preferred contact method",
                question_type = "single_select", is_required = false, display_order = 10,
                help_text = "How would you prefer us to reach you?"
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

        -- Country options (UK-focused)
        local country_q = db.select("id FROM profile_questions WHERE question_key = 'country'")
        if country_q and #country_q > 0 then
            local options = {
                { label = "United Kingdom", value = "GB", display_order = 1, is_default = true },
                { label = "Ireland", value = "IE", display_order = 2 },
                { label = "United States", value = "US", display_order = 3 },
                { label = "India", value = "IN", display_order = 4 },
                { label = "Pakistan", value = "PK", display_order = 5 },
                { label = "Other", value = "other", display_order = 6 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", country_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_default, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), country_q[1].id, opt.label, opt.value, opt.display_order, opt.is_default or false)
                end
            end
        end

        -- Preferred contact method options
        local pcm_q = db.select("id FROM profile_questions WHERE question_key = 'preferred_contact_method'")
        if pcm_q and #pcm_q > 0 then
            local options = {
                { label = "Email", value = "email", display_order = 1, is_default = true },
                { label = "Phone", value = "phone", display_order = 2 },
                { label = "SMS", value = "sms", display_order = 3 },
                { label = "Post", value = "post", display_order = 4 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", pcm_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_default, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), pcm_q[1].id, opt.label, opt.value, opt.display_order, opt.is_default or false)
                end
            end
        end
    end,

    -- ==========================================================================
    -- 30. Seed questions: Employment
    -- ==========================================================================
    [30] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'employment'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "employment_status", label = "Employment status",
                question_type = "single_select", is_required = true, display_order = 1,
                help_text = "Select your current employment status"
            },
            {
                question_key = "employer_name", label = "Employer name",
                question_type = "short_text", is_required = false, display_order = 2,
                placeholder = "Enter your employer's name"
            },
            {
                question_key = "job_title", label = "Job title",
                question_type = "short_text", is_required = false, display_order = 3,
                placeholder = "e.g. Software Engineer, Accountant"
            },
            {
                question_key = "employment_start_date", label = "Employment start date",
                question_type = "date", is_required = false, display_order = 4,
                help_text = "When did you start your current employment?"
            },
            {
                question_key = "annual_salary_band", label = "Annual salary range",
                question_type = "single_select", is_required = false, display_order = 5,
                help_text = "Your gross annual salary before tax"
            },
            {
                question_key = "has_other_income", label = "Do you have other sources of income?",
                question_type = "boolean", is_required = false, display_order = 6,
                help_text = "e.g. freelance work, investments, pensions"
            },
            {
                question_key = "other_income_description", label = "Describe your other income",
                question_type = "long_text", is_required = false, display_order = 7,
                placeholder = "e.g. Freelance web design, rental income, dividends"
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

        -- Employment status options
        local es_q = db.select("id FROM profile_questions WHERE question_key = 'employment_status'")
        if es_q and #es_q > 0 then
            local options = {
                { label = "Employed (full-time)", value = "employed_full_time", display_order = 1 },
                { label = "Employed (part-time)", value = "employed_part_time", display_order = 2 },
                { label = "Self-employed", value = "self_employed", display_order = 3 },
                { label = "Director", value = "director", display_order = 4 },
                { label = "Unemployed", value = "unemployed", display_order = 5 },
                { label = "Retired", value = "retired", display_order = 6 },
                { label = "Student", value = "student", display_order = 7 },
                { label = "Not working", value = "not_working", display_order = 8 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", es_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), es_q[1].id, opt.label, opt.value, opt.display_order)
                end
            end
        end

        -- Annual salary band options
        local asb_q = db.select("id FROM profile_questions WHERE question_key = 'annual_salary_band'")
        if asb_q and #asb_q > 0 then
            local options = {
                { label = "Under £12,570 (below Personal Allowance)", value = "under_12570", display_order = 1 },
                { label = "£12,570 - £50,270 (Basic rate)", value = "12570_50270", display_order = 2 },
                { label = "£50,270 - £125,140 (Higher rate)", value = "50270_125140", display_order = 3 },
                { label = "Over £125,140 (Additional rate)", value = "over_125140", display_order = 4 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", asb_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), asb_q[1].id, opt.label, opt.value, opt.display_order)
                end
            end
        end
    end,

    -- ==========================================================================
    -- 31. Seed questions: Financial / Tax Information
    -- ==========================================================================
    [31] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'financial-tax'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "tax_year_end", label = "Which tax year are you filing for?",
                question_type = "single_select", is_required = true, display_order = 1,
                help_text = "UK tax year runs 6 April to 5 April"
            },
            {
                question_key = "registered_for_sa", label = "Are you registered for Self Assessment?",
                question_type = "boolean", is_required = true, display_order = 2,
                help_text = "You need to register with HMRC if you have untaxed income"
            },
            {
                question_key = "has_student_loan", label = "Do you have a student loan?",
                question_type = "boolean", is_required = false, display_order = 3
            },
            {
                question_key = "student_loan_plan", label = "Student loan repayment plan",
                question_type = "single_select", is_required = false, display_order = 4,
                help_text = "Check your student loan statement for your plan type"
            },
            {
                question_key = "claims_marriage_allowance", label = "Do you claim Marriage Allowance?",
                question_type = "boolean", is_required = false, display_order = 5,
                help_text = "Transfer £1,260 of your Personal Allowance to your partner"
            },
            {
                question_key = "has_pension_contributions", label = "Do you make pension contributions?",
                question_type = "boolean", is_required = false, display_order = 6,
                help_text = "Private pension contributions may reduce your tax bill"
            },
            {
                question_key = "has_gift_aid_donations", label = "Do you make Gift Aid donations?",
                question_type = "boolean", is_required = false, display_order = 7,
                help_text = "Gift Aid donations can reduce your tax if you're a higher rate taxpayer"
            },
            {
                question_key = "has_capital_gains", label = "Have you sold any assets this tax year?",
                question_type = "boolean", is_required = false, display_order = 8,
                help_text = "e.g. shares, property (not your main home), crypto"
            },
            {
                question_key = "has_foreign_income", label = "Do you receive any foreign income?",
                question_type = "boolean", is_required = false, display_order = 9,
                help_text = "Income from outside the UK that may need to be declared"
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

        -- Tax year options
        local ty_q = db.select("id FROM profile_questions WHERE question_key = 'tax_year_end'")
        if ty_q and #ty_q > 0 then
            local options = {
                { label = "2025-26 (6 Apr 2025 - 5 Apr 2026)", value = "2025-26", display_order = 1 },
                { label = "2024-25 (6 Apr 2024 - 5 Apr 2025)", value = "2024-25", display_order = 2 },
                { label = "2023-24 (6 Apr 2023 - 5 Apr 2024)", value = "2023-24", display_order = 3 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", ty_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), ty_q[1].id, opt.label, opt.value, opt.display_order)
                end
            end
        end

        -- Student loan plan options
        local slp_q = db.select("id FROM profile_questions WHERE question_key = 'student_loan_plan'")
        if slp_q and #slp_q > 0 then
            local options = {
                { label = "Plan 1 (pre-2012)", value = "plan_1", display_order = 1 },
                { label = "Plan 2 (post-2012)", value = "plan_2", display_order = 2 },
                { label = "Plan 4 (Scotland)", value = "plan_4", display_order = 3 },
                { label = "Plan 5 (post-2023)", value = "plan_5", display_order = 4 },
                { label = "Postgraduate Loan", value = "postgrad", display_order = 5 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", slp_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), slp_q[1].id, opt.label, opt.value, opt.display_order)
                end
            end
        end
    end,

    -- ==========================================================================
    -- 32. Seed questions: Compliance
    -- ==========================================================================
    [32] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'compliance'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "confirm_identity", label = "Have you verified your identity?",
                question_type = "boolean", is_required = true, display_order = 1,
                help_text = "We need to verify your identity before submitting to HMRC"
            },
            {
                question_key = "data_consent", label = "Do you consent to us processing your tax data?",
                question_type = "boolean", is_required = true, display_order = 2,
                help_text = "Required under GDPR. We only use your data for tax filing purposes."
            },
            {
                question_key = "hmrc_agent_authorised", label = "Have you authorised us as your HMRC agent?",
                question_type = "boolean", is_required = false, display_order = 3,
                help_text = "If you want us to submit your return, you need to authorise us via HMRC"
            },
            {
                question_key = "anti_money_laundering", label = "AML check completed?",
                question_type = "boolean", is_required = false, display_order = 4,
                help_text = "Anti-Money Laundering verification status"
            },
            {
                question_key = "terms_accepted", label = "Do you accept our Terms of Service?",
                question_type = "boolean", is_required = true, display_order = 5,
                help_text = "You must accept our terms before we can file your return"
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
    -- 33. Seed questions: Preferences
    -- ==========================================================================
    [33] = function()
        local cat = db.select("id FROM profile_categories WHERE slug = 'preferences'")
        if not cat or #cat == 0 then return end
        local cat_id = cat[1].id

        local questions = {
            {
                question_key = "email_notifications", label = "Email notifications",
                question_type = "boolean", is_required = false, display_order = 1,
                help_text = "Receive updates about your tax return via email"
            },
            {
                question_key = "sms_reminders", label = "SMS reminders",
                question_type = "boolean", is_required = false, display_order = 2,
                help_text = "Receive deadline reminders via SMS"
            },
            {
                question_key = "push_notifications", label = "Push notifications",
                question_type = "boolean", is_required = false, display_order = 3,
                help_text = "Receive app push notifications for important updates"
            },
            {
                question_key = "marketing_opt_in", label = "Marketing communications",
                question_type = "boolean", is_required = false, display_order = 4,
                help_text = "Receive tips, guides, and product updates. You can unsubscribe anytime."
            },
            {
                question_key = "language_preference", label = "Preferred language",
                question_type = "single_select", is_required = false, display_order = 5
            },
            {
                question_key = "accessibility_needs", label = "Do you have any accessibility requirements?",
                question_type = "long_text", is_required = false, display_order = 6,
                placeholder = "Let us know how we can make our service more accessible for you"
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

        -- Language preference options
        local lp_q = db.select("id FROM profile_questions WHERE question_key = 'language_preference'")
        if lp_q and #lp_q > 0 then
            local options = {
                { label = "English", value = "en", display_order = 1, is_default = true },
                { label = "Welsh (Cymraeg)", value = "cy", display_order = 2 },
                { label = "Gaelic (Gàidhlig)", value = "gd", display_order = 3 },
            }
            for _, opt in ipairs(options) do
                local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", lp_q[1].id, opt.value)
                if not exists or #exists == 0 then
                    db.query([[
                        INSERT INTO profile_question_options (uuid, question_id, label, value, display_order, is_default, is_active, parent_option_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
                    ]], MigrationUtils.generateUUID(), lp_q[1].id, opt.label, opt.value, opt.display_order, opt.is_default or false)
                end
            end
        end
    end,

    -- ==========================================================================
    -- 34. Seed conditional rules for new categories
    -- ==========================================================================
    [34] = function()
        -- Rule: Show employer_name, job_title, employment_start_date, annual_salary_band
        -- only if employment_status is employed_full_time or employed_part_time or director
        local es_q = db.select("id FROM profile_questions WHERE question_key = 'employment_status'")
        if es_q and #es_q > 0 then
            local dependent_keys = { "employer_name", "job_title", "employment_start_date", "annual_salary_band" }
            for _, key in ipairs(dependent_keys) do
                local dep_q = db.select("id FROM profile_questions WHERE question_key = ?", key)
                if dep_q and #dep_q > 0 then
                    local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", dep_q[1].id, es_q[1].id)
                    if not exists or #exists == 0 then
                        db.query([[
                            INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, expected_value, is_active, created_at, updated_at)
                            VALUES (?, ?, ?, 'visibility', 'in_list', 'AND', ?, 'employed_full_time,employed_part_time,director', true, NOW(), NOW())
                        ]], MigrationUtils.generateUUID(), dep_q[1].id, "Show if employed", es_q[1].id)
                    end
                end
            end
        end

        -- Rule: Show other_income_description only if has_other_income = true
        local hoi_q = db.select("id FROM profile_questions WHERE question_key = 'has_other_income'")
        local oid_q = db.select("id FROM profile_questions WHERE question_key = 'other_income_description'")
        if hoi_q and #hoi_q > 0 and oid_q and #oid_q > 0 then
            local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", oid_q[1].id, hoi_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, 'visibility', 'equals', 'AND', ?, 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), oid_q[1].id, "Show if has other income", hoi_q[1].id)
            end
        end

        -- Rule: Show student_loan_plan only if has_student_loan = true
        local hsl_q = db.select("id FROM profile_questions WHERE question_key = 'has_student_loan'")
        local slp_q = db.select("id FROM profile_questions WHERE question_key = 'student_loan_plan'")
        if hsl_q and #hsl_q > 0 and slp_q and #slp_q > 0 then
            local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", slp_q[1].id, hsl_q[1].id)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, expected_value, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, 'visibility', 'equals', 'AND', ?, 'true', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), slp_q[1].id, "Show if has student loan", hsl_q[1].id)
            end
        end
    end,

    -- ==========================================================================
    -- 35. Replace seed data with client's actual categories & questions
    --
    -- Source: developer_handoff_user_questions.docx
    -- Categories: Personal Details, Employment Income, Self-Employment,
    --             Construction Industry Scheme, Other Income, Rental Income, Investments
    -- All seeded with question_key-based idempotency (won't duplicate on re-run).
    -- ==========================================================================
    [35] = function()
        -- Deactivate old seeded categories that no longer match client requirements
        local old_slugs = {
            "education", "employment", "business-profile", "property-rental",
            "financial-tax", "compliance", "preferences", "contact-details"
        }
        for _, slug in ipairs(old_slugs) do
            db.query("UPDATE profile_categories SET is_active = false, is_archived = true, updated_at = NOW() WHERE slug = ? AND namespace_id = 0", slug)
        end

        -- Helper: create or reactivate a category
        local function ensure_category(slug, name, description, icon, display_order)
            local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
            if exists and #exists > 0 then
                db.query("UPDATE profile_categories SET name = ?, description = ?, icon = ?, display_order = ?, is_active = true, is_archived = false, updated_at = NOW() WHERE slug = ?",
                    name, description, icon, display_order, slug)
                return exists[1].id
            else
                db.query([[
                    INSERT INTO profile_categories (uuid, namespace_id, name, slug, description, icon, display_order, is_active, is_archived, created_at, updated_at)
                    VALUES (?, 0, ?, ?, ?, ?, ?, true, false, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), name, slug, description, icon, display_order)
                local row = db.select("id FROM profile_categories WHERE slug = ?", slug)
                return row and row[1] and row[1].id or nil
            end
        end

        -- Helper: create or update a question
        local function ensure_question(cat_id, q)
            local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
            if exists and #exists > 0 then
                db.query([[
                    UPDATE profile_questions SET category_id = ?, label = ?, question_type = ?, is_required = ?,
                    display_order = ?, help_text = ?, placeholder = ?, is_active = true, is_archived = false, updated_at = NOW()
                    WHERE question_key = ?
                ]], cat_id, q.label, q.question_type, q.is_required, q.display_order, q.help_text or "", q.placeholder or "", q.question_key)
                return exists[1].id
            else
                db.query([[
                    INSERT INTO profile_questions (uuid, category_id, question_key, label, question_type, is_required, display_order, help_text, placeholder, is_active, version, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, true, 1, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label, q.question_type, q.is_required, q.display_order, q.help_text or "", q.placeholder or "")
                local row = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
                return row and row[1] and row[1].id or nil
            end
        end

        -- Helper: create a visibility rule (idempotent)
        local function ensure_rule(target_key, source_key, rule_name, operator, expected_value)
            local tgt = db.select("id FROM profile_questions WHERE question_key = ?", target_key)
            local src = db.select("id FROM profile_questions WHERE question_key = ?", source_key)
            if not tgt or #tgt == 0 or not src or #src == 0 then return end
            local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", tgt[1].id, src[1].id)
            if exists and #exists > 0 then return end
            db.query([[
                INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, source_question_id, expected_value, logic_group, is_active, created_at, updated_at)
                VALUES (?, ?, ?, 'visibility', ?, ?, ?, 'AND', true, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), tgt[1].id, rule_name, operator, src[1].id, expected_value)
        end

        -- ── 1. Personal Details ──────────────────────────────────────────────
        -- Rename existing "personal-information" to match client terminology
        local personal_id = ensure_category("personal-information", "Personal Details", "Your personal information", "user", 1)
        if personal_id then
            ensure_question(personal_id, { question_key = "first_name", label = "What is your first name?", question_type = "short_text", is_required = true, display_order = 1 })
            ensure_question(personal_id, { question_key = "middle_name", label = "What is your middle name?", question_type = "short_text", is_required = false, display_order = 2 })
            ensure_question(personal_id, { question_key = "surname", label = "What is your surname?", question_type = "short_text", is_required = true, display_order = 3 })
            ensure_question(personal_id, { question_key = "address", label = "What is your address?", question_type = "address", is_required = true, display_order = 4 })
            ensure_question(personal_id, { question_key = "ni_number", label = "What is your NI number?", question_type = "short_text", is_required = true, display_order = 5, help_text = "Your National Insurance number (e.g. QQ 123456 C)", placeholder = "QQ 123456 C" })
            ensure_question(personal_id, { question_key = "utr_number", label = "What is your UTR number?", question_type = "short_text", is_required = true, display_order = 6, help_text = "Your Unique Taxpayer Reference (10 digits)", placeholder = "1234567890" })
            ensure_question(personal_id, { question_key = "profession", label = "What is your profession?", question_type = "short_text", is_required = true, display_order = 7 })
        end
        print("[Profile] Seeded Personal Details: 7 questions")

        -- ── 2. Employment Income ─────────────────────────────────────────────
        local employment_id = ensure_category("employment-income", "Employment Income", "Your salary and benefits", "briefcase", 2)
        if employment_id then
            ensure_question(employment_id, { question_key = "has_salary_income", label = "Do you have salary income?", question_type = "boolean", is_required = true, display_order = 1 })
            ensure_question(employment_id, { question_key = "has_p11d_benefits", label = "Do you get benefits in kind (P11D) from your employer?", question_type = "boolean", is_required = true, display_order = 2, help_text = "P11D is a form listing benefits and expenses provided by your employer" })
        end
        print("[Profile] Seeded Employment Income: 2 questions")

        -- ── 3. Self-Employment ───────────────────────────────────────────────
        local self_emp_id = ensure_category("self-employment", "Self-Employment", "Self-employment details", "building", 3)
        if self_emp_id then
            ensure_question(self_emp_id, { question_key = "is_self_employed", label = "Are you self-employed?", question_type = "boolean", is_required = true, display_order = 1 })
            ensure_question(self_emp_id, { question_key = "revenue_above_20k", label = "Is your self-employment revenue above £20,000 before deducting expenses?", question_type = "boolean", is_required = false, display_order = 2, help_text = "Your gross revenue before any business expenses are deducted" })
        end
        ensure_rule("revenue_above_20k", "is_self_employed", "Show if self-employed", "equals", "true")
        print("[Profile] Seeded Self-Employment: 2 questions, 1 rule")

        -- ── 4. Construction Industry Scheme (CIS) ────────────────────────────
        local cis_id = ensure_category("construction-industry", "Construction Industry Scheme (CIS)", "CIS deductions and construction work", "hard-hat", 4)
        if cis_id then
            ensure_question(cis_id, { question_key = "is_construction_worker", label = "Are you working in the construction industry?", question_type = "boolean", is_required = true, display_order = 1 })
            ensure_question(cis_id, { question_key = "has_cis_deductions", label = "Is your contractor deducting your CIS?", question_type = "boolean", is_required = false, display_order = 2, help_text = "CIS (Construction Industry Scheme) deductions taken by your contractor" })
        end
        ensure_rule("has_cis_deductions", "is_construction_worker", "Show if in construction", "equals", "true")
        print("[Profile] Seeded CIS: 2 questions, 1 rule")

        -- ── 5. Other Income ──────────────────────────────────────────────────
        local other_id = ensure_category("other-income", "Other Income", "Interest and other income sources", "pound-sign", 5)
        if other_id then
            ensure_question(other_id, { question_key = "has_interest_income", label = "Do you have interest income?", question_type = "boolean", is_required = true, display_order = 1, help_text = "Interest from savings accounts, bonds, or other investments" })
        end
        print("[Profile] Seeded Other Income: 1 question")

        -- ── 6. Rental Income ─────────────────────────────────────────────────
        local rental_id = ensure_category("rental-income", "Rental Income", "Property rental income details", "home", 6)
        if rental_id then
            ensure_question(rental_id, { question_key = "has_rental_income", label = "Do you have rental income?", question_type = "boolean", is_required = true, display_order = 1 })
            ensure_question(rental_id, { question_key = "num_rental_properties", label = "How many rental properties do you have?", question_type = "number", is_required = false, display_order = 2 })
            ensure_question(rental_id, { question_key = "rental_property_addresses", label = "What is the address of each rental property?", question_type = "repeating_group", is_required = false, display_order = 3, help_text = "Add the address for each property you rent out" })
            ensure_question(rental_id, { question_key = "has_rental_mortgage", label = "Do you have a mortgage on a rental property?", question_type = "boolean", is_required = false, display_order = 4 })
            ensure_question(rental_id, { question_key = "is_interest_only_mortgage", label = "Is it an interest-only mortgage?", question_type = "boolean", is_required = false, display_order = 5 })
        end
        ensure_rule("num_rental_properties", "has_rental_income", "Show if has rental income", "equals", "true")
        ensure_rule("rental_property_addresses", "has_rental_income", "Show if has rental income", "equals", "true")
        ensure_rule("has_rental_mortgage", "has_rental_income", "Show if has rental income", "equals", "true")
        ensure_rule("is_interest_only_mortgage", "has_rental_mortgage", "Show if has mortgage", "equals", "true")
        print("[Profile] Seeded Rental Income: 5 questions, 4 rules")

        -- ── 7. Investments ───────────────────────────────────────────────────
        local invest_id = ensure_category("investments", "Investments", "Investment schemes and capital gains", "trending-up", 7)
        if invest_id then
            ensure_question(invest_id, { question_key = "has_eis_seis", label = "Do you make any investments such as EIS or SEIS?", question_type = "boolean", is_required = true, display_order = 1, help_text = "Enterprise Investment Scheme (EIS) or Seed Enterprise Investment Scheme (SEIS)" })
        end
        print("[Profile] Seeded Investments: 1 question")

        -- ── Auto-tag rules ───────────────────────────────────────────────────
        -- Ensure tags exist
        local function ensure_tag(name, slug, tag_type, color)
            local exists = db.select("id FROM profile_tags WHERE slug = ?", slug)
            if exists and #exists > 0 then return exists[1].id end
            db.query([[
                INSERT INTO profile_tags (uuid, namespace_id, name, slug, tag_type, color, is_active, created_at, updated_at)
                VALUES (?, 0, ?, ?, ?, ?, true, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), name, slug, tag_type, color)
            local row = db.select("id FROM profile_tags WHERE slug = ?", slug)
            return row and row[1] and row[1].id or nil
        end

        local function ensure_tag_rule(tag_slug, source_key, operator, expected_value)
            local tag = db.select("id FROM profile_tags WHERE slug = ?", tag_slug)
            local src = db.select("id FROM profile_questions WHERE question_key = ?", source_key)
            if not tag or #tag == 0 or not src or #src == 0 then return end
            local exists = db.select("id FROM profile_tag_rules WHERE tag_id = ? AND source_question_id = ?", tag[1].id, src[1].id)
            if exists and #exists > 0 then return end
            db.query([[
                INSERT INTO profile_tag_rules (uuid, tag_id, rule_name, source_question_id, operator, expected_value, is_active, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, true, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), tag[1].id, "Auto: " .. tag_slug, src[1].id, operator, expected_value)
        end

        ensure_tag("Self-Employed", "self-employed", "auto", "#6366f1")
        ensure_tag("Landlord", "landlord", "auto", "#0891b2")
        ensure_tag("Construction Worker", "construction-worker", "auto", "#d97706")
        ensure_tag("Investor", "investor", "auto", "#059669")

        ensure_tag_rule("self-employed", "is_self_employed", "equals", "true")
        ensure_tag_rule("landlord", "has_rental_income", "equals", "true")
        ensure_tag_rule("construction-worker", "is_construction_worker", "equals", "true")
        ensure_tag_rule("investor", "has_eis_seis", "equals", "true")
        print("[Profile] Seeded 4 auto-tag rules")

        print("[Profile] Client questions migration complete: 7 categories, 20 questions, 6 visibility rules, 4 tag rules")
    end,
}
