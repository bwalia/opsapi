--[[
  My Income — manually-entered income source-of-truth.

  Each row is one income line item for the authenticated user, scoped by
  namespace_id for multi-tenant isolation. The aggregator in FastAPI
  (backend/app/services/income_source.py::get_total_income) SUMs amount
  for a (user_id, tax_year) and overrides bank-transaction-derived
  trading_income whenever at least one row exists for that tax_year.

  Soft-delete is via is_archived (not hard DELETE) so that:
    - historical tax calculations stay reproducible
    - an accidentally archived row can be unarchived
    - the catalogue audit trail is preserved

  Income type is a fixed catalogue enforced in the Lapis route — see
  VALID_INCOME_TYPES in routes/my-incomes.lua. The DB just stores the key
  as varchar; we don't add a CHECK constraint here because the catalogue
  is server-authoritative and a future migration may add types.

  Pattern: mirrors tax_bank_accounts (lapis/migrations/tax-copilot-system.lua
  steps 1-2) for naming + index strategy.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- 1. Create my_incomes table
    [1] = function()
        schema.create_table("my_incomes", {
            { "id",           types.serial },
            { "uuid",         types.varchar({ unique = true }) },
            { "user_id",      types.integer },
            { "namespace_id", types.integer({ null = true }) },
            -- Income line item
            { "amount",       "numeric(15,2) NOT NULL" },
            { "income_type",  types.varchar },              -- catalogue key: salary, self_employment, etc.
            { "tax_year",     types.varchar },              -- YYYY-YY e.g. "2026-27"
            { "description",  types.text({ null = true }) }, -- optional user note
            -- Soft-delete
            { "is_archived",  types.boolean({ default = false }) },
            { "archived_at",  types.time({ null = true }) },
            { "archived_by",  types.integer({ null = true }) },
            -- Timestamps
            { "created_at",   types.time({ default = db.raw("NOW()") }) },
            { "updated_at",   types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        print("[My Income] Created my_incomes table")
    end,

    -- 2. Add indexes to my_incomes
    -- The composite (user_id, tax_year, is_archived) index is the hot path:
    -- it serves the FastAPI get_total_income aggregator that runs on every
    -- tax calculation. Without it that query degrades to a table scan once
    -- a user has many rows.
    [2] = function()
        schema.create_index("my_incomes", "uuid")
        schema.create_index("my_incomes", "user_id")
        schema.create_index("my_incomes", "namespace_id")
        schema.create_index("my_incomes", "tax_year")
        schema.create_index("my_incomes", "is_archived")
        schema.create_index("my_incomes", "user_id", "tax_year", "is_archived")
        print("[My Income] Added indexes to my_incomes")
    end,
}
