--[[
  "Let our accountant file it for you" — filing requests

  OpsAPI isn't an HMRC-recognised filer yet, so a customer can hand their return to
  our accountant, who files it via HMRC-recognised software (e.g. My Tax Digital)
  from the figures the customer approved (routes/tax-filing, lib/tax-report).

  Table tax_filing_requests — one row per request:
  - snapshot      : the report the customer approved (summary, HMRC boxes,
                    transactions), frozen so the accountant files exactly that
  - figures_hash  : fingerprint of those figures (lib/tax-report hash)
  - status        : submitted → reviewing → filing → filed; needs_info (question to
                    the customer); rejected / cancelled are closed
  - updates       : timeline [{type, status?, text?, by, at}]
  At most one OPEN request per customer + tax year (partial unique index). Scoped
  by namespace_id + user_id; soft FKs (app-enforced) like the rest of tax_*.

  Also registers the RBAC module `tax_filing_requests` (the accountant's queue —
  read = see the queue / download, update = change status) and its sidebar item.
  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    [1] = function()
        schema.create_table("tax_filing_requests", {
            { "id",               types.serial },
            { "uuid",             types.varchar({ unique = true }) },
            { "namespace_id",     types.integer },
            { "user_id",          types.integer },
            { "tax_year",         types.varchar },
            { "status",           types.varchar({ default = "'submitted'" }) },
            "snapshot jsonb NOT NULL",
            { "figures_hash",     types.varchar },
            "our_total_due numeric(14,2)",
            { "declaration_text", types.text },
            { "declared_at",      types.time },
            { "hmrc_reference",   types.varchar({ null = true }) },
            "hmrc_total_due numeric(14,2)",
            { "variance_note",    types.text({ null = true }) },
            { "client_message",   types.text({ null = true }) },
            "updates jsonb NOT NULL DEFAULT '[]'::jsonb",
            { "handled_by",       types.integer({ null = true }) },
            { "filed_at",         types.time({ null = true }) },
            { "created_at",       types.time({ default = db.raw("NOW()") }) },
            { "updated_at",       types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)",
        })
        db.query([[CREATE INDEX IF NOT EXISTS idx_tax_filing_requests_queue
            ON tax_filing_requests (namespace_id, status, created_at)]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_tax_filing_requests_owner
            ON tax_filing_requests (namespace_id, user_id, tax_year)]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS uq_tax_filing_requests_open
            ON tax_filing_requests (namespace_id, user_id, tax_year)
            WHERE status IN ('submitted', 'reviewing', 'needs_info', 'filing', 'filed')]])
    end,

    [2] = function()
        local inserted = db.query([[
            INSERT INTO modules (uuid, machine_name, name, description, category, priority,
                                 is_active, is_system, default_actions, created_at, updated_at)
            VALUES (gen_random_uuid()::text, 'tax_filing_requests', 'Filing Requests',
                    'Accountant queue: returns customers asked us to file for them',
                    'Tax', '0', true, false, 'create,read,update,delete,manage', NOW(), NOW())
            ON CONFLICT (machine_name) DO NOTHING
            RETURNING id
        ]])
        if inserted[1] then
            require("queries.ModuleQueries").propagateToNamespaceAdmins("tax_filing_requests")
        end

        if #db.select("id FROM menu_items WHERE key = ?", "tax_filing_requests") == 0 then
            local MigrationUtils = require("helper.migration-utils")
            local ts = MigrationUtils.getCurrentTimestamp()
            local parent = db.select("id FROM menu_items WHERE key = ? LIMIT 1", "tax")
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = "tax_filing_requests",
                name = "Filing requests",
                icon = "Inbox",
                path = "/dashboard/tax/filing-requests",
                module = "tax_filing_requests",
                required_action = "read",
                priority = 95,
                parent_id = parent[1] and parent[1].id or nil,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = ts,
                updated_at = ts,
            })
        end
    end,
}
