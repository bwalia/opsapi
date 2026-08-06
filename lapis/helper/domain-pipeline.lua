--[[
    Domain Pipeline Orchestrator
    ============================

    opsapi-driven chain (decision: "opsapi drives each step"):
      1. sync    — render domains → WSL Proxy vhost files, commit to the repo
      2. cloudflare-dns-reconcile   (dispatch → wait for completion)
      3. wslproxy-register-domains  (dispatch → wait)
      4. auto-tag-main              (dispatch → wait)

    Each step gates the next; a failure stops the pipeline. Runs in an ngx.timer
    so the HTTP request returns immediately; progress is written to
    domain_pipeline_runs for the dashboard to poll. See routes/domains.lua.

    The GitHub token comes from the namespace's services GitHub integration
    (encrypted at rest). All GitHub calls go through lib/github-repo.lua.
]]

local DomainPipelineRunQueries = require("queries.DomainPipelineRunQueries")

local DomainPipeline = {}

-- Default workflow chain: sync → Cloudflare DNS reconcile → WSL Proxy register.
-- (auto-tag is intentionally NOT part of this pipeline — domain syncs must not
-- tag/build images. auto-tag still runs for human merges to main.)
-- Callers may override via opts.steps, but this is the canonical order.
function DomainPipeline.default_steps(env)
    return {
        { name = "sync",                     type = "sync",     status = "pending" },
        { name = "cloudflare-dns-reconcile", type = "workflow", workflow = "cloudflare-dns-reconcile.yml",
          inputs = { ENV = env, DRY_RUN = "false", SOURCE = "opsapi" }, status = "pending" },
        { name = "wslproxy-register-domains", type = "workflow", workflow = "wslproxy-register-domains.yml",
          inputs = { TARGET_ENV = env, ACTIVATE_CONFIG = "false" }, status = "pending" },
    }
end

-- Resolve + decrypt the GitHub token for a run's integration.
local function resolve_token(run)
    local ok, ServiceQueries = pcall(require, "queries.ServiceQueries")
    if not ok then return nil, "services module unavailable" end
    local integration = ServiceQueries.getGithubIntegration(run.github_integration_id, true)
    if not integration then return nil, "GitHub integration not found" end
    if tonumber(integration.namespace_id) ~= tonumber(run.namespace_id) then
        return nil, "Integration belongs to another namespace"
    end
    local token = integration.github_token_decrypted
    if not token or token == "" then return nil, "Could not decrypt integration token" end
    return token, nil
end

-- Render + commit the WSL Proxy vhost files for the run's env. Returns commit sha.
local function do_sync(run, token)
    local DomainQueries = require("queries.DomainQueries")
    local WslproxyServer = require("helper.wslproxy-server")
    local GithubRepo = require("lib.github-repo")

    local rows = DomainQueries.getAllForNamespace(run.namespace_id)
    local built = WslproxyServer.build_sync_files(rows, run.environment)
    if built.count == 0 then return nil, "no domains for environment " .. tostring(run.environment) end

    return GithubRepo.commit_files({
        token = token, owner = run.owner, repo = run.repo, branch = run.branch,
        message = "chore(domains): sync " .. built.count .. " " .. run.environment .. " domains from opsapi",
        files = built.files, author_name = "opsapi-domain-sync", author_email = "domain-sync@opsapi",
    })
end

-- Persist the steps array + top-level fields for a run.
local function save(run_uuid, steps, patch)
    patch = patch or {}
    patch.steps = steps
    DomainPipelineRunQueries.update(run_uuid, patch)
end

--- The background worker. `premature` is the ngx.timer flag.
function DomainPipeline.execute(premature, run_uuid)
    if premature then return end

    local run = DomainPipelineRunQueries.get(run_uuid)
    if not run then return end
    local steps = run.steps or {}

    DomainPipelineRunQueries.update(run_uuid, { status = "running", started_at = require("lapis.db").raw("NOW()") })

    local token, terr = resolve_token(run)
    if not token then
        save(run_uuid, steps, { status = "failed", error = terr, finished_at = require("lapis.db").raw("NOW()") })
        return
    end

    local GithubRepo = require("lib.github-repo")

    for i, step in ipairs(steps) do
        step.status = "running"
        step.started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        save(run_uuid, steps, { current_step = i })

        local ok, err = pcall(function()
            if step.type == "sync" then
                local sha, serr = do_sync(run, token)
                if not sha then error(serr or "sync failed") end
                step.commit = sha
                DomainPipelineRunQueries.update(run_uuid, { commit_sha = sha })
            else
                -- Capture the dispatch moment (with buffer) to locate the run.
                local since = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 10)
                local wf_opts = { token = token, owner = run.owner, repo = run.repo,
                                  workflow = step.workflow, ref = run.branch }
                local dok, derr = GithubRepo.dispatch_workflow({
                    token = token, owner = run.owner, repo = run.repo,
                    workflow = step.workflow, ref = run.branch, inputs = step.inputs,
                })
                if not dok then error("dispatch failed: " .. tostring(derr)) end

                local found, ferr = GithubRepo.find_run_after(wf_opts, since)
                if not found then error(ferr or "run not found") end
                step.run_id = found.id
                step.run_url = found.html_url
                save(run_uuid, steps, {})

                local done, werr = GithubRepo.wait_for_run(wf_opts, found.id, 1200, 15)
                if not done then error(werr or "wait failed") end
                step.conclusion = done.conclusion
                if done.conclusion ~= "success" then
                    error("workflow concluded '" .. tostring(done.conclusion) .. "'")
                end
            end
        end)

        step.finished_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        if not ok then
            step.status = "failed"
            step.error = tostring(err)
            save(run_uuid, steps, { status = "failed", error = step.name .. ": " .. tostring(err),
                                    finished_at = require("lapis.db").raw("NOW()") })
            return
        end
        step.status = "success"
        save(run_uuid, steps, {})
    end

    save(run_uuid, steps, { status = "success", finished_at = require("lapis.db").raw("NOW()") })
end

--- Create a run record and kick off the background orchestration.
-- @param cfg { namespace_id, environment, owner, repo, branch, github_integration_id, triggered_by_uuid, steps? }
-- @return run_row, nil OR nil, err
function DomainPipeline.start(cfg)
    if not cfg.owner or not cfg.repo then return nil, "owner and repo are required" end
    if not cfg.github_integration_id then return nil, "github_integration_id is required" end

    local env = cfg.environment or "prod"
    local steps = cfg.steps or DomainPipeline.default_steps(env)

    local run = DomainPipelineRunQueries.create({
        namespace_id = cfg.namespace_id,
        status = "pending",
        environment = env,
        owner = cfg.owner,
        repo = cfg.repo,
        branch = cfg.branch or "main",
        github_integration_id = tostring(cfg.github_integration_id),
        triggered_by_uuid = cfg.triggered_by_uuid,
        steps = steps,
    })
    if not run then return nil, "failed to create pipeline run" end

    local ok, err = ngx.timer.at(0, DomainPipeline.execute, run.uuid)
    if not ok then
        DomainPipelineRunQueries.update(run.uuid, { status = "failed", error = "could not schedule: " .. tostring(err) })
        return nil, "could not schedule pipeline: " .. tostring(err)
    end

    return run, nil
end

return DomainPipeline
