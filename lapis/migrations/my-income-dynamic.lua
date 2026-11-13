--[[
  My Income — definition-driven income types for the OpsAPI dashboard.

  Builds on the income_types catalogue diy-tax-return-uk already uses
  (migrations/income-types-system.lua + dividend/interest/overseas/pension
  panels). Everything here is ADDITIVE: the diy routes (/api/v2/tax/my-incomes,
  /api/v2/tax/admin/income-types) keep working unchanged.

    [1] income_types gains the "definition" columns:
          icon, help_text, entity_type, entity_label, estimate_note,
          field_schema (jsonb)       what the user fills in (sections → fields)
          estimator_mapping (jsonb)  which lib/tax-calc input each figure feeds
    [2] income_type_namespace_overrides — a workspace's edits of a SYSTEM type
        (rename, help, order, hide, its own form). NULL column = inherit.
        A workspace's OWN types are income_types rows with namespace_id set
        and key "ns<id>_<slug>" (income_type_key stays globally unique, which
        other migrations' ON CONFLICT (income_type_key) relies on).
    [3] tax_income_records — the user's figures per (namespace, user, tax
        year, income type, entity?). Entities (properties, jobs, businesses)
        are user_profile_entities rows, shared with the diy hubs.
    [4] seed the definitions of the 13 system types from lib/income-types-seed
        ONLY where field_schema is still empty — never overwrites admin edits.
    [5] RBAC module tax_income_types (read = see the list, update/create =
        maintain) + propagate to namespace owner/admin roles.
    [6] menu: "My Income" (customer) and "Income types" (admin) under Tax.

  Idempotent throughout (IF NOT EXISTS / ON CONFLICT / existence checks).
  Only executed when PROJECT_CODE includes tax_copilot.
]]

local db = require("lapis.db")
local cjson = require("cjson")

local function jsonb(v, as_array)
    if v == nil or (type(v) == "table" and next(v) == nil) then return as_array and "[]" or "{}" end
    return cjson.encode(v)
end

return {
    [1] = function()
        db.query([[
            ALTER TABLE income_types
              ADD COLUMN IF NOT EXISTS icon              VARCHAR(60),
              ADD COLUMN IF NOT EXISTS help_text         TEXT,
              ADD COLUMN IF NOT EXISTS entity_type       VARCHAR(60),
              ADD COLUMN IF NOT EXISTS entity_label      VARCHAR(60),
              ADD COLUMN IF NOT EXISTS estimate_note     TEXT,
              ADD COLUMN IF NOT EXISTS field_schema      JSONB NOT NULL DEFAULT '{}'::jsonb,
              ADD COLUMN IF NOT EXISTS estimator_mapping JSONB NOT NULL DEFAULT '[]'::jsonb
        ]])
        print("[My Income] income_types: added definition columns")
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS income_type_namespace_overrides (
                id                SERIAL PRIMARY KEY,
                namespace_id      INTEGER NOT NULL,
                income_type_id    INTEGER NOT NULL REFERENCES income_types(id) ON DELETE CASCADE,
                display_name      VARCHAR(255),
                description       TEXT,
                help_text         TEXT,
                icon              VARCHAR(60),
                display_order     INTEGER,
                is_active         BOOLEAN,
                field_schema      JSONB,
                estimator_mapping JSONB,
                estimate_note     TEXT,
                created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at        TIMESTAMP NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, income_type_id)
            )
        ]])
        print("[My Income] created income_type_namespace_overrides")
    end,

    [3] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS tax_income_records (
                id               SERIAL PRIMARY KEY,
                uuid             VARCHAR(255) NOT NULL UNIQUE,
                namespace_id     INTEGER NOT NULL,
                user_id          INTEGER NOT NULL,
                tax_year         VARCHAR(7) NOT NULL,
                income_type_key  VARCHAR(255) NOT NULL,
                entity_uuid      VARCHAR(255),
                figures          JSONB NOT NULL DEFAULT '{}'::jsonb,
                value_sources    JSONB NOT NULL DEFAULT '{}'::jsonb,
                status           VARCHAR(20) NOT NULL DEFAULT 'in_progress'
                                 CHECK (status IN ('in_progress', 'done', 'not_applicable')),
                created_at       TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at       TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        -- One record per (ns, user, year, type, entity); the year-level record has no entity.
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS uq_tax_income_records_slot
            ON tax_income_records (namespace_id, user_id, tax_year, income_type_key, (COALESCE(entity_uuid, '')))
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS idx_tax_income_records_owner_year
            ON tax_income_records (namespace_id, user_id, tax_year)
        ]])
        print("[My Income] created tax_income_records")
    end,

    [4] = function()
        local seeds = require("lib.income-types-seed")
        local applied = 0
        for _, s in ipairs(seeds) do
            local res = db.query([[
                UPDATE income_types
                   SET field_schema      = ?::jsonb,
                       estimator_mapping = ?::jsonb,
                       icon          = COALESCE(icon, ?),
                       help_text     = COALESCE(help_text, ?),
                       entity_type   = COALESCE(entity_type, ?),
                       entity_label  = COALESCE(entity_label, ?),
                       estimate_note = COALESCE(estimate_note, ?),
                       updated_at    = NOW()
                 WHERE income_type_key = ?
                   AND COALESCE(namespace_id, 0) = 0
                   AND (field_schema IS NULL OR field_schema = '{}'::jsonb)
            ]], jsonb(s.field_schema, false), jsonb(s.estimator_mapping, true),
                s.icon or db.NULL, s.help_text or db.NULL, s.entity_type or db.NULL,
                s.entity_label or db.NULL, s.estimate_note or db.NULL, s.key)
            applied = applied + ((res and res.affected_rows) or 0)
        end
        print("[My Income] seeded definitions for " .. applied .. " income type(s) (empty ones only)")
    end,

    [5] = function()
        local inserted = db.query([[
            INSERT INTO modules (uuid, machine_name, name, description, category, priority,
                                 is_active, is_system, default_actions, created_at, updated_at)
            VALUES (gen_random_uuid()::text, 'tax_income_types', 'Income types',
                    'Maintain the income types customers fill in under My Income',
                    'Tax', '0', true, false, 'create,read,update,delete,manage', NOW(), NOW())
            ON CONFLICT (machine_name) DO NOTHING
            RETURNING id
        ]])
        if inserted[1] then
            require("queries.ModuleQueries").propagateToNamespaceAdmins("tax_income_types")
        end
        print("[My Income] RBAC module tax_income_types registered")
    end,

    [6] = function()
        local MigrationUtils = require("helper.migration-utils")
        local parent = db.select("id FROM menu_items WHERE key = ? LIMIT 1", "tax")
        local parent_id = parent[1] and parent[1].id or nil
        local items = {
            { key = "tax_my_income", name = "My Income", icon = "Wallet", path = "/dashboard/tax/income",
              module = "tax_statements", priority = 34 },
            { key = "tax_income_types", name = "Income types", icon = "Layers",
              path = "/dashboard/tax/income-types", module = "tax_income_types", priority = 96 },
        }
        for _, it in ipairs(items) do
            if #db.select("id FROM menu_items WHERE key = ?", it.key) == 0 then
                local ts = MigrationUtils.getCurrentTimestamp()
                db.insert("menu_items", {
                    uuid = MigrationUtils.generateUUID(),
                    key = it.key,
                    name = it.name,
                    icon = it.icon,
                    path = it.path,
                    module = it.module,
                    required_action = "read",
                    priority = it.priority,
                    parent_id = parent_id,
                    is_active = true,
                    is_admin_only = false,
                    always_show = false,
                    settings = "{}",
                    created_at = ts,
                    updated_at = ts,
                })
            end
        end
        print("[My Income] menu items: My Income, Income types")
    end,
}
