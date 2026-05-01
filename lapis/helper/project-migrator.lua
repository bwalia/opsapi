--[[
  Project Migration Runner

  Runs migrations for projects discovered under /projects/.
  Each project has its own /migrations/ directory with numbered migration files.
  Migration state is tracked in the `project_migrations` table, scoped by project_code.

  Migration file format:
    -- /projects/{code}/migrations/001_create_foo.lua
    return function(schema, db)
      schema.create_table("prefix_foo", { ... })
    end

  Usage:
    local ProjectMigrator = require("helper.project-migrator")
    ProjectMigrator.migrateAll("/app/projects")
    -- or for a single project:
    ProjectMigrator.migrate("hospital_patient_manager", "/app/projects/hospital-patient-manager")
]]

local schema = require("lapis.db.schema")
local db = require("lapis.db")

local ProjectMigrator = {}

-- ---------------------------------------------------------------------------
-- Tracking table management
-- ---------------------------------------------------------------------------

--- Ensure the project_migrations tracking table exists
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

-- ---------------------------------------------------------------------------
-- Query executed migrations
-- ---------------------------------------------------------------------------

--- Get set of migration names that have already been executed for a project
-- @param project_code string
-- @return table Set of migration names (name -> true)
function ProjectMigrator.getExecuted(project_code)
    local rows = db.select("migration_name FROM project_migrations WHERE project_code = ? ORDER BY migration_name", project_code)
    local executed = {}
    for _, row in ipairs(rows) do
        executed[row.migration_name] = true
    end
    return executed
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

--- Discover migration files in a project's /migrations/ directory
-- @param migrations_dir string Absolute path to project's migrations directory
-- @return table Ordered list of { name, path }
function ProjectMigrator.discover(migrations_dir)
    local files = {}

    local ok_lfs, lfs = pcall(require, "lfs")
    if ok_lfs then
        local attr = lfs.attributes(migrations_dir)
        if not attr or attr.mode ~= "directory" then
            return files
        end
        for entry in lfs.dir(migrations_dir) do
            if entry:match("%.lua$") then
                local name = entry:gsub("%.lua$", "")
                table.insert(files, {
                    name = name,
                    path = migrations_dir .. "/" .. entry,
                })
            end
        end
    else
        local handle = io.popen("ls " .. migrations_dir .. "/*.lua 2>/dev/null")
        if handle then
            for line in handle:lines() do
                local filename = line:match("([^/]+)$")
                if filename then
                    local name = filename:gsub("%.lua$", "")
                    table.insert(files, {
                        name = name,
                        path = line,
                    })
                end
            end
            handle:close()
        end
    end

    -- Sort by filename (001_xxx < 002_xxx)
    table.sort(files, function(a, b) return a.name < b.name end)

    return files
end

-- ---------------------------------------------------------------------------
-- Record migration execution
-- ---------------------------------------------------------------------------

--- Record that a migration was executed
-- @param project_code string
-- @param migration_name string
-- @param checksum string|nil Optional SHA256 of migration file
function ProjectMigrator.recordExecution(project_code, migration_name, checksum)
    db.insert("project_migrations", {
        project_code = project_code,
        migration_name = migration_name,
        checksum = checksum or db.NULL,
    })
end

-- ---------------------------------------------------------------------------
-- Run migrations
-- ---------------------------------------------------------------------------

--- Run pending migrations for a single project
-- @param project_code string Machine name of the project
-- @param project_path string Absolute path to project directory
-- @return number Number of migrations executed
function ProjectMigrator.migrate(project_code, project_path)
    local migrations_dir = project_path .. "/migrations"
    local migration_files = ProjectMigrator.discover(migrations_dir)

    if #migration_files == 0 then
        print("[ProjectMigrator] " .. project_code .. ": No migrations found")
        return 0
    end

    local executed = ProjectMigrator.getExecuted(project_code)
    local count = 0

    for _, mig in ipairs(migration_files) do
        if not executed[mig.name] then
            print("[ProjectMigrator] " .. project_code .. ": Running " .. mig.name .. "...")

            -- Load migration file
            local chunk, load_err = loadfile(mig.path)
            if not chunk then
                print("[ProjectMigrator] ERROR: Failed to load " .. mig.path .. ": " .. tostring(load_err))
                error("Migration " .. project_code .. "/" .. mig.name .. " failed to load: " .. tostring(load_err))
            end

            local ok_exec, migration_fn = pcall(chunk)
            if not ok_exec then
                print("[ProjectMigrator] ERROR: Failed to execute " .. mig.path .. ": " .. tostring(migration_fn))
                error("Migration " .. project_code .. "/" .. mig.name .. " failed to execute: " .. tostring(migration_fn))
            end

            if type(migration_fn) ~= "function" then
                print("[ProjectMigrator] WARNING: " .. mig.path .. " did not return a function, skipping")
            else
                -- Run the migration
                local ok_run, run_err = pcall(migration_fn, schema, db)
                if not ok_run then
                    print("[ProjectMigrator] ERROR: Migration " .. project_code .. "/" .. mig.name .. " failed: " .. tostring(run_err))
                    error("Migration " .. project_code .. "/" .. mig.name .. " failed: " .. tostring(run_err))
                end

                -- Record execution
                ProjectMigrator.recordExecution(project_code, mig.name)
                count = count + 1
                print("[ProjectMigrator] " .. project_code .. ": Completed " .. mig.name)
            end
        end
    end

    if count == 0 then
        print("[ProjectMigrator] " .. project_code .. ": All migrations already applied")
    else
        print("[ProjectMigrator] " .. project_code .. ": " .. count .. " migration(s) applied")
    end

    return count
end

--- Run migrations for all discovered projects
-- @param projects_root string Absolute path to /projects/ directory
-- @return number Total migrations executed across all projects
function ProjectMigrator.migrateAll(projects_root)
    print("=== Project Migrator: Running migrations for all projects ===")

    -- Ensure tracking table exists
    ProjectMigrator.ensureTrackingTable()

    -- Discover projects
    local ok_loader, ProjectLoader = pcall(require, "helper.project-loader")
    if not ok_loader then
        print("[ProjectMigrator] WARNING: project-loader not available: " .. tostring(ProjectLoader))
        return 0
    end

    local discovered = ProjectLoader.discover(projects_root)
    local total = 0

    for _, entry in ipairs(discovered) do
        local manifest, err = ProjectLoader.loadManifest(entry.manifest_path, entry.path)
        if manifest and manifest.enabled then
            local ok, count_or_err = pcall(ProjectMigrator.migrate, manifest.code, manifest.path)
            if ok then
                total = total + count_or_err
            else
                print("[ProjectMigrator] ERROR: Failed migrations for " .. manifest.code .. ": " .. tostring(count_or_err))
            end
        elseif err then
            print("[ProjectMigrator] WARNING: Skipping " .. entry.dir_name .. ": " .. tostring(err))
        end
    end

    print("=== Project Migrator: " .. total .. " total migration(s) applied ===")
    return total
end

--- Get migration status for a project (useful for CLI/API)
-- @param project_code string
-- @param project_path string
-- @return table { executed = {...}, pending = {...}, total = N }
function ProjectMigrator.status(project_code, project_path)
    ProjectMigrator.ensureTrackingTable()

    local migrations_dir = project_path .. "/migrations"
    local all_migrations = ProjectMigrator.discover(migrations_dir)
    local executed = ProjectMigrator.getExecuted(project_code)

    local pending = {}
    local executed_list = {}

    for _, mig in ipairs(all_migrations) do
        if executed[mig.name] then
            table.insert(executed_list, mig.name)
        else
            table.insert(pending, mig.name)
        end
    end

    return {
        executed = executed_list,
        pending = pending,
        total = #all_migrations,
    }
end

return ProjectMigrator
