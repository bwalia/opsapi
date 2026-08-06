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

-- Hard caps to protect the process against runaway inputs.
-- MAX_ENTRIES_PER_TABLE keeps a bad bundle from OOM-ing the openresty
-- worker while parsing rows into memory. 50,000 is 60× the biggest
-- catalogue we ship today (profile_questions with ~400) — well under
-- Lua table headroom, well above any real-world admin catalogue.
local MAX_ENTRIES_PER_TABLE = 50000

-- Slug shape enforced everywhere a namespace slug crosses a trust
-- boundary. `namespaces.slug` in Postgres is already a varchar; this
-- rejects anything a Lua/SQL/shell layer could interpret badly if the
-- string reached one of those verbatim (spaces, quotes, semicolons).
local SLUG_PATTERN = "^[a-z][a-z0-9%-]*$"
local SLUG_MAX_LEN = 64
local function validate_slug(slug)
    if type(slug) ~= "string" or #slug == 0 or #slug > SLUG_MAX_LEN or
       not slug:match(SLUG_PATTERN) then
        error("Invalid namespace slug '" .. tostring(slug) .. "': must be " ..
              "1-" .. SLUG_MAX_LEN .. " chars matching " .. SLUG_PATTERN)
    end
end

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
-- validate_slug() rejects anything that could sneak past a shell/Lua
-- interpolation layer (workflow_dispatch inputs travel as strings).
local function resolve_namespace(slug)
    validate_slug(slug)
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
-- (namespace-cleanup migration not yet applied). Cached per worker after
-- the first success — the check is 11 COUNT(*) queries and the answer
-- only changes if someone directly writes ns=0 rows to the DB (which
-- would be a separate bug worth surfacing loudly, but not on every
-- import step).
local _preflight_ok = false
local function preflight_namespace_cleanliness()
    if _preflight_ok then return end
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
    _preflight_ok = true
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

-- Startup: guarantee every registry entry has a distinct (scope, file)
-- pair. Two entries sharing the same file name would let entry_for_path
-- silently return the wrong table on bundle import, applying doc A's
-- rows to table B — data corruption with no error surfacing. Fail loud
-- at load rather than trust the registry is well-formed.
do
    local seen = {}
    for tbl_name, entry in pairs(Registry.tables) do
        local scope_key = entry.namespace_scope == "global" and "_global" or "<slug>"
        local path_key = scope_key .. "/" .. entry.file
        if seen[path_key] then
            error("Registry duplicate file path: '" .. path_key ..
                  "' claimed by both '" .. seen[path_key] .. "' and '" .. tbl_name .. "'")
        end
        seen[path_key] = tbl_name
    end
    -- Also assert every export_order entry actually exists in tables{}.
    -- A typo here would cause a nil-index crash mid-export otherwise.
    for _, tbl_name in ipairs(Registry.export_order) do
        if not Registry.tables[tbl_name] then
            error("Registry.export_order references '" .. tbl_name ..
                  "' but Registry.tables has no such entry")
        end
    end
end

--=============================================================================
-- EXPORT
--=============================================================================

-- Load an id→key lookup for one FK target table, in ONE query. Replaces
-- what used to be N+1 (one SELECT per row for the same target). Called
-- once per (fk_spec.table, fk_spec.key) pair per export_one invocation;
-- for 96 tax_categories with one hmrc_category_id FK that's 1 query
-- instead of 96.
local function load_fk_lookup(fk_spec)
    local rows = db.query("SELECT id, " .. fk_spec.key .. " AS k FROM " .. fk_spec.table)
    local map = {}
    for _, r in ipairs(rows or {}) do
        map[r.id] = r.k
    end
    return map
end

-- Build the export doc for one table as a Lua table — no disk I/O.
-- Shared between disk-mode (export_one) and bundle-mode (M.export_bundle
-- for the admin UI). Returns (doc, warnings).
local function build_export_doc(entry, ns_slug, target_ns_id)
    local where_frag, where_binds = scope_where(entry, target_ns_id)
    local sql = "SELECT " .. entry.table .. ".* FROM " .. entry.table .. where_frag
    local rows = db.query(sql, unpack(where_binds)) or {}
    sort_entries(entry, rows)

    -- Pre-load id→key maps for every FK we'll dereference. Bounded by
    -- the size of the parent config table (never large — hmrc_categories
    -- ~18 rows, profile_categories ~80). One query per FK column.
    local fk_maps = {}
    for local_col, spec in pairs(entry.fk_refs or {}) do
        fk_maps[local_col] = load_fk_lookup(spec)
    end

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
                local k = fk_maps[local_col][id]
                if k == nil then
                    warnings[#warnings + 1] = entry.table .. ": " ..
                        local_col .. "=" .. tostring(id) ..
                        " no " .. spec.table .. " row"
                    if spec.required then
                        error("EXPORT FAILED: " .. warnings[#warnings])
                    end
                    out[spec.as] = cjson.null
                else
                    out[spec.as] = k
                end
            end
        end
        for col, val in pairs(row) do
            if not skip[col] then out[col] = val end
        end
        out_entries[#out_entries + 1] = out
    end

    -- Force `entries` to serialise as an ARRAY even when empty.
    -- cjson's default for `{}` is object; setmetatable pins the type
    -- so downstream JSON output (json_pretty + cjson.encode both
    -- consult the metatable) produces `[]` deterministically. Empty
    -- catalogues (e.g. profile_lookup_values on a fresh env) render
    -- as `[]` — same shape whether populated or not, git diffs stay
    -- clean.
    if #out_entries == 0 then
        setmetatable(out_entries, cjson.array_mt)
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
    return doc, warnings
end

local function export_one(entry, config_dir, ns_slug, target_ns_id)
    local doc, warnings = build_export_doc(entry, ns_slug, target_ns_id)
    local subdir = config_dir .. "/" .. subfolder(entry, ns_slug)
    ensure_dir(subdir)
    local path = subdir .. "/" .. entry.file
    local ok, err = JSON.write_file(path, doc)
    if not ok then
        error("Failed to write " .. path .. ": " .. tostring(err))
    end
    return #doc.entries, warnings
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

local function build_upsert(entry, key_cols, columns)
    local key_set = {}
    for _, c in ipairs(key_cols) do key_set[c] = true end
    local set_frags = {}
    for _, c in ipairs(columns) do
        if not key_set[c] then
            set_frags[#set_frags + 1] = c .. " = EXCLUDED." .. c
        end
    end
    -- Bump updated_at ONLY if the table has it. Some link tables (e.g.
    -- profile_question_touchpoints) don't carry timestamps — appending
    -- `updated_at = NOW()` there fails with "column does not exist".
    if column_exists(entry.table, "updated_at") then
        set_frags[#set_frags + 1] = "updated_at = NOW()"
    end
    -- ON CONFLICT DO UPDATE SET requires at least one SET clause. If
    -- every column is a key column and the table has no updated_at
    -- (a pure join row), fall back to a no-op on one of the key cols
    -- so ON CONFLICT still resolves cleanly.
    if #set_frags == 0 then
        set_frags[#set_frags + 1] = key_cols[1] .. " = EXCLUDED." .. key_cols[1]
    end
    return table.concat(set_frags, ", ")
end

-- Apply a single parsed doc against the DB — the doc is a Lua table
-- (already JSON-decoded), no disk I/O. Shared between disk-mode
-- (import_one reads the file then calls this) and bundle-mode
-- (M.import_bundle_* has docs in memory). Returns the plan struct.
local function apply_import_doc(entry, doc, ns_slug, target_ns_id, apply)
    if doc.table ~= entry.table then
        return { table = entry.table, error = "doc claims table='" ..
                 tostring(doc.table) .. "' but registry expects '" ..
                 entry.table .. "'" }
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
                -- Under a transaction, ANY Postgres error poisons the
                -- txn — every subsequent statement fails with "current
                -- transaction is aborted" until ROLLBACK. So we can't
                -- swallow the error and continue like dry-run does;
                -- one row failure means the whole apply is doomed.
                -- Raise so the outer pcall catches it and rolls back
                -- the transaction cleanly, then reports the real cause.
                local ok_q, err_q = pcall(db.query,
                    "INSERT INTO " .. entry.table ..
                    " (" .. table.concat(cols, ", ") .. ")" ..
                    " VALUES (" .. table.concat(placeholders, ", ") .. ")" ..
                    " ON CONFLICT (" .. conflict_target .. ")" ..
                    " DO UPDATE SET " .. set_clause,
                    unpack(vals))
                if not ok_q then
                    error(entry.table .. " row " ..
                          (row[key_cols[1]] or "?") .. ": " .. tostring(err_q))
                end
                if existing[key_str] then
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
                    local set_clause_deact = "is_active = false"
                    if column_exists(entry.table, "updated_at") then
                        set_clause_deact = set_clause_deact .. ", updated_at = NOW()"
                    end
                    db.query("UPDATE " .. entry.table ..
                             " SET " .. set_clause_deact ..
                             " WHERE " .. table.concat(wf, " AND "),
                             unpack(wv))
                end
            end
        end
    end

    return plan
end

-- Disk-mode thin wrapper: reads the file, delegates to apply_import_doc.
local function import_one(entry, config_dir, ns_slug, target_ns_id, apply)
    local path = config_dir .. "/" .. subfolder(entry, ns_slug) .. "/" .. entry.file
    local doc, err = JSON.read_file(path)
    if not doc then
        return { table = entry.table, error = "cannot read " .. path .. ": " .. tostring(err) }
    end
    return apply_import_doc(entry, doc, ns_slug, target_ns_id, apply)
end

local function run_import(apply, config_dir_override, namespace_slug)
    local config_dir = resolve_config_dir(config_dir_override)
    local target_ns_id = resolve_namespace(namespace_slug)
    preflight_namespace_cleanliness()
    print(string.format("[cmi import] %s mode, namespace=%s (id=%d), config dir=%s",
                        apply and "APPLY" or "DRY-RUN", namespace_slug, target_ns_id, config_dir))

    -- Wrap the whole apply in a single transaction. Without this, a
    -- worker crash / connection drop / uncaught error halfway through
    -- leaves the DB with N tables imported and 18-N tables stale — a
    -- silent split-brain nobody would notice until the next diff.
    -- Dry-run doesn't write, so no transaction needed there.
    if apply then db.query("BEGIN") end
    local totals = { inserts = 0, updates = 0, matches = 0, deactivates = 0, errors = 0 }
    local ok, walk_err = pcall(function()
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
    end)
    if apply and (not ok or totals.errors > 0) then
        db.query("ROLLBACK")
        if not ok then error("[cmi import] aborted mid-flight: " .. tostring(walk_err)) end
        error("[cmi import] " .. totals.errors .. " errors above — rolled back.")
    end
    if apply then db.query("COMMIT") end

    print(string.format("[cmi import] done — %d inserts, %d updates, %d matches, %d deactivates, %d errors",
                        totals.inserts, totals.updates, totals.matches, totals.deactivates, totals.errors))
    if not apply and totals.errors > 0 then
        error("[cmi import] " .. totals.errors .. " errors above (dry-run).")
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

--=============================================================================
-- BUNDLE MODE — for the admin UI (no filesystem I/O)
--=============================================================================
--
-- The disk-based functions above (M.export/M.import_*/M.status) are what
-- the CLI + CI workflows use. The admin dashboard needs the same round-trip
-- via HTTP: a single downloadable JSON blob out, a single uploadable JSON
-- blob back in. The bundle functions below produce and consume that shape.
--
-- Bundle shape (a plain Lua table serialised as JSON at the HTTP boundary):
--
--   {
--     version         = 1,
--     namespace_slug  = "tax-copilot",
--     exported_at     = "<ISO8601>",     -- opaque marker, not verified on import
--     export_order    = { <table names in dep order> },
--     files = {
--       "_global/tax_hmrc_categories.json" = { <doc as produced by build_export_doc> },
--       "tax-copilot/income_types.json"    = { ... },
--       ...
--     },
--   }
--
-- The key of `files` matches the on-disk relative path so bundle output can
-- be spot-checked against the git baseline without any transformation.

local function isotime()
    -- No dependency on `date` helper; POSIX `os.date("!%FT%TZ")` gives UTC.
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Build the whole export in memory. Returns (bundle, total_rows, warnings).
-- Caller is expected to JSON-encode the bundle for transport.
function M.export_bundle(namespace_slug)
    local target_ns_id = resolve_namespace(namespace_slug)
    preflight_namespace_cleanliness()
    local bundle = {
        version = 1,
        namespace_slug = namespace_slug,
        exported_at = isotime(),
        export_order = Registry.export_order,
        files = {},
        table_row_counts = {},
    }
    local total_rows, all_warnings = 0, {}
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        if not entry then
            error("export_order references '" .. tbl_name ..
                  "' but no entry exists in Registry.tables")
        end
        local doc, warnings = build_export_doc(entry, namespace_slug, target_ns_id)
        local path = subfolder(entry, namespace_slug) .. "/" .. entry.file
        bundle.files[path] = doc
        bundle.table_row_counts[entry.table] = #doc.entries
        total_rows = total_rows + #doc.entries
        for _, w in ipairs(warnings) do all_warnings[#all_warnings + 1] = w end
    end
    return bundle, total_rows, all_warnings
end

-- Look up an entry by the path key produced during export.
local function entry_for_path(path)
    for _, tbl_name in ipairs(Registry.export_order) do
        local entry = Registry.tables[tbl_name]
        local expected = subfolder(entry, "*") -- namespace-agnostic match
        -- match "<any>/<entry.file>" — the leading segment is the namespace
        -- slug or "_global" per subfolder() rules, either is acceptable
        -- because scope filtering was already applied at export time.
        if path:sub(- #entry.file - 1) == "/" .. entry.file then
            return entry
        end
        -- silence unused var
        local _ = expected
    end
    return nil
end

-- Iterate a bundle's files in export_order (parents first). Returns an
-- array of { entry, doc } pairs, or errors on unknown paths.
local function ordered_bundle_docs(bundle)
    local docs_by_table = {}
    for path, doc in pairs(bundle.files or {}) do
        local entry = entry_for_path(path)
        if not entry then
            error("bundle contains unknown file path: " .. tostring(path))
        end
        docs_by_table[entry.table] = { entry = entry, doc = doc, path = path }
    end
    local out = {}
    for _, tbl_name in ipairs(Registry.export_order) do
        if docs_by_table[tbl_name] then
            out[#out + 1] = docs_by_table[tbl_name]
        end
    end
    return out
end

-- Import a bundle (already-parsed Lua table). `apply` controls dry-run vs
-- write. Returns { plans = [...], totals = {...} } — no printing, all data.
--
-- Apply wraps every write in ONE transaction. If any table's upsert
-- errors, or a plan carries row-level errors, we ROLLBACK — no partial
-- imports. Dry-run needs no transaction (reads only).
local function run_bundle_import(bundle, namespace_slug, apply)
    if not bundle or type(bundle) ~= "table" then
        error("bundle must be a table (JSON-decoded); got " .. type(bundle))
    end
    if bundle.version ~= 1 then
        error("bundle version " .. tostring(bundle.version) ..
              " not supported (this CLI understands version 1)")
    end
    -- Enforce entries-per-table ceiling. Protects the worker from OOM
    -- when someone posts a bundle with a runaway array. Applied here
    -- rather than at the HTTP boundary so the CLI path also benefits.
    for path, doc in pairs(bundle.files or {}) do
        if doc and doc.entries and #doc.entries > MAX_ENTRIES_PER_TABLE then
            error("bundle file '" .. tostring(path) .. "' has " ..
                  #doc.entries .. " entries — exceeds MAX_ENTRIES_PER_TABLE=" ..
                  MAX_ENTRIES_PER_TABLE)
        end
    end
    -- namespace_slug from bundle is informational; target is the caller's.
    -- Cross-tenant apply is fine if the operator is explicit.
    local target_ns_id = resolve_namespace(namespace_slug)
    preflight_namespace_cleanliness()

    local ordered = ordered_bundle_docs(bundle)
    local plans = {}
    local totals = { inserts = 0, updates = 0, matches = 0,
                     deactivates = 0, errors = 0 }

    if apply then db.query("BEGIN") end
    local ok, walk_err = pcall(function()
        for _, item in ipairs(ordered) do
            local plan = apply_import_doc(item.entry, item.doc, namespace_slug,
                                          target_ns_id, apply)
            plans[#plans + 1] = plan
            if plan.error then
                totals.errors = totals.errors + 1
            else
                totals.inserts = totals.inserts + (plan.inserts or 0)
                totals.updates = totals.updates + (plan.updates or 0)
                totals.matches = totals.matches + (plan.matches or 0)
                totals.deactivates = totals.deactivates + (plan.deactivates or 0)
                totals.errors = totals.errors + #(plan.errors or {})
            end
        end
    end)
    if apply and (not ok or totals.errors > 0) then
        db.query("ROLLBACK")
        if not ok then error("[cmi bundle-import] aborted mid-flight: " .. tostring(walk_err)) end
        -- Row-level errors: return the plans (they contain the error
        -- detail) but mark applied=false so the caller knows nothing
        -- actually wrote.
        return { plans = plans, totals = totals,
                 namespace_slug = namespace_slug,
                 target_ns_id = target_ns_id,
                 applied = false,
                 rolled_back = true }
    end
    if apply then db.query("COMMIT") end

    return { plans = plans, totals = totals,
             namespace_slug = namespace_slug,
             target_ns_id = target_ns_id,
             applied = apply }
end

function M.import_bundle_plan(bundle, namespace_slug)
    return run_bundle_import(bundle, namespace_slug, false)
end

function M.import_bundle_apply(bundle, namespace_slug)
    return run_bundle_import(bundle, namespace_slug, true)
end

return M
