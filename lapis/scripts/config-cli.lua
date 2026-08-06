--[[
  Config-as-Code (CMI) CLI — export / import / status.

  Reads config/registry.lua to know which tables are in scope, walks
  each, and either dumps them to opsapi/config/*.json or reads those
  files back and upserts them into the current DB.

  Invocation (from inside the opsapi container or a dev shell with
  lapis on PATH):

    # Dump current DB → JSON files under $CMI_CONFIG_DIR (or ./config)
    lapis exec "require('scripts.config-cli').export()"

    # Preview an import (no writes) — shows every INSERT / UPDATE it
    # would perform, plus rows it would mark inactive.
    lapis exec "require('scripts.config-cli').import_dry()"

    # Apply the import for real (upsert + mark-inactive-not-delete).
    lapis exec "require('scripts.config-cli').import_apply()"

    # One-line drift summary (per-table row counts + INSERT/UPDATE
    # counts vs on-disk config). Non-zero when drift exists.
    lapis exec "require('scripts.config-cli').status()"

  Config directory resolution, in order:
    1. $CMI_CONFIG_DIR                            (explicit override)
    2. First of these that exists as a directory: ./config, ../config
    3. Fatal error — export/import cannot proceed without a target.

  IMPORTANT — SAFETY MODEL

  Export is read-only against the DB but WILL overwrite JSON files.
  Import is destructive against the DB. It does NOT hard-delete
  anything: rows not present in the YAML get is_active=false (soft
  delete), preserving referential integrity for historical user data.

  Only rows with `namespace_id IS NULL` participate. Per-tenant
  customization is treated as data, not config, and follows the tenant.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local JSON = require("config.json_pretty")
local Registry = require("config.registry")
local Global = require("helper.global")

-- Lua 5.2 renamed unpack → table.unpack; opsapi runs LuaJIT 5.1 where the
-- global still exists, but belt-and-braces so this module keeps compiling
-- if the runtime ever moves.
local unpack = unpack or table.unpack

local M = {}

--=============================================================================
-- config dir resolution
--=============================================================================

local function dir_exists(path)
    local f = io.open(path .. "/.", "r")
    if f then f:close(); return true end
    return false
end

-- Resolve the config directory. Priority:
--   1. Explicit arg from the caller (highest)
--   2. $CMI_CONFIG_DIR env var (works from a shell but NOT from
--      `lapis exec`, which runs inside the OpenResty worker whose
--      env is frozen at nginx spawn — pass an arg in that case)
--   3. ./config or ../config relative to CWD (dev-shell fallback)
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

--=============================================================================
-- shared helpers
--=============================================================================

local function merged_skip_columns(entry)
    local skip = {}
    for _, c in ipairs(Registry.defaults.skip_columns or {}) do skip[c] = true end
    for _, c in ipairs(entry.skip_columns or {}) do skip[c] = true end
    -- Every FK ref's local column is skipped from raw output (replaced by
    -- the dereferenced field via `as`).
    for local_col, _ in pairs(entry.fk_refs or {}) do skip[local_col] = true end
    return skip
end

local function key_columns(entry)
    if type(entry.key) == "table" then return entry.key end
    return { entry.key }
end

-- Given a table name, return the list of column names it actually has.
-- Cached per-table so the export/import walk doesn't re-query information_schema.
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

-- Sort the entries in a stable order for both export (deterministic diff)
-- and status (readable output). Sort by the entry's key columns.
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

--=============================================================================
-- EXPORT — DB → JSON files
--=============================================================================

-- Look up a stable-key value for an integer FK id (used when exporting).
-- Treats 0 as absent — 0 can never be a valid serial PK, but shows up in
-- older seed data on columns that lacked a NULL default at insert time.
local function deref_id_to_key(fk_spec, id)
    if id == nil or id == cjson.null or id == 0 then return nil end
    local rows = db.query("SELECT " .. fk_spec.key .. " AS k FROM " ..
                          fk_spec.table .. " WHERE id = ?", id)
    if not rows or #rows == 0 then
        return nil, "no " .. fk_spec.table .. " row with id=" .. tostring(id)
    end
    return rows[1].k, nil
end

local function export_one(entry, config_dir)
    local sql = "SELECT * FROM " .. entry.table
    -- Some in-scope tables (e.g. tax_hmrc_categories, tax_categories,
    -- income_types-linked ones) are already single-tenant and don't carry
    -- a namespace_id at all. Only apply the WHERE when the column exists.
    if (Registry.defaults.namespace_scope == "global_only") and column_exists(entry.table, "namespace_id") then
        -- Treat namespace_id IS NULL and namespace_id = 0 as equivalent —
        -- some seed migrations wrote 0, others wrote NULL. Both mean
        -- "global config, not tenant-scoped".
        sql = sql .. " WHERE (namespace_id IS NULL OR namespace_id = 0)"
    end
    local rows = db.query(sql) or {}
    sort_entries(entry, rows)

    local skip = merged_skip_columns(entry)
    local out_entries = {}
    local warnings = {}

    for _, row in ipairs(rows) do
        local out = {}
        -- Dereference FK columns first. 0 shows up on nullable FK columns
        -- whose seed data was inserted without an explicit NULL — treat it
        -- as absent to keep warnings signal-heavy.
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
        -- Copy remaining columns
        for col, val in pairs(row) do
            if not skip[col] then
                out[col] = val
            end
        end
        out_entries[#out_entries + 1] = out
    end

    local doc = {
        table = entry.table,
        key = entry.key,
        registry_version = Registry.version,
        exported_at_note = "regenerated by `lapis exec require('scripts.config-cli').export()`",
        entries = out_entries,
    }

    local path = config_dir .. "/" .. entry.file
    local ok, err = JSON.write_file(path, doc)
    if not ok then
        error("Failed to write " .. path .. ": " .. tostring(err))
    end
    return #out_entries, warnings
end

function M.export(config_dir_override)
    local config_dir = resolve_config_dir(config_dir_override)
    print("[cmi export] config dir: " .. config_dir)
    local total_rows, total_warnings = 0, 0
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        if not entry then
            error("export_order references '" .. tbl_name ..
                  "' but no entry exists in Registry.tables")
        end
        local count, warnings = export_one(entry, config_dir)
        total_rows = total_rows + count
        total_warnings = total_warnings + #warnings
        print(string.format("[cmi export]   %-32s %4d rows  → %s",
                            entry.table, count, entry.file))
        for _, w in ipairs(warnings) do
            print("[cmi export]     WARN: " .. w)
        end
    end
    print(string.format("[cmi export] done — %d rows across %d tables (%d warnings)",
                        total_rows, #Registry.export_order, total_warnings))
end

--=============================================================================
-- IMPORT — JSON files → DB
--=============================================================================

-- Look up an integer id for a stable-key value (used when importing).
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
    -- cjson.null → SQL NULL sentinel that db.query understands
    if v == cjson.null then return db.NULL end
    -- JSON objects / arrays go back to the DB as JSON strings; the columns
    -- are jsonb/text and postgres will parse them.
    if type(v) == "table" then return cjson.encode(v) end
    return v
end

-- Build the SET clause for an ON CONFLICT DO UPDATE — every non-key column.
-- The entry itself isn't consulted (all info is in key_cols + columns) but
-- kept in the signature for symmetry with the other builder helpers.
local function build_upsert(_entry, key_cols, columns)
    local key_set = {}
    for _, c in ipairs(key_cols) do key_set[c] = true end
    local set_frags = {}
    for _, c in ipairs(columns) do
        if not key_set[c] then
            set_frags[#set_frags + 1] = c .. " = EXCLUDED." .. c
        end
    end
    -- always bump updated_at if the target has one
    set_frags[#set_frags + 1] = "updated_at = NOW()"
    return table.concat(set_frags, ", ")
end


local function import_one(entry, config_dir, apply)
    local path = config_dir .. "/" .. entry.file
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

    -- Snapshot current keys so we can spot rows that disappeared.
    local existing = {}
    local snapshot_sql = "SELECT " .. table.concat(key_cols, ", ") ..
                         " FROM " .. entry.table
    if (Registry.defaults.namespace_scope == "global_only") and column_exists(entry.table, "namespace_id") then
        snapshot_sql = snapshot_sql .. " WHERE (namespace_id IS NULL OR namespace_id = 0)"
    end
    for _, r in ipairs(db.query(snapshot_sql) or {}) do
        local composite = {}
        for _, c in ipairs(key_cols) do composite[#composite + 1] = tostring(r[c]) end
        existing[table.concat(composite, "|")] = true
    end
    local seen = {}

    for _, yaml_row in ipairs(doc.entries or {}) do
        -- Resolve FKs (stable-key → integer id)
        local row = {}
        for k, v in pairs(yaml_row) do row[k] = v end
        local resolved_ok = true
        for local_col, spec in pairs(entry.fk_refs or {}) do
            local key_val = row[spec.as]
            row[spec.as] = nil -- consumed
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
            -- Track composite for is_active fallback
            local composite = {}
            for _, c in ipairs(key_cols) do composite[#composite + 1] = tostring(row[c]) end
            seen[table.concat(composite, "|")] = true

            -- Ensure uuid is present so an INSERT can succeed. Rule tables
            -- always carry their uuid in the YAML (it IS their identity);
            -- slug-keyed tables usually do too (round-tripped from the
            -- original int export). If it's missing, mint one the same
            -- way the seed migrations do — Global.generateUUID falls back
            -- to a non-ngx generator when invoked from the CLI.
            if row.uuid == nil and column_exists(entry.table, "uuid") then
                row.uuid = Global.generateUUID()
            end

            -- Build INSERT ... ON CONFLICT (keys) DO UPDATE SET ...
            local cols, vals = {}, {}
            for c, v in pairs(row) do
                cols[#cols + 1] = c
                vals[#vals + 1] = coerce_value(v)
            end

            local placeholders = {}
            for _ = 1, #cols do placeholders[#placeholders + 1] = "?" end

            local conflict_target = table.concat(key_cols, ", ")
            local set_clause = build_upsert(entry, key_cols, cols)

            local key_str = table.concat(composite, "|")
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
                -- Dry-run: we can't cheaply tell value-level drift here (JSON
                -- columns need a real deep-compare vs the DB row). Report
                -- STRUCTURAL drift only — new keys as inserts, missing keys
                -- as deactivates, existing keys as `matches`. A follow-up
                -- can add value-level diff for a stricter status.
                if existing[key_str] then
                    plan.matches = plan.matches + 1
                else
                    plan.inserts = plan.inserts + 1
                end
            end
        end
    end

    -- Rows in DB but missing from YAML → is_active = false (soft delete).
    if column_exists(entry.table, "is_active") then
        for composite_str in pairs(existing) do
            if not seen[composite_str] then
                plan.deactivates = plan.deactivates + 1
                if apply then
                    local parts = {}
                    for part in string.gmatch(composite_str, "([^|]+)") do
                        parts[#parts + 1] = part
                    end
                    local where_frags, where_vals = {}, {}
                    for i, c in ipairs(key_cols) do
                        where_frags[i] = c .. " = ?"
                        where_vals[i] = parts[i]
                    end
                    if (Registry.defaults.namespace_scope == "global_only") and column_exists(entry.table, "namespace_id") then
                        where_frags[#where_frags + 1] = "namespace_id IS NULL"
                    end
                    db.query("UPDATE " .. entry.table ..
                             " SET is_active = false, updated_at = NOW()" ..
                             " WHERE " .. table.concat(where_frags, " AND "),
                             unpack(where_vals))
                end
            end
        end
    end

    return plan
end

local function run_import(apply, config_dir_override)
    local config_dir = resolve_config_dir(config_dir_override)
    print(string.format("[cmi import] %s mode, config dir: %s",
                        apply and "APPLY" or "DRY-RUN", config_dir))
    local totals = { inserts = 0, updates = 0, deactivates = 0, errors = 0 }
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        local plan = import_one(entry, config_dir, apply)
        if plan.error then
            print(string.format("[cmi import] %-32s ERROR: %s",
                                entry.table, plan.error))
            totals.errors = totals.errors + 1
        else
            print(string.format("[cmi import]   %-32s +%d ~%d -%d",
                                entry.table, plan.inserts, plan.updates,
                                plan.deactivates))
            for _, e in ipairs(plan.errors) do
                print("[cmi import]     ROW ERROR: " .. e)
                totals.errors = totals.errors + 1
            end
            totals.inserts = totals.inserts + plan.inserts
            totals.updates = totals.updates + plan.updates
            totals.deactivates = totals.deactivates + plan.deactivates
        end
    end
    print(string.format("[cmi import] done — %d inserts, %d updates, %d deactivates, %d errors",
                        totals.inserts, totals.updates, totals.deactivates, totals.errors))
    if totals.errors > 0 then
        error("[cmi import] " .. totals.errors .. " errors above — aborting.")
    end
end

function M.import_dry(config_dir_override) run_import(false, config_dir_override) end
function M.import_apply(config_dir_override) run_import(true, config_dir_override) end

--=============================================================================
-- STATUS — one-line drift summary
--=============================================================================

function M.status(config_dir_override)
    local config_dir = resolve_config_dir(config_dir_override)
    print("[cmi status] config dir: " .. config_dir)
    print("[cmi status] (v1 reports structural drift only: added/removed rows.")
    print("[cmi status]  value-level drift on existing rows is a follow-up.)")
    local any_drift = false
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        local plan = import_one(entry, config_dir, false)
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
        -- error() propagates to `lapis exec` as non-zero exit without
        -- killing the openresty worker (which os.exit would).
        error("[cmi status] structural drift detected — run import_dry() for details, then import_apply() to apply.")
    else
        print("[cmi status] no structural drift.")
    end
end

return M
