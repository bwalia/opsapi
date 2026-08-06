--[[
  Config-as-Code (CMI) CLI — export / import / status.

  Reads config/registry.lua to know which tables are in scope, walks
  each, and either dumps them to opsapi/config/... or reads those files
  back and upserts them into the current DB.

  MULTI-TENANT MODEL
  ------------------
  Every namespaced table is scoped to ONE namespace per operation. The
  caller passes a namespace slug ('tax-copilot' is the DIY-tax-return
  default); the CLI resolves it to the local integer id and filters
  every query. Cross-tenant leakage is impossible by construction —
  every SELECT WHERE clause carries the resolved id.

  Global tables (no namespace concept — e.g. tax_hmrc_categories,
  menu_items) are exported to a shared `_global/` subfolder regardless
  of the namespace arg.

  Invocation (from inside the opsapi container or a dev shell):

    -- Dump the tax-copilot namespace + globals into /path/to/config/
    lapis exec "require('scripts.config-cli').export('/path/to/config', 'tax-copilot')"

    -- Preview an import (no writes) — shows every INSERT / DEACTIVATE
    -- and MATCHES counts, per table.
    lapis exec "require('scripts.config-cli').import_dry('/path/to/config', 'tax-copilot')"

    -- Apply the import for real (upsert + mark-inactive-not-delete).
    lapis exec "require('scripts.config-cli').import_apply('/path/to/config', 'tax-copilot')"

    -- Structural drift summary; non-zero on any add/remove.
    lapis exec "require('scripts.config-cli').status('/path/to/config', 'tax-copilot')"

  File layout produced:

    <config_dir>/_global/tax_hmrc_categories.json
    <config_dir>/_global/menu_items.json
    <config_dir>/<namespace-slug>/income_types.json
    <config_dir>/<namespace-slug>/profile_categories.json
    <config_dir>/<namespace-slug>/...

  SAFETY MODEL
  ------------
  Export is read-only against the DB but WILL overwrite JSON files.
  Import is destructive against the DB. It does NOT hard-delete
  anything: rows present in the DB but missing from the file get
  is_active = false (soft delete), preserving referential integrity
  for historical user rows that reference a retired config row.

  Refusing to proceed
  -------------------
  If any tenant-scoped table still has rows with namespace_id IS NULL
  or namespace_id = 0, the CLI aborts with a repair hint pointing at
  migration 994_cmi_ns_cleanup_to_tax_copilot. Zero and NULL are never
  real namespaces and would silently drop out of scoped queries.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local JSON = require("config.json_pretty")
local Registry = require("config.registry")
local Global = require("helper.global")

-- Lua 5.2+ renamed unpack → table.unpack; opsapi runs LuaJIT 5.1 where
-- the global still exists. Belt-and-braces for future runtime moves.
local unpack = unpack or table.unpack

local M = {}

--=============================================================================
-- helpers
--=============================================================================

local function dir_exists(path)
    local f = io.open(path .. "/.", "r")
    if f then f:close(); return true end
    return false
end

local function ensure_dir(path)
    -- Best-effort mkdir -p. `os.execute` is safe here — path is an operator
    -- input to the CLI, not user input to a route.
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
end

local function resolve_config_dir(override)
    if override and override ~= "" then
        if not dir_exists(override) then
            error("Config dir arg points at '" .. override .. "' but that directory does not exist")
        end
        return override
    end
    local env = os.getenv("CMI_CONFIG_DIR")
    if env and env ~= "" then
        if not dir_exists(env) then
            error("CMI_CONFIG_DIR points at '" .. env .. "' but that directory does not exist")
        end
        return env
    end
    for _, candidate in ipairs({ "./config", "../config" }) do
        if dir_exists(candidate) then return candidate end
    end
    error("No config directory found (looked for arg, CMI_CONFIG_DIR, ./config, ../config).")
end

-- Resolve a namespace slug to its local integer id on this env. Every
-- CLI operation begins with this — no downstream query runs without it.
local function resolve_namespace(slug)
    if not slug or slug == "" then
        error("CMI CLI requires a namespace slug (e.g. 'tax-copilot'). " ..
              "Passing nil would silently export/import across all namespaces.")
    end
    local rows = db.query("SELECT id FROM namespaces WHERE slug = ? LIMIT 1", slug)
    if not rows or #rows == 0 then
        error("Namespace '" .. slug .. "' does not exist on this environment. " ..
              "Available: run `SELECT slug FROM namespaces`.")
    end
    return rows[1].id
end

-- Cached per-table column list; used to detect namespace_id presence.
local column_cache = {}
local function get_columns(tbl)
    if column_cache[tbl] then return column_cache[tbl] end
    local rows = db.query([[
        SELECT column_name FROM information_schema.columns
        WHERE table_name = ? AND table_schema = 'public'
    ]], tbl)
    local cols = {}
    for _, r in ipairs(rows or {}) do cols[#cols + 1] = r.column_name end
    column_cache[tbl] = cols
    return cols
end

local function column_exists(tbl, col)
    for _, c in ipairs(get_columns(tbl)) do
        if c == col then return true end
    end
    return false
end

-- Refuse to run if any tenant-scoped table still holds ns=0 / NULL rows
-- (namespace-cleanup migration not yet applied). Bail loudly rather than
-- silently miss data.
local function preflight_namespace_cleanliness()
    local bad = {}
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        if entry.namespace_scope == "tenant_scoped" and column_exists(entry.table, "namespace_id") then
            local rows = db.query(
                "SELECT COUNT(*) AS n FROM " .. entry.table ..
                " WHERE namespace_id IS NULL OR namespace_id = 0")
            local n = rows and rows[1] and tonumber(rows[1].n) or 0
            if n > 0 then bad[#bad + 1] = entry.table .. " (" .. n .. " rows)" end
        end
    end
    if #bad > 0 then
        error("CMI refuses to run — tables have ns=0 / NULL rows: " ..
              table.concat(bad, ", ") .. ". Apply migration " ..
              "'994_cmi_ns_cleanup_to_tax_copilot' first.")
    end
end

local function merged_skip_columns(entry)
    local skip = {}
    for _, c in ipairs(Registry.defaults.skip_columns or {}) do skip[c] = true end
    for _, c in ipairs(entry.skip_columns or {}) do skip[c] = true end
    for local_col, _ in pairs(entry.fk_refs or {}) do skip[local_col] = true end
    return skip
end

local function key_columns(entry)
    if type(entry.key) == "table" then return entry.key end
    return { entry.key }
end

local function sort_entries(entry, rows)
    local cols = key_columns(entry)
    table.sort(rows, function(a, b)
        for _, c in ipairs(cols) do
            local av, bv = tostring(a[c] or ""), tostring(b[c] or "")
            if av ~= bv then return av < bv end
        end
        return false
    end)
end

-- Build the WHERE fragment applying the entry's namespace scope. Returns
-- (sql_fragment, bind_values) where fragment starts with " WHERE ..." or
-- is the empty string for global tables.
local function scope_where(entry, target_ns_id)
    local scope = entry.namespace_scope or "tenant_scoped"
    if scope == "global" then
        return "", {}
    elseif scope == "tenant_scoped" then
        return " WHERE " .. entry.table .. ".namespace_id = ?", { target_ns_id }
    elseif scope == "inherited" then
        -- Filter via the parent's namespace_id through the local FK.
        local via = entry.inherit_ns_via
        return " WHERE " .. entry.table .. "." .. via.local_col .. " IN (" ..
               "SELECT id FROM " .. via.parent_table ..
               " WHERE namespace_id = ?)", { target_ns_id }
    end
    error("Unknown namespace_scope '" .. tostring(scope) .. "' for " .. entry.table)
end

-- Choose the subfolder for a table given the target slug.
local function subfolder(entry, ns_slug)
    if entry.namespace_scope == "global" then return "_global" end
    return ns_slug
end

--=============================================================================
-- EXPORT
--=============================================================================

local function deref_id_to_key(fk_spec, id)
    if id == nil or id == cjson.null or id == 0 then return nil end
    local rows = db.query("SELECT " .. fk_spec.key .. " AS k FROM " ..
                          fk_spec.table .. " WHERE id = ?", id)
    if not rows or #rows == 0 then
        return nil, "no " .. fk_spec.table .. " row with id=" .. tostring(id)
    end
    return rows[1].k, nil
end

local function export_one(entry, config_dir, ns_slug, target_ns_id)
    local where_frag, where_binds = scope_where(entry, target_ns_id)
    local sql = "SELECT " .. entry.table .. ".* FROM " .. entry.table .. where_frag
    local rows = db.query(sql, unpack(where_binds)) or {}
    sort_entries(entry, rows)

    local skip = merged_skip_columns(entry)
    local out_entries = {}
    local warnings = {}

    for _, row in ipairs(rows) do
        local out = {}
        for local_col, spec in pairs(entry.fk_refs or {}) do
            local id = row[local_col]
            if id == nil or id == cjson.null or id == 0 then
                out[spec.as] = cjson.null
            else
                local k, err = deref_id_to_key(spec, id)
                if k == nil then
                    warnings[#warnings + 1] = entry.table .. ": " ..
                        local_col .. "=" .. tostring(id) .. " " .. tostring(err)
                    if spec.required then
                        error("EXPORT FAILED: " .. warnings[#warnings])
                    end
                end
                out[spec.as] = k
            end
        end
        for col, val in pairs(row) do
            if not skip[col] then out[col] = val end
        end
        out_entries[#out_entries + 1] = out
    end

    local doc = {
        table = entry.table,
        key = entry.key,
        namespace_scope = entry.namespace_scope,
        namespace_slug = (entry.namespace_scope == "global") and nil or ns_slug,
        registry_version = Registry.version,
        exported_at_note = "regenerated by `lapis exec require('scripts.config-cli').export()`",
        entries = out_entries,
    }

    local subdir = config_dir .. "/" .. subfolder(entry, ns_slug)
    ensure_dir(subdir)
    local path = subdir .. "/" .. entry.file
    local ok, err = JSON.write_file(path, doc)
    if not ok then
        error("Failed to write " .. path .. ": " .. tostring(err))
    end
    return #out_entries, warnings
end

function M.export(config_dir_override, namespace_slug)
    local config_dir = resolve_config_dir(config_dir_override)
    local target_ns_id = resolve_namespace(namespace_slug)
    preflight_namespace_cleanliness()
    print(string.format("[cmi export] namespace=%s (id=%d), config dir=%s",
                        namespace_slug, target_ns_id, config_dir))
    local total_rows, total_warnings = 0, 0
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        if not entry then
            error("export_order references '" .. tbl_name ..
                  "' but no entry exists in Registry.tables")
        end
        local count, warnings = export_one(entry, config_dir, namespace_slug, target_ns_id)
        total_rows = total_rows + count
        total_warnings = total_warnings + #warnings
        print(string.format("[cmi export]   %-32s %4d rows  → %s/%s",
                            entry.table, count, subfolder(entry, namespace_slug), entry.file))
        for _, w in ipairs(warnings) do
            print("[cmi export]     WARN: " .. w)
        end
    end
    print(string.format("[cmi export] done — %d rows across %d tables (%d warnings)",
                        total_rows, #Registry.export_order, total_warnings))
end

--=============================================================================
-- IMPORT
--=============================================================================

local function resolve_key_to_id(fk_spec, key_val)
    if key_val == nil or key_val == cjson.null then return nil end
    local rows = db.query("SELECT id FROM " .. fk_spec.table ..
                          " WHERE " .. fk_spec.key .. " = ?", key_val)
    if not rows or #rows == 0 then
        return nil, "no " .. fk_spec.table .. " row with " ..
               fk_spec.key .. "=" .. tostring(key_val)
    end
    return rows[1].id, nil
end

local function coerce_value(v)
    if v == cjson.null then return db.NULL end
    if type(v) == "table" then return cjson.encode(v) end
    return v
end

local function build_upsert(_entry, key_cols, columns)
    local key_set = {}
    for _, c in ipairs(key_cols) do key_set[c] = true end
    local set_frags = {}
    for _, c in ipairs(columns) do
        if not key_set[c] then
            set_frags[#set_frags + 1] = c .. " = EXCLUDED." .. c
        end
    end
    set_frags[#set_frags + 1] = "updated_at = NOW()"
    return table.concat(set_frags, ", ")
end

local function import_one(entry, config_dir, ns_slug, target_ns_id, apply)
    local path = config_dir .. "/" .. subfolder(entry, ns_slug) .. "/" .. entry.file
    local doc, err = JSON.read_file(path)
    if not doc then
        return { table = entry.table, error = "cannot read " .. path .. ": " .. tostring(err) }
    end
    if doc.table ~= entry.table then
        return { table = entry.table, error = "file " .. path ..
                 " claims table='" .. tostring(doc.table) ..
                 "' but registry expects '" .. entry.table .. "'" }
    end

    local key_cols = key_columns(entry)
    local plan = { table = entry.table, inserts = 0, updates = 0,
                   matches = 0, deactivates = 0, errors = {} }

    -- Snapshot current keys, scoped to the target namespace.
    local where_frag, where_binds = scope_where(entry, target_ns_id)
    local snapshot_sql = "SELECT " .. table.concat(
        (function() local q = {} for _, c in ipairs(key_cols) do q[#q+1] = entry.table.."."..c end; return q end)(),
        ", ") .. " FROM " .. entry.table .. where_frag
    local existing = {}
    for _, r in ipairs(db.query(snapshot_sql, unpack(where_binds)) or {}) do
        local composite = {}
        for _, c in ipairs(key_cols) do composite[#composite + 1] = tostring(r[c]) end
        existing[table.concat(composite, "|")] = true
    end
    local seen = {}

    for _, yaml_row in ipairs(doc.entries or {}) do
        local row = {}
        for k, v in pairs(yaml_row) do row[k] = v end
        local resolved_ok = true
        for local_col, spec in pairs(entry.fk_refs or {}) do
            local key_val = row[spec.as]
            row[spec.as] = nil
            if key_val ~= nil and key_val ~= cjson.null then
                local id, id_err = resolve_key_to_id(spec, key_val)
                if id == nil then
                    if spec.required then
                        plan.errors[#plan.errors + 1] = "row " ..
                            (row[key_cols[1]] or "?") .. ": " .. id_err
                        resolved_ok = false
                    end
                end
                row[local_col] = id
            else
                row[local_col] = cjson.null
            end
        end

        if resolved_ok then
            -- Force the correct namespace id on tenant-scoped rows; global
            -- and inherited tables don't carry a namespace_id column.
            if entry.namespace_scope == "tenant_scoped" and column_exists(entry.table, "namespace_id") then
                row.namespace_id = target_ns_id
            end

            local composite = {}
            for _, c in ipairs(key_cols) do composite[#composite + 1] = tostring(row[c]) end
            local key_str = table.concat(composite, "|")
            seen[key_str] = true

            if row.uuid == nil and column_exists(entry.table, "uuid") then
                row.uuid = Global.generateUUID()
            end

            local cols, vals = {}, {}
            for c, v in pairs(row) do
                cols[#cols + 1] = c
                vals[#vals + 1] = coerce_value(v)
            end
            local placeholders = {}
            for _ = 1, #cols do placeholders[#placeholders + 1] = "?" end
            local conflict_target = table.concat(key_cols, ", ")
            local set_clause = build_upsert(entry, key_cols, cols)

            if apply then
                local ok_q, err_q = pcall(db.query,
                    "INSERT INTO " .. entry.table ..
                    " (" .. table.concat(cols, ", ") .. ")" ..
                    " VALUES (" .. table.concat(placeholders, ", ") .. ")" ..
                    " ON CONFLICT (" .. conflict_target .. ")" ..
                    " DO UPDATE SET " .. set_clause,
                    unpack(vals))
                if not ok_q then
                    plan.errors[#plan.errors + 1] = tostring(err_q)
                elseif existing[key_str] then
                    plan.updates = plan.updates + 1
                else
                    plan.inserts = plan.inserts + 1
                end
            else
                -- Dry-run: report structural drift only; value drift on
                -- existing rows is a follow-up (would require deep-compare
                -- against decoded JSON cols).
                if existing[key_str] then
                    plan.matches = plan.matches + 1
                else
                    plan.inserts = plan.inserts + 1
                end
            end
        end
    end

    -- Rows in DB but missing from file → is_active = false (soft delete),
    -- scoped by the same namespace filter so this can't touch other tenants.
    if column_exists(entry.table, "is_active") then
        for composite_str in pairs(existing) do
            if not seen[composite_str] then
                plan.deactivates = plan.deactivates + 1
                if apply then
                    local parts = {}
                    for part in string.gmatch(composite_str, "([^|]+)") do
                        parts[#parts + 1] = part
                    end
                    local wf, wv = {}, {}
                    for i, c in ipairs(key_cols) do
                        wf[i] = c .. " = ?"
                        wv[i] = parts[i]
                    end
                    -- Layer the scope filter on top of the key filter so a
                    -- key collision across tenants can never cross-write.
                    if entry.namespace_scope == "tenant_scoped" and column_exists(entry.table, "namespace_id") then
                        wf[#wf + 1] = "namespace_id = ?"
                        wv[#wv + 1] = target_ns_id
                    end
                    db.query("UPDATE " .. entry.table ..
                             " SET is_active = false, updated_at = NOW()" ..
                             " WHERE " .. table.concat(wf, " AND "),
                             unpack(wv))
                end
            end
        end
    end

    return plan
end

local function run_import(apply, config_dir_override, namespace_slug)
    local config_dir = resolve_config_dir(config_dir_override)
    local target_ns_id = resolve_namespace(namespace_slug)
    preflight_namespace_cleanliness()
    print(string.format("[cmi import] %s mode, namespace=%s (id=%d), config dir=%s",
                        apply and "APPLY" or "DRY-RUN", namespace_slug, target_ns_id, config_dir))
    local totals = { inserts = 0, updates = 0, matches = 0, deactivates = 0, errors = 0 }
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        local plan = import_one(entry, config_dir, namespace_slug, target_ns_id, apply)
        if plan.error then
            print(string.format("[cmi import] %-32s ERROR: %s",
                                entry.table, plan.error))
            totals.errors = totals.errors + 1
        else
            print(string.format("[cmi import]   %-32s +%d ~%d matches=%d -%d",
                                entry.table, plan.inserts, plan.updates,
                                plan.matches, plan.deactivates))
            for _, e in ipairs(plan.errors) do
                print("[cmi import]     ROW ERROR: " .. e)
                totals.errors = totals.errors + 1
            end
            totals.inserts = totals.inserts + plan.inserts
            totals.updates = totals.updates + plan.updates
            totals.matches = totals.matches + plan.matches
            totals.deactivates = totals.deactivates + plan.deactivates
        end
    end
    print(string.format("[cmi import] done — %d inserts, %d updates, %d matches, %d deactivates, %d errors",
                        totals.inserts, totals.updates, totals.matches, totals.deactivates, totals.errors))
    if totals.errors > 0 then
        error("[cmi import] " .. totals.errors .. " errors above — aborting.")
    end
end

function M.import_dry(config_dir_override, namespace_slug)
    run_import(false, config_dir_override, namespace_slug)
end

function M.import_apply(config_dir_override, namespace_slug)
    run_import(true, config_dir_override, namespace_slug)
end

--=============================================================================
-- STATUS
--=============================================================================

function M.status(config_dir_override, namespace_slug)
    local config_dir = resolve_config_dir(config_dir_override)
    local target_ns_id = resolve_namespace(namespace_slug)
    preflight_namespace_cleanliness()
    print(string.format("[cmi status] namespace=%s (id=%d), config dir=%s",
                        namespace_slug, target_ns_id, config_dir))
    print("[cmi status] (v1 reports structural drift only: added/removed rows.")
    print("[cmi status]  value-level drift on existing rows is a follow-up.)")
    local any_drift = false
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        local plan = import_one(entry, config_dir, namespace_slug, target_ns_id, false)
        if plan.error then
            print(string.format("  %-32s ERROR: %s", entry.table, plan.error))
            any_drift = true
        else
            local drift = plan.inserts + plan.deactivates
            local marker = drift > 0 and "DRIFT" or "clean"
            print(string.format("  %-32s [%s]  +%d matches=%d -%d",
                                entry.table, marker,
                                plan.inserts, plan.matches, plan.deactivates))
            if drift > 0 then any_drift = true end
        end
    end
    if any_drift then
        error("[cmi status] structural drift detected — run import_dry() for details, then import_apply() to apply.")
    else
        print("[cmi status] no structural drift.")
    end
end

return M
