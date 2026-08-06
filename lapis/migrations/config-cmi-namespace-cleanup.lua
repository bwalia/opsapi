--[[
  Config-as-Code (CMI) — namespace cleanup for tax_copilot rows.

  Prep step for `lapis config export|import` under a multi-tenant
  namespace model. Every DIY-tax-return admin catalogue row must be
  owned by the `tax_copilot` namespace (id looked up by slug at
  migrate time — id assignment is per-env). Two edge cases exist:

    1. namespace_id = 0
       The admin routes historically wrote `namespace_id or 0` when
       the request had no namespace context — see e.g.
       routes/profile-builder.lua:2149. Zero is never a real namespace
       (namespaces.id is serial from 1). These are data-integrity
       bugs; migrate them to tax_copilot.

    2. namespace_id IS NULL
       Seed migrations inserted platform catalogues (income_types,
       profile_questions) without a namespace_id because the row
       existed BEFORE the multi-tenant model landed. On a
       DIY-tax-return install the tenant that owns them is tax_copilot.

  Idempotent: every UPDATE is guarded by the current row state, so
  re-running the migration on already-fixed data is a no-op.

  Skips itself silently if the `tax_copilot` namespace doesn't exist
  in this DB (a fresh install where namespace seeding hasn't run yet).
  The next `lapis migrate` run picks it up after namespaces exist.
]]

local db = require("lapis.db")

-- Tables in scope for CMI that have a namespace_id column.
-- Kept in sync with lapis/config/registry.lua manually — if you add a
-- new registry entry with namespace_id, add it here too.
local TENANT_SCOPED_TABLES = {
    "profile_touchpoints",
    "profile_tags",
    "profile_categories",
    "profile_lookup_tables",
    "profile_questions",
    "income_types",
    "tax_categories",
    "tax_form_sections",
    "pension_payment_categories",
    "property_line_categories",
    "business_line_categories",
}

-- Resolve the tax_copilot namespace id. Returns nil (not error) if the
-- namespaces table hasn't been seeded yet — the caller then no-ops the
-- migration and lets a later re-run finish the job.
local function tax_copilot_id()
    local ok, rows = pcall(db.query,
        "SELECT id FROM namespaces WHERE slug = 'tax-copilot' LIMIT 1")
    if not ok then return nil end
    return rows and rows[1] and rows[1].id or nil
end

local function migrate_table(tbl, target_id)
    -- Only touch rows that are actually bugs — ns=0 or NULL. Real
    -- tenant rows (any other integer) stay untouched.
    local ok, res = pcall(db.query,
        "UPDATE " .. tbl ..
        " SET namespace_id = ?, updated_at = NOW()" ..
        " WHERE namespace_id = 0 OR namespace_id IS NULL",
        target_id)
    if not ok then
        -- Table might not exist on this project code (e.g. CMI installed
        -- before TAX_COPILOT tables were created). Skip silently.
        print(string.format("[CMI ns-cleanup] skip %s (%s)", tbl, tostring(res)))
        return 0
    end
    return res and res.affected_rows or 0
end

return {
    -- =========================================================================
    -- 1. Reassign ns=0 / NULL rows on every in-scope table to tax_copilot.
    -- =========================================================================
    [1] = function()
        local target = tax_copilot_id()
        if not target then
            print("[CMI ns-cleanup] tax_copilot namespace not found — skipping. " ..
                  "Re-run `lapis migrate` after the namespaces table is seeded.")
            return
        end
        local total = 0
        for _, tbl in ipairs(TENANT_SCOPED_TABLES) do
            local n = migrate_table(tbl, target)
            total = total + n
            if n > 0 then
                print(string.format("[CMI ns-cleanup]   %s: reassigned %d row(s) → namespace_id=%d",
                                    tbl, n, target))
            end
        end
        print(string.format("[CMI ns-cleanup] done — %d row(s) reassigned to tax_copilot (id=%d).",
                            total, target))
    end,
}
