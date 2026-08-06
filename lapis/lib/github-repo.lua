--[[
    GitHub Repo Commit Helper (Git Data API)
    ========================================

    Commits a set of files to a repo/branch in ONE atomic commit using the Git
    Trees API. Because the new tree is created with `base_tree` = the current
    commit's tree, only the paths we pass are added/updated — every other file
    in the repo is preserved. We never send deletions, so this is strictly
    add/update-only (safe alongside hand-authored files).

    Auth: a GitHub token (PAT / fine-grained) passed in — this module never
    reads the DB. Reuse the services module's stored, encrypted integration
    token to obtain it.

    Usage:
      local GH = require("lib.github-repo")
      local sha, err = GH.commit_files({
        token = "...", owner = "bwalia", repo = "diy-tax-return-uk",
        branch = "main", message = "chore(domains): sync",
        files = { { path = ".github/.../host:x.json", content = "{...}" } },
      })
]]

local cjson = require("cjson")

local GithubRepo = {}

local API = "https://api.github.com"

local function http_client(timeout)
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(timeout or 20000)
    return httpc, nil
end

-- One GitHub API call. Returns decoded_body, status, err.
local function api(token, method, path, body)
    local httpc, herr = http_client()
    if not httpc then return nil, nil, herr end
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = "opsapi-domain-sync",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
    local payload
    if body ~= nil then
        headers["Content-Type"] = "application/json"
        payload = cjson.encode(body)
    end
    local res, rerr = httpc:request_uri(API .. path, {
        method = method, headers = headers, body = payload, ssl_verify = true,
    })
    if not res then return nil, nil, "request failed: " .. tostring(rerr) end
    local decoded
    if res.body and res.body ~= "" then
        local ok, d = pcall(cjson.decode, res.body)
        if ok then decoded = d end
    end
    if res.status >= 400 then
        local msg = "GitHub API " .. tostring(res.status)
        if decoded and decoded.message then msg = msg .. ": " .. decoded.message end
        return decoded, res.status, msg
    end
    return decoded, res.status, nil
end

--- Commit files atomically. add/update-only (base_tree preserves everything else).
-- @param opts { token, owner, repo, branch, message, files={{path,content}...}, author_name?, author_email? }
-- @return commit_sha, nil OR nil, err
function GithubRepo.commit_files(opts)
    assert(opts and opts.token and opts.owner and opts.repo, "token/owner/repo required")
    local branch = opts.branch or "main"
    local files = opts.files or {}
    if #files == 0 then return nil, "no files to commit" end

    local base = "/repos/" .. opts.owner .. "/" .. opts.repo

    -- 1. Current branch ref → base commit sha
    local ref, _, err = api(opts.token, "GET", base .. "/git/ref/heads/" .. branch)
    if err then return nil, "get ref: " .. err end
    local base_commit_sha = ref and ref.object and ref.object.sha
    if not base_commit_sha then return nil, "could not resolve branch head sha" end

    -- 2. Base commit → base tree sha
    local commit, _, cerr = api(opts.token, "GET", base .. "/git/commits/" .. base_commit_sha)
    if cerr then return nil, "get base commit: " .. cerr end
    local base_tree_sha = commit and commit.tree and commit.tree.sha
    if not base_tree_sha then return nil, "could not resolve base tree sha" end

    -- 3. One blob per file
    local tree_entries = {}
    for _, f in ipairs(files) do
        local blob, _, berr = api(opts.token, "POST", base .. "/git/blobs", {
            content = ngx.encode_base64(f.content),
            encoding = "base64",
        })
        if berr then return nil, "create blob (" .. tostring(f.path) .. "): " .. berr end
        if not (blob and blob.sha) then return nil, "create blob (" .. tostring(f.path) .. "): no sha returned" end
        table.insert(tree_entries, {
            path = f.path, mode = "100644", type = "blob", sha = blob.sha,
        })
    end

    -- 4. New tree on top of the base tree (only our paths change)
    local tree, _, terr = api(opts.token, "POST", base .. "/git/trees", {
        base_tree = base_tree_sha,
        tree = tree_entries,
    })
    if terr then return nil, "create tree: " .. terr end
    if not (tree and tree.sha) then return nil, "create tree: no sha returned" end

    -- 5. New commit
    local body = {
        message = opts.message or "chore(domains): sync from opsapi",
        tree = tree.sha,
        parents = { base_commit_sha },
    }
    if opts.author_name and opts.author_email then
        body.author = { name = opts.author_name, email = opts.author_email, date = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    end
    local newcommit, _, ncerr = api(opts.token, "POST", base .. "/git/commits", body)
    if ncerr then return nil, "create commit: " .. ncerr end
    if not (newcommit and newcommit.sha) then return nil, "create commit: no sha returned" end

    -- 6. Fast-forward the branch ref
    local _, _, uerr = api(opts.token, "PATCH", base .. "/git/refs/heads/" .. branch, {
        sha = newcommit.sha, force = false,
    })
    if uerr then return nil, "update ref: " .. uerr end

    return newcommit.sha, nil
end

--- Dispatch a workflow_dispatch event (thin wrapper; the services module has a
--- fuller one, but the pipeline reuses this for a uniform token path).
-- @param opts { token, owner, repo, workflow (file name or id), ref?, inputs? }
function GithubRepo.dispatch_workflow(opts)
    assert(opts and opts.token and opts.owner and opts.repo and opts.workflow, "token/owner/repo/workflow required")
    local path = string.format("/repos/%s/%s/actions/workflows/%s/dispatches",
        opts.owner, opts.repo, opts.workflow)
    local _, status, err = api(opts.token, "POST", path, {
        ref = opts.ref or "main",
        inputs = opts.inputs or nil,
    })
    if err then return nil, err end
    return status == 204 or status == 200, nil
end

--- Find the workflow run created by a dispatch. workflow_dispatch returns no run
--- id, so we poll the workflow's runs and pick the newest created at/after
--- `since_iso` (an ISO-8601 UTC string captured just before dispatch). Retries a
--- few times because the run can take a few seconds to appear.
-- @param opts { token, owner, repo, workflow, ref? }
-- @param since_iso string e.g. "2026-08-06T09:00:00Z"
-- @return run_table, nil OR nil, err   (run_table has id, status, conclusion, html_url, created_at)
function GithubRepo.find_run_after(opts, since_iso)
    local path = string.format("/repos/%s/%s/actions/workflows/%s/runs?event=workflow_dispatch&per_page=15",
        opts.owner, opts.repo, opts.workflow)
    if opts.ref then path = path .. "&branch=" .. opts.ref end

    for attempt = 1, 8 do
        local body, _, err = api(opts.token, "GET", path)
        if not err and body and type(body.workflow_runs) == "table" then
            local newest
            for _, run in ipairs(body.workflow_runs) do
                if run.created_at and run.created_at >= since_iso then
                    if not newest or run.created_at > newest.created_at then newest = run end
                end
            end
            if newest then return newest, nil end
        end
        if ngx and ngx.sleep then ngx.sleep(3) end
        if attempt == 8 then
            return nil, "run did not appear after dispatch (timed out finding run)"
        end
    end
    return nil, "run not found"
end

--- Get a single workflow run's current state.
function GithubRepo.get_run(opts, run_id)
    local body, _, err = api(opts.token, "GET",
        string.format("/repos/%s/%s/actions/runs/%s", opts.owner, opts.repo, run_id))
    if err then return nil, err end
    return body, nil
end

--- Poll a run until it completes (status == "completed") or times out.
-- @param opts { token, owner, repo }
-- @param run_id number
-- @param timeout_s number total seconds to wait (default 900)
-- @param interval_s number poll interval (default 15)
-- @return run_table (completed), nil  OR  nil, err (timeout/error). Caller checks .conclusion.
function GithubRepo.wait_for_run(opts, run_id, timeout_s, interval_s)
    timeout_s = timeout_s or 900
    interval_s = interval_s or 15
    local waited = 0
    while waited <= timeout_s do
        local run, err = GithubRepo.get_run(opts, run_id)
        if err then return nil, err end
        if run and run.status == "completed" then
            return run, nil
        end
        if ngx and ngx.sleep then ngx.sleep(interval_s) end
        waited = waited + interval_s
    end
    return nil, "timed out waiting for run " .. tostring(run_id) .. " to complete"
end

return GithubRepo
