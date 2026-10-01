--[[
  Plugin (project) migration runner
  =================================

  Runs projects/<plugin>/migrations/*.lua in filename order, once each,
  tracked per plugin in `project_migrations` (separate from core
  lapis_migrations). `lapis migrate` runs every plugin via the
  zzx_run_project_migrations core migration; consumer images call
  migrate(code, path) directly from their deploy hook.

  A migration file returns either

    return function(schema, db) ... end

  or, when a statement can't run inside a transaction (CREATE INDEX
  CONCURRENTLY):

    return { transaction = false, up = function(schema, db) ... end }

  Guarantees:
    * each migration + its tracking row commit together (a savepoint when
      already inside `lapis migrate --transaction/--dry-run`), so a failure
      never leaves a half-applied migration marked as done
    * one runner at a time across pods/hooks (Postgres advisory lock)
    * a file edited after it was applied is reported (checksum drift)
    * the plugin's manifest `modules` are added to the RBAC `modules` table,
      its `menu` entries to the dashboard sidebar (menu_items), and its event
      subscriptions / published tables to helper.plugin-events
    * any failure raises, so the deploy step fails instead of shipping pods
      without their schema
]]

local schema = require("lapis.db.schema")
local db = require("lapis.db")

local ProjectMigrator = {}

local LOCK_KEY = "opsapi.project_migrations"

-- ---------------------------------------------------------------------------
-- Tracking table
-- ---------------------------------------------------------------------------

function ProjectMigrator.ensureTrackingTable()
    db.query([[
        CREATE TABLE IF NOT EXISTS project_migrations (
            id SERIAL PRIMARY KEY,
            project_code VARCHAR(100) NOT NULL,
            migration_name VARCHAR(255) NOT NULL,
            executed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
            checksum VARCHAR(64),
            UNIQUE(project_code, migration_name)
        )
    ]])
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_project_migrations_code
        ON project_migrations(project_code)
    ]])
end

--- Executed migrations of a project: name -> checksum (false when unknown).
function ProjectMigrator.getExecuted(project_code)
    local rows = db.select("migration_name, checksum FROM project_migrations WHERE project_code = ?", project_code)
    local executed = {}
    for _, row in ipairs(rows) do
        executed[row.migration_name] = row.checksum ~= db.NULL and row.checksum or false
    end
    return executed
end

function ProjectMigrator.recordExecution(project_code, migration_name, checksum)
    db.insert("project_migrations", {
        project_code = project_code,
        migration_name = migration_name,
        checksum = checksum or db.NULL,
    })
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

--- Migration files in a directory, in filename order.
-- @return table List of { name, path }
function ProjectMigrator.discover(migrations_dir)
    local files = {}
    for _, entry in ipairs(require("helper.project-loader").listDir(migrations_dir)) do
        if entry:match("%.lua$") then
            table.insert(files, { name = entry:gsub("%.lua$", ""), path = migrations_dir .. "/" .. entry })
        end
    end
    return files
end

local function checksum(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    return db.query("SELECT encode(sha256(convert_to(?, 'UTF8')), 'hex') AS c", src)[1].c
end

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

-- `lapis migrate --transaction/--dry-run` wraps everything in one transaction;
-- a COMMIT of ours would end it (and make a dry run real). now() is the
-- transaction start, so it only differs from the statement start inside one.
local function in_transaction()
    return db.query("SELECT now() <> statement_timestamp() AS t")[1].t
end

local function load_migration(path)
    local chunk, err = loadfile(path)
    if not chunk then error(err, 0) end
    local m = chunk()
    if type(m) == "function" then return m, true end
    if type(m) == "table" and type(m.up) == "function" then return m.up, m.transaction ~= false end
    error("must return function(schema, db) or { up = function(schema, db) ... }", 0)
end

local function run_one(project_code, mig, sum)
    local label = project_code .. "/" .. mig.name
    print("[ProjectMigrator] " .. label .. ": running")

    local ok, up, use_tx = pcall(load_migration, mig.path)
    if not ok then error(label .. " failed to load: " .. tostring(up), 0) end

    local begin, commit, rollback = "BEGIN", "COMMIT", "ROLLBACK"
    if use_tx and in_transaction() then
        begin, commit, rollback = "SAVEPOINT project_migration",
            "RELEASE SAVEPOINT project_migration", "ROLLBACK TO SAVEPOINT project_migration"
    end

    if use_tx then db.query(begin) end
    local ok_run, err = pcall(function()
        up(schema, db)
        ProjectMigrator.recordExecution(project_code, mig.name, sum)
    end)
    if not ok_run then
        if use_tx then pcall(db.query, rollback) end
        error(label .. " failed: " .. tostring(err), 0)
    end
    if use_tx then db.query(commit) end
end

--- Add the plugin's manifest modules to `modules` so roles can be granted
-- them, giving admin/owner roles "manage" the first time a module appears
-- (as ModuleQueries.create does). Existing modules are left alone, so a
-- permission an admin revoked isn't re-granted on the next deploy.
local function sync_modules(manifest)
    for _, m in ipairs(manifest.modules) do
        local inserted = db.query([[
            INSERT INTO modules (uuid, machine_name, name, description, category, priority,
                                 is_active, is_system, default_actions, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, '0', true, false,
                    'create,read,update,delete,manage', NOW(), NOW())
            ON CONFLICT (machine_name) DO NOTHING
            RETURNING id
        ]], m.machine_name, m.name or m.machine_name, m.description or "", m.category or manifest.name)
        if inserted[1] then
            require("queries.ModuleQueries").propagateToNamespaceAdmins(m.machine_name)
            print("[ProjectMigrator] " .. manifest.code .. ": added RBAC module " .. m.machine_name)
        end
    end
end

--- Upsert the manifest's sidebar entries into menu_items (key
-- plugin:<code>:<resource>) and hide ones the manifest no longer lists.
-- Per-namespace overrides live in namespace_menu_config and are untouched.
local function sync_menu(manifest)
    local prefix = "plugin:" .. manifest.code .. ":"
    local slug = manifest.code:gsub("_", "-")
    local keys = {}
    for i, e in ipairs(manifest.menu) do
        local key = prefix .. e.resource
        db.query([[
            INSERT INTO menu_items (uuid, key, name, icon, path, module, required_action, priority,
                                    is_active, is_admin_only, always_show, settings, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, 'read', ?, true, false, false, '{}', NOW(), NOW())
            ON CONFLICT (key) DO UPDATE SET name = EXCLUDED.name, icon = EXCLUDED.icon, path = EXCLUDED.path,
                module = EXCLUDED.module, priority = EXCLUDED.priority, is_active = true, updated_at = NOW()
        ]], key, e.label, e.icon or "Puzzle", "/dashboard/plugins/" .. slug .. "/" .. e.resource,
            e.module, tonumber(e.priority) or 90 + i)
        keys[#keys + 1] = db.escape_literal(key)
    end
    db.query("UPDATE menu_items SET is_active = false, updated_at = NOW() WHERE is_active AND left(key, "
        .. #prefix .. ") = " .. db.escape_literal(prefix)
        .. (#keys > 0 and (" AND key NOT IN (" .. table.concat(keys, ", ") .. ")") or ""))
end

--- Apply the manifest to the database: RBAC modules, sidebar menu, and the
-- events it publishes / subscribes to (then the table triggers that feed them).
function ProjectMigrator.syncManifest(project_path)
    local manifest = require("helper.project-loader").loadManifest(project_path .. "/project.lua", project_path)
    if not manifest then return end
    sync_modules(manifest)
    sync_menu(manifest)
    local PluginEvents = require("helper.plugin-events")
    PluginEvents.ensureSchema()
    PluginEvents.syncPlugin(manifest)
    PluginEvents.syncTriggers()
end

local function run_pending(project_code, project_path)
    local executed = ProjectMigrator.getExecuted(project_code)
    local count = 0
    for _, mig in ipairs(ProjectMigrator.discover(project_path .. "/migrations")) do
        local sum = checksum(mig.path)
        local applied = executed[mig.name]
        if applied == nil then
            run_one(project_code, mig, sum)
            count = count + 1
        elseif applied and applied ~= sum then
            print("[ProjectMigrator] WARNING: " .. project_code .. "/" .. mig.name
                .. " was edited after it was applied — add a new migration instead")
        end
    end
    ProjectMigrator.syncManifest(project_path)
    return count
end

--- Run pending migrations for one plugin. Raises on failure.
-- @return number Number of migrations executed
function ProjectMigrator.migrate(project_code, project_path)
    ProjectMigrator.ensureTrackingTable()

    db.query("SELECT pg_advisory_lock(hashtext(?))", LOCK_KEY)
    local ok, res = pcall(run_pending, project_code, project_path)
    db.query("SELECT pg_advisory_unlock(hashtext(?))", LOCK_KEY)
    if not ok then error(res, 0) end

    print("[ProjectMigrator] " .. project_code .. ": "
        .. (res == 0 and "up to date" or (res .. " migration(s) applied")))
    return res
end

--- Run migrations for every plugin under projects_root. Every plugin is
-- attempted; if any failed this raises at the end.
-- @return number Total migrations executed
function ProjectMigrator.migrateAll(projects_root)
    local ProjectLoader = require("helper.project-loader")
    local total, failed = 0, {}

    for _, entry in ipairs(ProjectLoader.discover(projects_root)) do
        local manifest, err = ProjectLoader.loadManifest(entry.manifest_path, entry.path)
        if manifest and manifest.enabled then
            local ok, res = pcall(ProjectMigrator.migrate, manifest.code, manifest.path)
            if ok then
                total = total + res
            else
                err = res
            end
        end
        if err then
            print("[ProjectMigrator] ERROR: " .. entry.dir_name .. ": " .. tostring(err))
            table.insert(failed, entry.dir_name)
        end
    end

    -- Core event sources, the audit-trail subscriptions (OPSAPI_AUDIT_ENABLED)
    -- and the table triggers — every migrate, plugins or not.
    local ok, err = pcall(function()
        local PluginEvents = require("helper.plugin-events")
        PluginEvents.ensureSchema()
        PluginEvents.syncAudit()
        PluginEvents.syncTriggers()
    end)
    if not ok then
        print("[ProjectMigrator] ERROR: event sources / audit trail: " .. tostring(err))
        table.insert(failed, "audit-trail")
    end

    if #failed > 0 then
        error("plugin migrations failed: " .. table.concat(failed, ", "), 0)
    end
    return total
end

--- Migration status of a plugin: executed / pending / drift (edited after
-- being applied).
function ProjectMigrator.status(project_code, project_path)
    ProjectMigrator.ensureTrackingTable()
    local executed = ProjectMigrator.getExecuted(project_code)
    local out = { executed = {}, pending = {}, drift = {} }
    local all = ProjectMigrator.discover(project_path .. "/migrations")
    for _, mig in ipairs(all) do
        local applied = executed[mig.name]
        if applied == nil then
            table.insert(out.pending, mig.name)
        else
            table.insert(out.executed, mig.name)
            if applied and applied ~= checksum(mig.path) then
                table.insert(out.drift, mig.name)
            end
        end
    end
    out.total = #all
    return out
end

return ProjectMigrator
