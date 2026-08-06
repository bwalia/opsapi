--[[
  Config-as-Code (CMI) — declarative registry.

  Single source of truth for which DB tables are "config" (portable across
  int/acc/prod) and how they round-trip through YAML files. Drives
  `lapis config export|import|status|diff`.

  Structure per entry:

    {
      table  = "<db table name>",
      file   = "<yaml filename under opsapi/config/>",
      key    = "<column>" | { "<col1>", "<col2>" },  -- stable business key
      fk_refs = {
        -- Cross-config integer FKs: at EXPORT the local column is replaced
        -- with `as` in the YAML by looking up `table`'s `key` for that id.
        -- At IMPORT the reverse lookup gets the local integer id back.
        -- If the FK target is a KEY-based reference (e.g. tax_form_sections
        -- .income_type_key) no entry is needed — the key travels natively.
        <local_column> = {
          table = "<referenced table>",
          key   = "<referenced table's stable key column>",
          as    = "<field name to write into the YAML>",
          required = <bool>,  -- if true, missing target on import errors out
        },
      },
      skip_columns = { ... },  -- omit from YAML (defaults handle common cases)
      description  = "<one-line human-readable>",
    }

  export_order determines the sequence for both dump and load — parents
  first (so on import the referenced rows exist by the time FK refs
  need to resolve). If two entries have no ordering relationship, alpha.

  Defaults every entry inherits (no need to repeat):

    * `id`, `created_at`, `updated_at`, `answered_at`,
      `last_updated_at`, `created_by`, `updated_by`, `changed_by`,
      `archived_by`, `namespace_id`  — always skipped on export.
    * `is_active` presence — kept; used by import to mark-inactive rows
      that disappeared from YAML (never DELETE).
    * Only rows with `namespace_id IS NULL` (global config) are exported
      in v1. Per-tenant customization stays with the tenant.

  Adding a new config table: append to `tables`, add its slot in
  `export_order`, run `lapis config export`, commit the resulting YAML.
]]

return {
    version = 1,

    -- Global defaults; every entry inherits these unless it overrides.
    defaults = {
        skip_columns = {
            "id",
            "created_at",
            "updated_at",
            "answered_at",
            "last_updated_at",
            "created_by",
            "updated_by",
            "changed_by",
            "archived_by",
            "namespace_id",
        },
        namespace_scope = "global_only", -- WHERE namespace_id IS NULL
    },

    -- Order matters: parents first, so FK refs resolve on import.
    export_order = {
        -- No dependencies (roots)
        "profile_touchpoints",
        "profile_tags",
        "profile_categories",
        "profile_lookup_tables",
        "income_types",
        "tax_hmrc_categories",
        "pension_payment_categories",
        "property_line_categories",
        "business_line_categories",
        "menu_items",

        -- One-level deps
        "tax_categories",             -- → tax_hmrc_categories
        "profile_lookup_values",      -- → profile_lookup_tables
        "profile_questions",          -- → profile_categories, profile_lookup_tables
        "tax_form_sections",          -- → income_types (via income_type_key, native)

        -- Two-level deps
        "profile_question_options",   -- → profile_questions
        "profile_question_rules",     -- → profile_questions
        "profile_tag_rules",          -- → profile_tags, profile_questions
        "profile_question_touchpoints", -- → profile_questions, profile_touchpoints
    },

    -- Per-table descriptors, keyed by table name.
    tables = {
        --=====================================================================
        -- ROOTS (no cross-config FKs)
        --=====================================================================

        profile_touchpoints = {
            table = "profile_touchpoints",
            file = "profile_touchpoints.yaml",
            key = "slug",
            description = "Onboarding / annual-review / campaign touchpoints",
        },

        profile_tags = {
            table = "profile_tags",
            file = "profile_tags.yaml",
            key = "slug",
            description = "Tag catalogue (manual + auto)",
        },

        profile_categories = {
            table = "profile_categories",
            file = "profile_categories.yaml",
            key = "slug",
            skip_columns = { "parent_id" }, -- self-ref, deferred to v2
            description = "Top-level profile-builder categories",
        },

        profile_lookup_tables = {
            table = "profile_lookup_tables",
            file = "profile_lookup_tables.yaml",
            key = "slug",
            description = "Named lookup / reference tables",
        },

        income_types = {
            table = "income_types",
            file = "income_types.yaml",
            key = "income_type_key",
            description = "Admin-managed catalogue of income sources",
        },

        tax_hmrc_categories = {
            table = "tax_hmrc_categories",
            file = "tax_hmrc_categories.yaml",
            key = "key",
            description = "SA103 HMRC category catalogue (box mappings)",
        },

        pension_payment_categories = {
            table = "pension_payment_categories",
            file = "pension_payment_categories.yaml",
            key = "category_key",
            description = "Legacy pension-payments catalogue (superseded by form_sections)",
        },

        property_line_categories = {
            table = "property_line_categories",
            file = "property_line_categories.yaml",
            key = { "kind", "category_key" },
            description = "SA105 property income/expense line catalogue",
        },

        business_line_categories = {
            table = "business_line_categories",
            file = "business_line_categories.yaml",
            key = { "kind", "category_key" },
            description = "SA103 self-employment line catalogue",
        },

        menu_items = {
            table = "menu_items",
            file = "menu_items.yaml",
            key = "key",
            skip_columns = { "parent_id" }, -- self-ref, deferred to v2
            description = "Global menu template (per-namespace overrides not exported)",
        },

        --=====================================================================
        -- ONE-LEVEL DEPS
        --=====================================================================

        tax_categories = {
            table = "tax_categories",
            file = "tax_categories.yaml",
            key = "key",
            fk_refs = {
                hmrc_category_id = {
                    table = "tax_hmrc_categories",
                    key = "key",
                    as = "hmrc_category_key",
                    required = false,
                },
            },
            description = "Tax category catalogue (income + expense)",
        },

        profile_lookup_values = {
            table = "profile_lookup_values",
            file = "profile_lookup_values.yaml",
            key = { "lookup_table_id", "value" }, -- composite; lookup_table_id is FK-deref'd
            fk_refs = {
                lookup_table_id = {
                    table = "profile_lookup_tables",
                    key = "slug",
                    as = "lookup_table_slug",
                    required = true,
                },
            },
            skip_columns = { "parent_value_id" }, -- self-ref, deferred to v2
            description = "Values within named lookup tables",
        },

        profile_questions = {
            table = "profile_questions",
            file = "profile_questions.yaml",
            key = "question_key",
            fk_refs = {
                category_id = {
                    table = "profile_categories",
                    key = "slug",
                    as = "category_slug",
                    required = true,
                },
                lookup_table_id = {
                    table = "profile_lookup_tables",
                    key = "slug",
                    as = "lookup_table_slug",
                    required = false,
                },
            },
            description = "Dynamic profile questions (schema per category)",
        },

        tax_form_sections = {
            table = "tax_form_sections",
            file = "tax_form_sections.yaml",
            key = { "income_type_key", "section_key" },
            -- income_type_key is a NATIVE key ref (varchar), no dereference needed
            description = "Admin catalogue of sub-form sections per income type",
        },

        --=====================================================================
        -- TWO-LEVEL DEPS
        --=====================================================================

        profile_question_options = {
            table = "profile_question_options",
            file = "profile_question_options.yaml",
            key = { "question_id", "value" }, -- composite; question_id is FK-deref'd
            fk_refs = {
                question_id = {
                    table = "profile_questions",
                    key = "question_key",
                    as = "question_key",
                    required = true,
                },
            },
            skip_columns = { "parent_option_id" }, -- self-ref, deferred to v2
            description = "Predefined options for select-type questions",
        },

        profile_question_rules = {
            table = "profile_question_rules",
            file = "profile_question_rules.yaml",
            key = "uuid", -- rules have no natural name; uuid is portable
            fk_refs = {
                question_id = {
                    table = "profile_questions",
                    key = "question_key",
                    as = "question_key",
                    required = true,
                },
                source_question_id = {
                    table = "profile_questions",
                    key = "question_key",
                    as = "source_question_key",
                    required = false,
                },
            },
            description = "Visibility / requirement / validation rules per question",
        },

        profile_tag_rules = {
            table = "profile_tag_rules",
            file = "profile_tag_rules.yaml",
            key = "uuid",
            fk_refs = {
                tag_id = {
                    table = "profile_tags",
                    key = "slug",
                    as = "tag_slug",
                    required = true,
                },
                source_question_id = {
                    table = "profile_questions",
                    key = "question_key",
                    as = "source_question_key",
                    required = false,
                },
            },
            description = "Auto-tagging rules driven by answers",
        },

        profile_question_touchpoints = {
            table = "profile_question_touchpoints",
            file = "profile_question_touchpoints.yaml",
            key = { "question_id", "touchpoint_id" },
            fk_refs = {
                question_id = {
                    table = "profile_questions",
                    key = "question_key",
                    as = "question_key",
                    required = true,
                },
                touchpoint_id = {
                    table = "profile_touchpoints",
                    key = "slug",
                    as = "touchpoint_slug",
                    required = true,
                },
            },
            description = "Which questions are asked in which touchpoint",
        },
    },
}
