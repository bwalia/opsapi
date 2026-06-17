--[[
  Migration Ledger Reconciliation

  WHY THIS EXISTS
  ---------------
  `lapis_migrations` is the ledger of "which migrations have been
  applied". Lapis trusts it blindly: if a migration name is in the
  ledger, `lapis migrate` skips it — it never even calls the function.

  That ledger can drift out of sync with the actual schema:
    * a DB restore that brings the ledger but an older table set
      (or vice-versa),
    * migrations once run against the wrong database name,
    * a table dropped manually.

  When it drifts, `lapis migrate` skips the drifted migration (ledger
  says done) and any LATER migration that FK-depends on its table dies
  with a cryptic `relation "X" does not exist` — which fails the
  pod's postStart hook and crash-loops it.

  This is exactly what took acc opsapi down for 22h on 2026-05-14:
  CRM migrations 500-504 were in the ledger but every crm_* table was
  gone, so `510_crm_create_leads` died on `REFERENCES crm_contacts`.

  WHAT THIS DOES
  --------------
  Runs BEFORE `lapis migrate` (wired into the bootstrap hook). Walks
  MANIFEST — a static map of `migration_key -> the relation it
  creates`. For each entry where the migration is recorded as applied
  but the relation is MISSING, it deletes that ledger row. The very
  next `lapis migrate` then re-applies it cleanly.

  This is safe because every create-table migration is idempotent
  (a `table_exists()` guard and/or `CREATE TABLE IF NOT EXISTS`), so
  re-running one is a no-op when the table is present and a clean
  create when it is not.

  Never fatal: if this script itself errors, the bootstrap proceeds
  straight to `lapis migrate` — i.e. no worse than before this
  existed.

  MAINTAINING THE MANIFEST
  ------------------------
  When you add a `*_create_*` migration, add one line to MANIFEST
  below: ["<migration_key>"] = "<table_it_creates>". If you forget,
  reconcile() prints a STALENESS NOTE for every applied `create`
  migration it does not recognise — so a gap is visible on the very
  next deploy rather than hiding until the next drift incident.

  The manifest was auto-derived from the `table_exists("...")` guards
  in each lapis/migrations/*.lua module joined with the
  `conditional_array(feature, module, index)` registrations in
  lapis/migrations.lua.
]]

local db = require("lapis.db")

-- migration_key -> the single relation that migration is responsible
-- for creating. Grouped by feature for review; order is irrelevant.
local MANIFEST = {
  -- ── services ──────────────────────────────────────────────────────
  ["180_create_namespace_services_table"]            = "namespace_services",
  ["182_create_namespace_service_secrets_table"]     = "namespace_service_secrets",
  ["184_create_namespace_service_deployments_table"] = "namespace_service_deployments",
  ["186_create_namespace_service_variables_table"]   = "namespace_service_variables",
  ["189_create_namespace_github_integrations_table"] = "namespace_github_integrations",

  -- ── chat ──────────────────────────────────────────────────────────
  ["195_create_message_delivery_tracking"]           = "chat_message_delivery",
  ["200_create_message_archive_table"]               = "chat_messages_archive",
  ["202_create_message_edit_history"]                = "chat_message_edits",
  ["209_add_chat_metrics_table"]                     = "chat_system_metrics",

  -- ── kanban ────────────────────────────────────────────────────────
  ["210_create_kanban_projects_table"]               = "kanban_projects",
  ["212_create_kanban_project_members_table"]        = "kanban_project_members",
  ["214_create_kanban_boards_table"]                 = "kanban_boards",
  ["216_create_kanban_columns_table"]                = "kanban_columns",
  ["218_create_kanban_tasks_table"]                  = "kanban_tasks",
  ["220_create_kanban_task_assignees_table"]         = "kanban_task_assignees",
  ["222_create_kanban_task_labels_table"]            = "kanban_task_labels",
  ["224_create_kanban_task_label_links_table"]       = "kanban_task_label_links",
  ["226_create_kanban_task_comments_table"]          = "kanban_task_comments",
  ["228_create_kanban_task_attachments_table"]       = "kanban_task_attachments",
  ["230_create_kanban_task_checklists_table"]        = "kanban_task_checklists",
  ["232_create_kanban_checklist_items_table"]        = "kanban_checklist_items",
  ["234_create_kanban_task_activities_table"]        = "kanban_task_activities",
  ["236_create_kanban_sprints_table"]                = "kanban_sprints",
  ["250_create_kanban_time_entries_table"]           = "kanban_time_entries",
  ["252_create_kanban_notifications_table"]          = "kanban_notifications",
  ["254_create_kanban_notification_preferences_table"] = "kanban_notification_preferences",
  ["256_create_kanban_sprint_burndown_table"]        = "kanban_sprint_burndown",

  -- ── menu ──────────────────────────────────────────────────────────
  ["263_create_menu_items_table"]                    = "menu_items",
  ["265_create_namespace_menu_config_table"]         = "namespace_menu_config",

  -- ── secret vault ──────────────────────────────────────────────────
  ["272_create_namespace_secret_vaults_table"]       = "namespace_secret_vaults",
  ["274_create_namespace_vault_folders_table"]       = "namespace_vault_folders",
  ["276_create_namespace_vault_secrets_table"]       = "namespace_vault_secrets",
  ["278_create_namespace_vault_shares_table"]        = "namespace_vault_shares",
  ["280_create_namespace_vault_access_logs_table"]   = "namespace_vault_access_logs",

  -- ── bank transactions / push ──────────────────────────────────────
  ["290_create_bank_transactions_table"]             = "bank_transactions",
  ["292_create_device_tokens_table"]                 = "device_tokens",

  -- ── tax copilot ───────────────────────────────────────────────────
  ["331_tax_create_tax_rates_table"]                 = "tax_rates",
  ["333_tax_create_user_profiles"]                   = "tax_user_profiles",
  ["335_tax_create_hmrc_businesses"]                 = "hmrc_businesses",
  ["337_tax_create_hmrc_obligations"]                = "hmrc_obligations",
  ["340_tax_create_hmrc_tokens"]                     = "hmrc_tokens",
  ["478_tax_create_hmrc_calculations"]               = "hmrc_calculations",
  ["480_tax_create_classification_profiles"]         = "classification_profiles",
  ["481_tax_create_app_settings"]                    = "tax_app_settings",
  ["482_tax_create_user_custom_categories"]          = "tax_user_custom_categories",
  ["483_tax_create_transaction_audit"]               = "tax_transaction_audit",
  ["490_tax_create_hmrc_filings"]                    = "hmrc_filings",

  -- ── error catalog ─────────────────────────────────────────────────
  ["464_create_error_catalog_schema"]                = "message_catalog",

  -- ── crm (the 2026-05-14 incident) ─────────────────────────────────
  ["500_crm_create_pipelines"]                       = "crm_pipelines",
  ["501_crm_create_accounts"]                        = "crm_accounts",
  ["502_crm_create_contacts"]                        = "crm_contacts",
  ["503_crm_create_deals"]                           = "crm_deals",
  ["504_crm_create_activities"]                      = "crm_activities",
  ["510_crm_create_leads"]                           = "crm_leads",

  -- ── timesheets ────────────────────────────────────────────────────
  ["520_ts_create_timesheets"]                       = "timesheets",
  ["521_ts_create_entries"]                          = "timesheet_entries",
  ["522_ts_create_approvals"]                        = "timesheet_approvals",

  -- ── invoicing ─────────────────────────────────────────────────────
  ["540_inv_create_invoices"]                        = "invoices",
  ["541_inv_create_line_items"]                      = "invoice_line_items",
  ["542_inv_create_payments"]                        = "invoice_payments",
  ["543_inv_create_tax_rates"]                       = "invoice_tax_rates",
  ["544_inv_create_sequences"]                       = "invoice_sequences",

  -- ── document templates ────────────────────────────────────────────
  ["570_doc_create_templates"]                       = "document_templates",
  ["571_doc_create_versions"]                        = "document_template_versions",
  ["572_doc_create_generated"]                       = "generated_documents",

  -- ── vault integrations ────────────────────────────────────────────
  ["580_vault_create_providers"]                     = "vault_external_providers",
  ["581_vault_create_sync_mappings"]                 = "vault_sync_mappings",
  ["582_vault_create_sync_logs"]                     = "vault_sync_logs",

  -- ── accounting ────────────────────────────────────────────────────
  ["600_acct_create_accounts"]                       = "accounting_accounts",
  ["601_acct_create_journal_entries"]                = "accounting_journal_entries",
  ["602_acct_create_journal_lines"]                  = "accounting_journal_lines",
  ["603_acct_create_bank_transactions"]              = "accounting_bank_transactions",
  ["604_acct_create_expenses"]                       = "accounting_expenses",
  ["605_acct_create_vat_returns"]                    = "accounting_vat_returns",

  -- ── theme system ──────────────────────────────────────────────────
  ["621_create_themes_table"]                        = "themes",
  ["622_create_theme_tokens_table"]                  = "theme_tokens",
  ["623_create_theme_revisions_table"]               = "theme_revisions",
  ["624_create_namespace_active_themes"]             = "namespace_active_themes",
  ["625_create_theme_installations"]                 = "theme_installations",
  ["626_create_theme_assets"]                        = "theme_assets",
}

-- True when the given relation does NOT exist in the current database.
-- to_regclass() returns NULL for an absent relation without raising,
-- so this is safe to call for any name.
local function table_missing(name)
  local ok, rows = pcall(db.query, "SELECT to_regclass(?) IS NULL AS missing", name)
  if not ok then
    -- If even the probe fails, assume present — never delete a ledger
    -- row on a guess.
    return false
  end
  return rows and rows[1] and rows[1].missing
end

-- Walk the ledger, un-record any applied migration whose table is gone.
local function reconcile()
  local ok, applied_rows = pcall(db.query, "SELECT name FROM lapis_migrations")
  if not ok then
    print("[reconcile-migrations] Could not read lapis_migrations (" ..
          tostring(applied_rows) .. ") — skipping reconciliation.")
    return
  end

  local applied = {}
  for _, row in ipairs(applied_rows or {}) do
    applied[row.name] = true
  end

  local healed, checked = {}, 0
  for key, tbl in pairs(MANIFEST) do
    if applied[key] then
      checked = checked + 1
      if table_missing(tbl) then
        local del_ok, del_err = pcall(
          db.query, "DELETE FROM lapis_migrations WHERE name = ?", key)
        if del_ok then
          healed[#healed + 1] = key .. "  (missing relation: " .. tbl .. ")"
        else
          print("[reconcile-migrations] WARNING: could not un-record '" ..
                key .. "': " .. tostring(del_err))
        end
      end
    end
  end

  -- Staleness guard — surface applied `*create*` migrations the
  -- manifest does not know about, so a forgotten manifest entry is
  -- visible immediately instead of only at the next drift incident.
  for name in pairs(applied) do
    if name:match("create") and not MANIFEST[name] then
      print("[reconcile-migrations] NOTE: applied migration '" .. name ..
            "' is not in MANIFEST. If it creates a relation, add it to " ..
            "scripts/reconcile-migrations.lua so drift can be auto-healed.")
    end
  end

  if #healed > 0 then
    print("[reconcile-migrations] Healed " .. #healed ..
          " drifted ledger entr" .. (#healed == 1 and "y" or "ies") ..
          " — `lapis migrate` will now re-apply:")
    for _, h in ipairs(healed) do
      print("  - " .. h)
    end
  else
    print("[reconcile-migrations] Ledger consistent (" .. checked ..
          " create-table migrations verified against live schema).")
  end
end

return { reconcile = reconcile }
