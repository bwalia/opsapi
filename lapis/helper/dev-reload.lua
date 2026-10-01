--[[
    Dev hot reload — OPSAPI_DEV_RELOAD=true (local development only)
    ================================================================

    Save a .lua file (core or plugin) and the running server picks it up in
    about two seconds, no container restart:

      * nginx's privileged agent (a helper process that serves no requests
        and, unlike the workers, may signal the master) looks for changed .lua
        files under the app and plugins directories every second, and waits
        for a quiet second so a multi-file save reloads once;
      * every changed file must compile — on a syntax error the error is
        logged and the old code keeps serving;
      * a changed plugin manifest or events/*.lua re-syncs that plugin's RBAC
        modules, sidebar menu and event subscriptions;
      * then nginx reloads gracefully (HUP): new workers start with the new
        code while the old ones finish their requests.

    Migrations never run by themselves (a half-written file would be marked as
    applied): a changed migration is logged with a reminder to run
    `opsapi migrate`. Static plugin UI files (ui/) need no reload at all.
    Deleting a file isn't noticed: run `opsapi reload` (or save any file).

    ./start.sh -e local turns this on; it's off everywhere else.
]]

local DevReload = {}

local INTERVAL = 1
-- Files saved on the host can show up in the container a moment late (Docker
-- Desktop file sharing), with their original mtime: look back this far and
-- compare each file's mtime with the last one seen.
local LOOKBACK = 30
local PREFIX = "[dev-reload] "

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run(cmd)
    local h = io.popen(cmd .. " 2>/dev/null")
    if not h then return {} end
    local out = {}
    for line in h:lines() do out[#out + 1] = line end
    h:close()
    return out
end

local function log(level, ...)
    ngx.log(level, PREFIX, ...)
end

-- Directories to watch: the app (core code, and plugins when they live under
-- it) plus the plugins directory if it's elsewhere.
local function roots(app_dir, projects_dir)
    local list = { app_dir }
    if projects_dir:sub(1, #app_dir + 1) ~= app_dir .. "/" then list[#list + 1] = projects_dir end
    return list
end

--- Returns scan(): the .lua files whose mtime changed since the last scan.
-- Files already there when watching starts are the baseline (so a reload
-- doesn't trigger another one).
local function scanner(watch, stamp)
    local quoted = {}
    for i, r in ipairs(watch) do quoted[i] = shell_quote(r) end
    local find = "find " .. table.concat(quoted, " ")
        .. " \\( -name node_modules -o -name logs -o -name '.*' \\) -prune -o -type f -name '*.lua' -newer "
        .. shell_quote(stamp) .. " -exec stat -c '%y|%n' {} +"
    local function recent()
        os.execute("touch -d @" .. (os.time() - LOOKBACK) .. " " .. shell_quote(stamp))
        local out = {}
        for _, line in ipairs(run(find)) do
            local mtime, path = line:match("^(.-)|(.+)$")
            if path then out[path] = mtime end
        end
        return out
    end
    local seen = recent()
    return function()
        local changed = {}
        for path, mtime in pairs(recent()) do
            if seen[path] ~= mtime then
                seen[path] = mtime
                changed[#changed + 1] = path
            end
        end
        return changed
    end
end

--- Plugin directory a file belongs to, if any.
local function plugin_of(path, projects_dir)
    return path:match("^(" .. projects_dir:gsub("%p", "%%%0") .. "/[^/]+)/")
end

local function sync_plugins(dirs)
    for dir in pairs(dirs) do
        local ok, err = pcall(function()
            require("helper.project-migrator").syncManifest(dir)
        end)
        if ok then
            log(ngx.NOTICE, "re-synced ", dir, " (modules, menu, events)")
        else
            log(ngx.ERR, "could not sync ", dir, ": ", tostring(err))
        end
    end
    -- Timers don't run lapis' after-dispatch hook: give the connection back.
    pcall(require("lapis.nginx.context").run_after_dispatch)
end

local function reload()
    local ok_p, process = pcall(require, "ngx.process")
    local pid = ok_p and process.get_master_pid and process.get_master_pid()
    if not pid then
        log(ngx.ERR, "no nginx master process; restart the container to load the change")
        return
    end
    os.execute("kill -HUP " .. tonumber(pid))
end

--- Start watching. Runs in the privileged agent (nginx.conf enables it when
-- OPSAPI_DEV_RELOAD=true): workers run as an unprivileged user and can't
-- signal the master.
function DevReload.start(app_dir, projects_dir)
    app_dir = (app_dir or ngx.config.prefix()):gsub("/+$", "")
    projects_dir = (projects_dir or (app_dir .. "/projects")):gsub("/+$", "")
    local scan = scanner(roots(app_dir, projects_dir), "/tmp/opsapi-dev-reload.stamp")
    local pending, busy = {}, false

    local function tick(premature)
        if premature or busy then return end
        busy = true
        local ok, err = pcall(function()
            local changed = scan()
            for _, path in ipairs(changed) do pending[path] = true end
            if #changed > 0 or next(pending) == nil then return end -- wait for a quiet second

            local files, broken, plugins, migrations = {}, {}, {}, {}
            for path in pairs(pending) do files[#files + 1] = path end
            pending = {}
            table.sort(files)
            for _, path in ipairs(files) do
                local chunk, syntax_err = loadfile(path)
                if not chunk then broken[#broken + 1] = syntax_err end
                local plugin = plugin_of(path, projects_dir)
                if plugin and (path:match("/project%.lua$") or path:match("/events/[^/]+%.lua$")) then
                    plugins[plugin] = true
                end
                if path:match("/migrations/[^/]+%.lua$") or path:match("/migrations%.lua$") then
                    migrations[#migrations + 1] = path
                end
            end
            if #broken > 0 then
                log(ngx.ERR, "not reloading — fix this first:\n  ", table.concat(broken, "\n  "))
                return
            end
            for _, path in ipairs(migrations) do
                log(ngx.WARN, path, " changed — run `opsapi migrate` to apply new migrations")
            end
            sync_plugins(plugins)
            log(ngx.NOTICE, "reloading for ", #files, " changed file(s): ", table.concat(files, ", "))
            reload()
        end)
        busy = false
        if not ok then log(ngx.ERR, "watch failed: ", tostring(err)) end
    end

    log(ngx.WARN, "watching ", app_dir, " and ", projects_dir,
        " — saved .lua files reload the server (local development only)")
    ngx.timer.every(INTERVAL, tick)
end

DevReload._scanner = scanner -- for spec/dev-reload_spec.lua

return DevReload
