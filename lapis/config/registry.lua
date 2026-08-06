--[[
  Config-as-Code (CMI) — declarative registry.

  Single source of truth for which DB tables are "config" (portable across
  int/acc/prod) and how they round-trip through JSON files. Drives
  `lapis config export|import|status|diff`.

  Multi-tenant model
  ------------------
  Every namespaced admin catalogue MUST be scoped to a real namespace.
  Zero and NULL are never real namespace ids — the cleanup migration
  (config-cmi-namespace-cleanup) reassigns them to tax_copilot before
  CMI ever runs. Export/import operate on ONE namespace at a time; the
  caller passes its slug ('tax-copilot' by default) and the CLI resolves
  it to the local integer id per env.

  Three scope types per entry:

    tenant_scoped   — has a namespace_id column; filtered by
                      namespace_id = <resolved id> on both export and
                      the "existing snapshot" import step.
    inherited       — no namespace_id column, but scope flows through
                      a FK to another registry entry. Filtered by
                      JOIN through `inherit_ns_via.local_col` to the
                      parent, then WHERE parent.namespace_id = <id>.
    global          — no namespace concept (e.g. HMRC categories, the
                      shared menu template). Exported as-is, single
                      copy per environment.

  File layout
  -----------
  On disk:
    opsapi/config/
      _global/                       ← global tables
        tax_hmrc_categories.json
        menu_items.json
      <namespace-slug>/              ← tenant-scoped tables + child tables
        income_types.json
        tax_categories.json
        profile_categories.json
        profile_question_options.json
        ...

  A CMI export run writes to EXACTLY ONE tenant subfolder plus the
  shared _global/. Callers that want multiple tenants exported run the
  command per-tenant.

  Entry structure

    {
      table  = "<db table name>",
      file   = "<yaml filename within its scope folder>",
      key    = "<column>" | { "<col1>", "<col2>" },   -- stable business key
      namespace_scope = "tenant_scoped" | "inherited" | "global",
      inherit_ns_via  = {                             -- only for "inherited"
        local_col     = "<fk column on this table>",
        parent_table  = "<parent table with namespace_id>",
      },
      fk_refs = { ... },                              -- as before
      skip_columns = { ... },
      description = "...",
    }

  Defaults every entry inherits:
    * `id`, `created_at`, `updated_at`, `answered_at`, `last_updated_at`,
      `created_by`, `updated_by`, `changed_by`, `archived_by`,
      `namespace_id` — always skipped on export.
    * Rules use uuid as identity; every other entry uses a natural key.
]]

return {
    version = 1,

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
    },

    -- Order matters: parents first, so FK refs resolve on import.
    export_order = {
        -- Truly global (exported into _global/ regardless of namespace arg)
        "tax_hmrc_categories",
        "menu_items",

        -- Tenant-scoped roots (namespace_id column present)
        "profile_touchpoints",
        "profile_tags",
        "profile_categories",
        "profile_lookup_tables",
        "income_types",
        "pension_payment_categories",
        "property_line_categories",
        "business_line_categories",

        -- One-level deps (tenant-scoped)
        "tax_categories",
        "profile_lookup_values",       -- inherited via lookup_table_id
        "profile_questions",
        "tax_form_sections",           -- inherited via income_type_key JOIN

        -- Two-level deps (inherited)
        "profile_question_options",    -- inherited via question_id
        "profile_question_rules",      -- inherited via question_id
        "profile_tag_rules",           -- inherited via tag_id
        "profile_question_touchpoints",-- inherited via question_id
    },

    tables = {
        --=====================================================================
        -- GLOBAL (no namespace_id column, no per-tenant filter)
        --=====================================================================

        tax_hmrc_categories = {
            table = "tax_hmrc_categories",
            file = "tax_hmrc_categories.json",
            key = "key",
            namespace_scope = "global",
            description = "SA103 HMRC category catalogue (box mappings)",
        },

        menu_items = {
            table = "menu_items",
            file = "menu_items.json",
            key = "key",
            namespace_scope = "global",
            skip_columns = { "parent_id" }, -- self-ref, deferred to v2
            description = "Global menu template (per-namespace overrides not exported)",
        },

        --=====================================================================
        -- TENANT-SCOPED ROOTS (have namespace_id, no cross-config FKs)
        --=====================================================================

        profile_touchpoints = {
            table = "profile_touchpoints",
            file = "profile_touchpoints.json",
            key = "slug",
            namespace_scope = "tenant_scoped",
            description = "Onboarding / annual-review / campaign touchpoints",
        },

        profile_tags = {
            table = "profile_tags",
            file = "profile_tags.json",
            key = "slug",
            namespace_scope = "tenant_scoped",
            description = "Tag catalogue (manual + auto)",
        },

        profile_categories = {
            table = "profile_categories",
            file = "profile_categories.json",
            key = "slug",
            namespace_scope = "tenant_scoped",
            skip_columns = { "parent_id" }, -- self-ref, deferred to v2
            description = "Top-level profile-builder categories",
        },

        profile_lookup_tables = {
            table = "profile_lookup_tables",
            file = "profile_lookup_tables.json",
            key = "slug",
            namespace_scope = "tenant_scoped",
            description = "Named lookup / reference tables",
        },

        income_types = {
            table = "income_types",
            file = "income_types.json",
            key = "income_type_key",
            namespace_scope = "tenant_scoped",
            description = "Admin-managed catalogue of income sources",
        },

        pension_payment_categories = {
            table = "pension_payment_categories",
            file = "pension_payment_categories.json",
            key = "category_key",
            namespace_scope = "tenant_scoped",
            description = "Legacy pension-payments catalogue (superseded by form_sections)",
        },

        property_line_categories = {
            table = "property_line_categories",
            file = "property_line_categories.json",
            key = { "kind", "category_key" },
            namespace_scope = "tenant_scoped",
            description = "SA105 property income/expense line catalogue",
        },

        business_line_categories = {
            table = "business_line_categories",
            file = "business_line_categories.json",
            key = { "kind", "category_key" },
            namespace_scope = "tenant_scoped",
            description = "SA103 self-employment line catalogue",
        },

        --=====================================================================
        -- ONE-LEVEL DEPS
        --=====================================================================

        tax_categories = {
            table = "tax_categories",
            file = "tax_categories.json",
            key = "key",
            namespace_scope = "tenant_scoped",
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
            file = "profile_lookup_values.json",
            key = { "lookup_table_id", "value" }, -- lookup_table_id is FK-deref'd
            namespace_scope = "inherited",
            inherit_ns_via = {
                local_col = "lookup_table_id",
                parent_table = "profile_lookup_tables",
            },
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
            file = "profile_questions.json",
            key = "question_key",
            namespace_scope = "tenant_scoped",
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
            file = "tax_form_sections.json",
            key = { "income_type_key", "section_key" },
            namespace_scope = "tenant_scoped",
            -- income_type_key is a NATIVE key ref (varchar), no dereference needed
            description = "Admin catalogue of sub-form sections per income type",
        },

        --=====================================================================
        -- TWO-LEVEL DEPS (inherited scope)
        --=====================================================================

        profile_question_options = {
            table = "profile_question_options",
            file = "profile_question_options.json",
            key = { "question_id", "value" }, -- question_id is FK-deref'd
            namespace_scope = "inherited",
            inherit_ns_via = {
                local_col = "question_id",
                parent_table = "profile_questions",
            },
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
            file = "profile_question_rules.json",
            key = "uuid",
            namespace_scope = "inherited",
            inherit_ns_via = {
                local_col = "question_id",
                parent_table = "profile_questions",
            },
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
            file = "profile_tag_rules.json",
            key = "uuid",
            namespace_scope = "inherited",
            inherit_ns_via = {
                local_col = "tag_id",
                parent_table = "profile_tags",
            },
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
            file = "profile_question_touchpoints.json",
            key = { "question_id", "touchpoint_id" },
            namespace_scope = "inherited",
            inherit_ns_via = {
                local_col = "question_id",
                parent_table = "profile_questions",
            },
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
