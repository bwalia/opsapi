-- Fetch GitHub credentials from a project's HashiCorp/WSL Vault URL and open a PR
-- in the project's target_repo (never the OpsAPI repo). Vault access token is sealed
-- on ar_project_settings (secret-box purpose ai_runner_vault).
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(true)
local db = require("lapis.db")
local U = require("ai_runner.util")
local G = require("ai_runner.github")
local C = require("ai_runner.context")

local V = {}
V.PURPOSE = "ai_runner_vault"
V.TIMEOUT_MS = 15000

local VAULT_HTTP_OPTS = {
    allow_private = os.getenv("OPSAPI_VAULT_ALLOW_PRIVATE") == "true",
    allow_http = os.getenv("OPSAPI_VAULT_ALLOW_PRIVATE") == "true",
    timeout_ms = V.TIMEOUT_MS,
}

--- owner/repo from a git/https GitHub URL.
function V.parse_repo(url)
    if type(url) ~= "string" or url == "" then return nil end
    local s = url:gsub("%.git$", ""):gsub("%s+", "")
    local owner, repo = s:match("github%.com[:/]+([^/]+)/([^/]+)$")
    if not owner then owner, repo = s:match("^([^/]+)/([^/]+)$") end
    if owner and repo and owner ~= "" and repo ~= "" then return owner .. "/" .. repo end
end

--- Open the sealed vault token from project settings.
function V.vault_token(ps)
    if type(ps.vault_token_sealed) ~= "string" or ps.vault_token_sealed == "" then
        return nil, "this project has no vault token saved"
    end
    local plain, err = require("helper.secret-box").open(ps.vault_token_sealed, V.PURPOSE)
    if not plain then return nil, err or "vault token could not be opened" end
    return plain
end

--- Read the GitHub PAT (or token) from Vault KV v2 at the project's secret path.
-- Expected data: { github_token | token | value | pat }.
function V.fetch_github_token(ps)
    local token, terr = V.vault_token(ps)
    if not token then return nil, terr end
    local base = type(ps.vault_url) == "string" and ps.vault_url:gsub("/+$", "") or ""
    local path = type(ps.vault_secret_path) == "string" and ps.vault_secret_path:gsub("^/+", ""):gsub("/+$", "") or ""
    if base == "" or path == "" then return nil, "project vault_url and vault_secret_path are required" end
    local mount = type(ps.vault_mount_path) == "string" and ps.vault_mount_path ~= "" and ps.vault_mount_path
        or "secret"
    local url = base .. "/v1/" .. mount .. "/data/" .. path
    local res, err = require("lib.outbound-webhooks").request(url, {
        method = "GET",
        headers = { ["X-Vault-Token"] = token, ["Accept"] = "application/json" },
    }, VAULT_HTTP_OPTS)
    if not res then return nil, "Vault unreachable: " .. tostring(err) end
    if res.status >= 400 then
        return nil, "Vault answered " .. tostring(res.status)
    end
    local data = cjson.decode(res.body or "") or {}
    local secret = type(data.data) == "table" and (data.data.data or data.data) or data
    if type(secret) ~= "table" then return nil, "Vault secret is empty" end
    local gh = secret.github_token or secret.token or secret.pat or secret.value or secret.GITHUB_TOKEN
    if type(gh) ~= "string" or gh == "" then
        return nil, "Vault secret has no github_token / token / pat field"
    end
    return gh
end

--- A Repo client authenticated with an explicit PAT for owner/repo.
function V.repo_with_token(full_name, token, api_url, web_url)
    local c = { api_url = G.base_url(api_url) or G.API_URL, web_url = G.base_url(web_url) or G.WEB_URL }
    local Repo = {}
    Repo.__index = Repo
    function Repo:call(method, path, body)
        return G.request(method, c.api_url .. "/repos/" .. full_name .. path,
            { Authorization = "Bearer " .. token }, body)
    end
    function Repo:pull_request(head, base, title, body, draft)
        local data, status, err = self:call("POST", "/pulls", {
            title = title, head = head, base = base, body = body, draft = draft == true,
        })
        if data and type(data.html_url) == "string" then
            return data.html_url, data.number
        end
        if status == 422 then
            local owner = full_name:match("^([^/]+)/")
            local list = self:call("GET", "/pulls?state=open&head=" .. ngx.escape_uri(owner .. ":" .. head))
            if type(list) == "table" and type(list[1]) == "table" then
                return list[1].html_url, list[1].number
            end
        end
        return nil, nil, err
    end
    return setmetatable({ full_name = full_name, token = token, c = c }, Repo)
end

--- Attach a PR row to the task (idempotent per run).
function V.attach(ns, task, run, pr_url, pr_number, repo)
    if type(pr_url) ~= "string" or pr_url == "" then return nil, "no pr_url" end
    local row = U.one([[
        INSERT INTO ar_task_prs (namespace_id, task_uuid, project_uuid, run_uuid, repo, pr_url, pr_number, state)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'open')
        ON CONFLICT (namespace_id, run_uuid) DO UPDATE SET
            pr_url = EXCLUDED.pr_url, pr_number = COALESCE(EXCLUDED.pr_number, ar_task_prs.pr_number),
            repo = EXCLUDED.repo, state = 'open', updated_at = NOW()
        RETURNING *
    ]], ns, task.uuid, task.project_uuid or run.project_uuid, run.uuid, repo or "", pr_url,
        pr_number or db.NULL)
    return row
end

--- Open a PR in the project's target repo using Vault credentials, then attach + notify.
-- Falls back to attaching an already-reported pr_url without opening a new one.
function V.open_or_attach(run, opts)
    opts = opts or {}
    local R = require("ai_runner.runs")
    local ns = run.namespace_id
    local task = R.task(ns, run.task_uuid)
    if not task then return nil, "task not found" end
    local ps = R.project_settings(ns, task.project_uuid)
    local repo = V.parse_repo(ps.target_repo_url)
        or V.parse_repo(run.repo_remote)
        or V.parse_repo(opts.repo)
    local pr_url, pr_number = opts.pr_url, opts.pr_number

    if not pr_url and run.output_mode == "pull_request" and repo and ps.vault_configured then
        local token, err = V.fetch_github_token(ps)
        if not token then
            ngx.log(ngx.WARN, "[ai_runner] vault github token: ", tostring(err))
            return nil, err
        end
        local client = V.repo_with_token(repo, token)
        local head = run.work_branch
        local base = run.pr_base or run.base_branch or ps.base_branch or "main"
        if type(base) ~= "string" or base == "" or base == cjson.null then base = "main" end
        local title = "#" .. tostring(task.task_number or "") .. " " .. tostring(task.title or "AI run")
        local body = table.concat({
            "AI run for task " .. R.task_url(task.project_uuid, task.uuid),
            "",
            run.summary and ("Summary:\n" .. tostring(run.summary)) or "",
            "",
            "Run: /dashboard/ai-runner/runs/" .. run.uuid,
        }, "\n")
        local url, num, perr = client:pull_request(head, base, title, body, run.pr_draft ~= false)
        if not url then return nil, perr or "could not open pull request" end
        pr_url, pr_number = url, num
        db.query("UPDATE ar_runs SET pr_url = ?, updated_at = NOW() WHERE id = ?", pr_url, run.id)
        run.pr_url = pr_url
    end

    if not pr_url and type(run.pr_url) == "string" and run.pr_url ~= "" then
        pr_url = run.pr_url
    end
    if not pr_url then return nil, "no pull request URL" end

    local row = V.attach(ns, task, run, pr_url, pr_number, repo or "")
    pcall(function()
        require("queries.KanbanTaskQueries").addComment({
            task_id = task.id, user_uuid = run.requested_by,
            content = "Pull request ready for review: " .. pr_url
                .. "\nRun: /dashboard/ai-runner/runs/" .. run.uuid
                .. "\nManagers: approve or request changes on the task's AI work panel.",
        })
    end)
    R.alert(run, "pr_ready", nil, pr_url)
    return row
end

--- Manager sign-off on a PR of this task (does not merge). The task is part of the condition: a manager of one
-- project can't sign off a PR of another task. 404 when it isn't this task's.
function V.review(ns, task_uuid, pr_uuid, user_uuid, decision, note)
    if decision ~= "approved" and decision ~= "changes_requested" then
        U.invalid({ decision = "must be approved or changes_requested" })
    end
    local row = U.one([[
        UPDATE ar_task_prs SET review_status = ?, reviewed_by = ?, reviewed_at = NOW(),
            review_note = ?, updated_at = NOW()
        WHERE namespace_id = ? AND task_uuid = ? AND uuid = ? RETURNING *
    ]], decision, user_uuid, note and U.clean(note, 2000) or db.NULL, ns, task_uuid, pr_uuid)
    if not row then U.fail(404, "Pull request not found") end
    return row
end

function V.list_for_task(ns, task_uuid)
    return db.query([[SELECT * FROM ar_task_prs WHERE namespace_id = ? AND task_uuid = ?
        ORDER BY created_at DESC, id DESC LIMIT 50]], ns, task_uuid)
end

function V.view(p)
    return {
        uuid = p.uuid, task_uuid = p.task_uuid, project_uuid = p.project_uuid,
        run_uuid = U.null(p.run_uuid), repo = p.repo, pr_url = p.pr_url,
        pr_number = U.null(p.pr_number), state = p.state, review_status = p.review_status,
        reviewed_by = U.null(p.reviewed_by), reviewed_at = U.null(p.reviewed_at),
        review_note = U.null(p.review_note), created_at = p.created_at, updated_at = p.updated_at,
    }
end

-- Used by project_settings view
V.context = C

return V
