--[[
  Project-Migration History Seeder
  ================================

  Companion to helper/project-migrator.lua (which runs plugin-project
  migrations under /app/projects/<code>/migrations/ and tracks them in
  project_migrations). This script pre-seeds project_migrations rows on
  environments where the equivalent DDL was already applied by opsapi's
  OWN monorepo migrations under a different key.

  WHY THIS EXISTS
  ---------------
  Historically, migrations for a specific consumer product (e.g.
  tax_copilot) lived under opsapi's lapis/migrations/*.lua and were
  registered in lapis/migrations.lua as `<n>_<name>` keys tracked in
  lapis_migrations. That tightly coupled the consumer's schema to
  opsapi's release cadence.

  Consumer products are moving to owning their own migrations in their
  own repos, delivered as a small image FROM bwalia/opsapi that COPYs
  the migrations under /app/projects/<code>/migrations/ and invokes
  helper.project-migrator at deploy time. Per-consumer history is
  tracked in project_migrations, not lapis_migrations.

  On a FRESH environment this is trivial: no rows in either table, the
  new consumer migrate-job runs everything from scratch.

  On an EXISTING environment (int/test/acc/prod) the extracted
  migrations were ALREADY APPLIED by opsapi under the old keys — their
  tables exist. If the consumer migrate-job just ran, it would try to
  CREATE TABLE those tables again. Every extracted migration uses
  `IF NOT EXISTS`, so the DDL succeeds silently — but the intent gets
  muddy, and more importantly a subsequent extracted migration that
  ALTERs a column that older opsapi versions never had would fail hard.

  This script closes the gap. It reads a manifest that maps
  old-opsapi-key -> new-consumer-filename, and for every mapping where
  the old key is recorded in lapis_migrations it INSERTS a matching row
  in project_migrations. The consumer migrate-job then treats those
  extracted migrations as "already applied" and skips them entirely.

  MANIFEST FORMAT
  ---------------
  Loaded from a JSON file at a caller-supplied path (typically
  /app/projects/<code>/RECONCILE.json inside the consumer image).
  Structure:

      {
        "$doc":     "human-readable pointer to the format docs",
        "project_code": "<must match the caller-supplied project_code>",
        "entries": [
          { "legacy_key": "775_seed_sa105_property_completion",
            "consumer_migration": "20260801_001_seed_sa105_property_completion" },
          ...
        ]
      }

  `project_code` inside the manifest is a belt-and-braces check — if
  the caller passes one project_code but the manifest declares a
  different one, we abort loudly so a mis-mounted manifest can't seed
  the wrong ledger.

  RUN CHARACTERISTICS
  -------------------
  - Idempotent: uses ON CONFLICT DO NOTHING on (project_code,
    migration_name), so re-running against an already-seeded env is a
    no-op.
  - Skip-safe: if a legacy_key is not present in lapis_migrations (a
    fresh env, or a partial-extract state), the entry is skipped
    silently — the consumer migrate-job will run the extracted
    migration itself. No side-effects.
  - Non-fatal on manifest error: a bad or missing JSON prints a
    warning and returns 0. The deploy still succeeds. Rationale: the
    manifest is an OPTIMISATION, not a correctness requirement — even
    without it, IF NOT EXISTS guards prevent double-creates.

  USAGE
  -----
  Invoked from the consumer migrations chart's reconcile hook:

      lapis exec "require('scripts.seed-project-history').run(
          'tax_copilot_app',
          '/app/projects/tax-copilot-app/RECONCILE.json'
      )"

  The hook is wired at pre-upgrade weight -1 so it fires BEFORE the
  consumer's migrate-job (weight +5) — see the diytaxreturn-migrations
  Helm chart for the deploy-side wiring.
]]

local db     = require("lapis.db")
local cjson  = require("cjson.safe")
local ProjectMigrator = require("helper.project-migrator")

local M = {}

-- Read a file into a string. Returns (contents, nil) on success or
-- (nil, err) on failure. Kept small on purpose — cjson does the
-- structural validation.
local function read_file(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, "open failed: " .. tostring(err)
    end
    local body = f:read("*a")
    f:close()
    if not body then
        return nil, "read returned nil for " .. path
    end
    return body, nil
end

-- Parse the manifest JSON and enforce the minimum shape we depend on.
-- On any structural problem we return (nil, err) so the caller can
-- print a warning and continue — this is not a fatal path.
local function load_manifest(path, expected_project_code)
    local body, read_err = read_file(path)
    if not body then
        return nil, "cannot read manifest at " .. path .. ": " .. read_err
    end

    local doc, parse_err = cjson.decode(body)
    if not doc then
        return nil, "JSON parse failed for " .. path .. ": " .. tostring(parse_err)
    end

    if type(doc) ~= "table" then
        return nil, "manifest root must be a JSON object, got " .. type(doc)
    end

    if doc.project_code and doc.project_code ~= expected_project_code then
        return nil, string.format(
            "manifest project_code mismatch: manifest says %q but caller passed %q — refusing to seed the wrong ledger",
            tostring(doc.project_code), tostring(expected_project_code))
    end

    if type(doc.entries) ~= "table" then
        return nil, "manifest has no `entries` array (or it's not an array)"
    end

    return doc, nil
end

-- Build a set { migration_name = true, ... } of everything currently
-- recorded in opsapi's core lapis_migrations. We consult this set
-- (not the DB per-entry) so seeding a 100-entry manifest is one query,
-- not 100.
local function load_applied_lapis_migrations()
    local ok, rows = pcall(db.query, "SELECT name FROM lapis_migrations")
    if not ok then
        return nil, "cannot read lapis_migrations: " .. tostring(rows)
    end
    local set = {}
    for _, row in ipairs(rows or {}) do
        set[row.name] = true
    end
    return set, nil
end

--- Seed project_migrations rows for extracted migrations that opsapi
--- already applied under their old keys.
---
--- @param project_code       string  Must match the `code` in the
---                                    consumer's project.lua (and, if
---                                    present, the manifest's own
---                                    `project_code` field).
--- @param manifest_path      string  Absolute path to the RECONCILE.json
---                                    inside the consumer image.
--- @return number  seeded   Count of newly-inserted rows.
function M.run(project_code, manifest_path)
    print(string.format(
        "[seed-project-history] Reconciling project=%q from manifest=%q",
        project_code, manifest_path))

    if type(project_code) ~= "string" or project_code == "" then
        print("[seed-project-history] WARNING: project_code missing — nothing to do.")
        return 0
    end

    local doc, err = load_manifest(manifest_path, project_code)
    if not doc then
        print("[seed-project-history] WARNING: " .. err .. " — skipping seed pass.")
        return 0
    end

    if #doc.entries == 0 then
        print("[seed-project-history] Manifest has 0 entries — nothing to reconcile yet.")
        return 0
    end

    local applied, applied_err = load_applied_lapis_migrations()
    if not applied then
        print("[seed-project-history] WARNING: " .. applied_err .. " — skipping seed pass.")
        return 0
    end

    -- Ensure the target table exists. The consumer migrate-job would
    -- create it on its own first invocation, but this hook runs
    -- BEFORE the migrate-job (pre-upgrade weight -1 vs +5), so we
    -- can't rely on that ordering.
    ProjectMigrator.ensureTrackingTable()

    local seeded, skipped, already = 0, 0, 0
    for _, entry in ipairs(doc.entries) do
        if type(entry) ~= "table"
           or type(entry.legacy_key) ~= "string"
           or type(entry.consumer_migration) ~= "string" then
            print("[seed-project-history] WARNING: skipping malformed entry: " ..
                  cjson.encode(entry))
        elseif applied[entry.legacy_key] then
            -- ON CONFLICT DO NOTHING makes this idempotent — a re-run
            -- against an already-seeded env prints "already" for every
            -- entry, not an insert-followed-by-primary-key-error.
            local ins_ok, ins_err = pcall(db.query, [[
                INSERT INTO project_migrations (project_code, migration_name, checksum)
                VALUES (?, ?, NULL)
                ON CONFLICT (project_code, migration_name) DO NOTHING
                RETURNING id
            ]], project_code, entry.consumer_migration)
            if not ins_ok then
                print(string.format(
                    "[seed-project-history] WARNING: INSERT failed for %s -> %s: %s",
                    entry.legacy_key, entry.consumer_migration, tostring(ins_err)))
            else
                -- pcall returns the query result; RETURNING id gives us
                -- one row on insert, zero rows on conflict-do-nothing.
                if type(ins_err) == "table" and #ins_err > 0 then
                    seeded = seeded + 1
                    print(string.format("[seed-project-history]   + %s -> %s",
                        entry.legacy_key, entry.consumer_migration))
                else
                    already = already + 1
                end
            end
        else
            skipped = skipped + 1
        end
    end

    print(string.format(
        "[seed-project-history] Done: %d seeded, %d already-present, %d skipped (opsapi never applied).",
        seeded, already, skipped))
    return seeded
end

return M
