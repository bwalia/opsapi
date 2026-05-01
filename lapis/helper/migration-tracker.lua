--[[
    Migration Tracker (helper/migration-tracker.lua)

    Stateful singleton that accumulates migration events during a run.
    Provides skip logging, dry-run support, and a summary report.

    Usage:
        local MigrationTracker = require "helper.migration-tracker"
        MigrationTracker.init("tax_copilot", {"core", "tax_copilot", "notifications", "menu"})

        -- In skip_migration / conditional / conditional_array:
        MigrationTracker.recordSkipped("11_create_products", "ecommerce")
        MigrationTracker.recordRan("01_create_users", "core")

        -- At end of migration run:
        MigrationTracker.printSummary()

    Dry-run mode:
        Set MIGRATION_DRY_RUN=1 env var to preview migrations without executing.
]]

local MigrationTracker = {}

-- Internal state (module-level singleton)
local _stats = {
    ran = {},
    skipped = {},
    dry_run = false,
    project_code = "all",
    project_codes = {},
    enabled_features = {},
}

--- Initialize the tracker. Call once at the top of migrations.lua.
-- @param project_code string The raw PROJECT_CODE value
-- @param enabled_features table Array of enabled feature names
function MigrationTracker.init(project_code, enabled_features)
    _stats.project_code = project_code or "all"
    _stats.enabled_features = enabled_features or {}
    _stats.dry_run = os.getenv("MIGRATION_DRY_RUN") == "1"
    _stats.ran = {}
    _stats.skipped = {}
end

--- Check if dry-run mode is active.
-- @return boolean
function MigrationTracker.isDryRun()
    return _stats.dry_run
end

--- Get the current project code.
-- @return string
function MigrationTracker.getProjectCode()
    return _stats.project_code
end

--- Record a migration that was executed (or would be in dry-run).
-- @param name string Migration identifier
-- @param feature string Feature that owns this migration (e.g. "core", "ecommerce")
function MigrationTracker.recordRan(name, feature)
    table.insert(_stats.ran, { name = name, feature = feature or "core" })
end

--- Record a migration that was skipped due to disabled feature.
-- Logs immediately to stdout and accumulates for the summary.
-- @param name string Migration identifier
-- @param feature string The disabled feature that caused the skip
function MigrationTracker.recordSkipped(name, feature)
    local feat = feature or "unknown"
    print("[Migration] SKIP " .. name .. " -- feature '" .. feat .. "' not enabled for PROJECT_CODE=" .. _stats.project_code)
    table.insert(_stats.skipped, { name = name, feature = feat })
end

--- Print a grouped summary of the migration run.
function MigrationTracker.printSummary()
    print("")
    print("============================================================")
    print("  MIGRATION SUMMARY")
    print("============================================================")
    print("  Project Code:     " .. _stats.project_code)
    print("  Enabled Features: " .. table.concat(_stats.enabled_features, ", "))

    if _stats.dry_run then
        print("  Mode:             DRY-RUN (no database changes applied)")
    end

    print("------------------------------------------------------------")
    print("  Migrations executed: " .. #_stats.ran)
    print("  Migrations skipped:  " .. #_stats.skipped)
    print("------------------------------------------------------------")

    -- Group skipped by feature
    if #_stats.skipped > 0 then
        local skip_by_feature = {}
        local feature_order = {}
        for _, s in ipairs(_stats.skipped) do
            if not skip_by_feature[s.feature] then
                skip_by_feature[s.feature] = 0
                table.insert(feature_order, s.feature)
            end
            skip_by_feature[s.feature] = skip_by_feature[s.feature] + 1
        end

        print("  Skipped by disabled feature:")
        for _, feature in ipairs(feature_order) do
            print("    " .. feature .. ": " .. skip_by_feature[feature] .. " migration(s)")
        end
    end

    -- Group ran by feature
    if #_stats.ran > 0 then
        local ran_by_feature = {}
        local feature_order = {}
        for _, r in ipairs(_stats.ran) do
            if not ran_by_feature[r.feature] then
                ran_by_feature[r.feature] = 0
                table.insert(feature_order, r.feature)
            end
            ran_by_feature[r.feature] = ran_by_feature[r.feature] + 1
        end

        print("  Executed by feature:")
        for _, feature in ipairs(feature_order) do
            print("    " .. feature .. ": " .. ran_by_feature[feature] .. " migration(s)")
        end
    end

    print("============================================================")
    print("")
end

--- Get raw stats (useful for testing).
-- @return table The internal stats
function MigrationTracker.getStats()
    return {
        ran = _stats.ran,
        skipped = _stats.skipped,
        dry_run = _stats.dry_run,
        project_code = _stats.project_code,
        enabled_features = _stats.enabled_features,
    }
end

--- Reset tracker state (useful for testing).
function MigrationTracker.reset()
    _stats.ran = {}
    _stats.skipped = {}
    _stats.dry_run = false
    _stats.project_code = "all"
    _stats.project_codes = {}
    _stats.enabled_features = {}
end

return MigrationTracker
