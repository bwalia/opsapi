--[[
    Domain Management API Routes
    ============================

    Namespace-scoped domain registry with SSL/registration expiry monitoring,
    two-way Cloudflare DNS management, encrypted provider credentials, and a
    k3s-job sync generator. Gated on the SERVICES feature (see app.lua).

    Permission model: every route requires the "domains" RBAC action via
    NamespaceMiddleware.requirePermission (which itself enforces auth + namespace,
    and lets platform admins / namespace owners through). Reads that a platform
    admin can widen to all namespaces honour self.is_platform_admin.

    Endpoints:
      GET    /api/v2/domains                         List (?all=true = admin super-view)
      GET    /api/v2/domains/stats                    Aggregate counts
      GET    /api/v2/domains/export                   JSON array for the k3s sync job
      POST   /api/v2/domains                          Create
      GET    /api/v2/domains/:uuid                    Get one
      PUT    /api/v2/domains/:uuid                    Update
      DELETE /api/v2/domains/:uuid                    Soft delete
      POST   /api/v2/domains/refresh-expiry           Bulk refresh (namespace)
      POST   /api/v2/domains/:uuid/refresh-expiry     Refresh one

      GET    /api/v2/domains/credentials              List provider creds (no secrets)
      POST   /api/v2/domains/credentials              Save/replace a cred (encrypts)
      POST   /api/v2/domains/credentials/verify       Verify the Cloudflare token
      DELETE /api/v2/domains/credentials/:provider    Delete a cred

      GET    /api/v2/domains/cloudflare/zones          List Cloudflare zones
      GET    /api/v2/domains/:uuid/cloudflare/records   List DNS records
      POST   /api/v2/domains/:uuid/cloudflare/records   Create DNS record
      PUT    /api/v2/domains/:uuid/cloudflare/records/:record_id   Update
      DELETE /api/v2/domains/:uuid/cloudflare/records/:record_id   Delete

      GET    /api/v2/domains/sync-configs              List sync configs
      POST   /api/v2/domains/sync-configs              Create
      GET    /api/v2/domains/sync-configs/:uuid        Get one
      PUT    /api/v2/domains/sync-configs/:uuid        Update
      DELETE /api/v2/domains/sync-configs/:uuid        Delete
      GET    /api/v2/domains/sync-configs/:uuid/manifest   Render CronJob YAML
      POST   /api/v2/domains/sync-configs/:uuid/run-now    Render run-once Job YAML
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local DomainQueries = require("queries.DomainQueries")
local DomainCredentialQueries = require("queries.DomainCredentialQueries")
local DomainSyncConfigQueries = require("queries.DomainSyncConfigQueries")

return function(app)
    -- Parse a request body supporting BOTH JSON and form-encoded (the dashboard
    -- posts form-encoded via toFormData; Lapis exposes those in self.params).
    local function parse_body(self)
        ngx.req.read_body()
        local raw = ngx.req.get_body_data()
        if raw and raw ~= "" then
            local ok, data = pcall(cjson.decode, raw)
            if ok and type(data) == "table" then return data end
        end
        local params = {}
        if self and self.params then
            for k, v in pairs(self.params) do params[k] = v end
        end
        return params
    end

    local function ok_resp(data, meta)
        if meta then
            return { status = 200, json = { success = true, data = data, meta = meta } }
        end
        return { status = 200, json = { success = true, data = data } }
    end

    local function err_resp(status, msg)
        return { status = status, json = { success = false, error = msg } }
    end

    local function trim(s)
        return (tostring(s == nil and "" or s):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    -- Load a domain and enforce namespace ownership (platform admins bypass).
    local function load_owned_domain(self, uuid)
        local domain = DomainQueries.getDomain(uuid)
        if not domain then return nil, err_resp(404, "Domain not found") end
        if not self.is_platform_admin and tonumber(domain.namespace_id) ~= tonumber(self.namespace.id) then
            return nil, err_resp(403, "Access denied")
        end
        return domain, nil
    end

    -- Resolve + decrypt the namespace's Cloudflare token, return a client or error.
    local function cloudflare_client(namespace_id)
        local token, terr = DomainCredentialQueries.getDecryptedSecret(namespace_id, "cloudflare")
        if not token then return nil, terr end
        local Cloudflare = require("lib.cloudflare")
        return Cloudflare.new(token), nil
    end

    local function domain_zone_id(client, domain)
        if domain.cloudflare_zone_id and domain.cloudflare_zone_id ~= "" then
            return domain.cloudflare_zone_id, nil
        end
        return client:find_zone_id(domain.domain_name)
    end

    -- ========================================================================
    -- LIST / STATS / EXPORT  (specific paths registered before /:uuid)
    -- ========================================================================

    app:get("/api/v2/domains", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local want_all = (self.params.all == "true" or self.params.all == "1") and self.is_platform_admin
            local result = DomainQueries.getDomains(self.namespace.id, {
                page = self.params.page,
                per_page = self.params.per_page,
                status = self.params.status,
                dns_provider = self.params.dns_provider,
                search = self.params.search,
                expiring_within_days = self.params.expiring_within_days,
                platform_admin = want_all,
            })
            return ok_resp(result.items, result.meta)
        end)
    ))

    app:get("/api/v2/domains/stats", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            return ok_resp(DomainQueries.getStats(self.namespace.id))
        end)
    ))

    -- Minimal list of EVERY domain (no pagination cap) for the sync modal's
    -- domain -> repo assignment matrix.
    app:get("/api/v2/domains/all", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local rows = DomainQueries.getAllForNamespace(self.namespace.id)
            local out = {}
            for _, d in ipairs(rows or {}) do
                table.insert(out, {
                    uuid = d.uuid, domain_name = d.domain_name,
                    environment = d.environment or "prod", sync_repo_uuid = d.sync_repo_uuid or "",
                })
            end
            return ok_resp(out)
        end)
    ))

    -- Export: a bare JSON array consumed by the k3s sync job.
    app:get("/api/v2/domains/export", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local rows = DomainQueries.getAllForNamespace(self.namespace.id)
            local out = {}
            for _, d in ipairs(rows or {}) do
                table.insert(out, {
                    domain_name = d.domain_name,
                    registrar = d.registrar,
                    dns_provider = d.dns_provider,
                    status = d.status,
                    registration_expires_at = d.registration_expires_at,
                    ssl_expires_at = d.ssl_expires_at,
                    ssl_issuer = d.ssl_issuer,
                    cloudflare_zone_id = d.cloudflare_zone_id,
                })
            end
            return { status = 200, json = { generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), count = #out, domains = out } }
        end)
    ))

    -- Render all domains for an environment as WSL Proxy server files and commit
    -- them to a GitHub repo (add/update only — never deletes hand-authored files).
    -- Body: { environment?, owner, repo, branch?, github_integration_id, data_base?,
    --         message?, dry_run? }. The GitHub token comes from the namespace's
    --         services GitHub integration (encrypted at rest).
    app:post("/api/v2/domains/sync-to-repo", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local data = parse_body(self)
            -- The single Sync Settings row is the DEFAULT repo + namespace defaults
            -- (backend, rule id, sync_rules, data_base, environment, templates).
            local SyncSettings = require("queries.DomainSyncSettingsQueries")
            local eff = SyncSettings.resolve(self.namespace.id, data)
            local env = eff.environment
            local default_repo = {
                name = "Default", owner = eff.owner, repo = eff.repo, branch = eff.branch or "main",
                github_integration_id = eff.github_integration_id,
            }
            local is_dry = data.dry_run == true or data.dry_run == "true"

            -- domain_uuids (array) and assignments (map) may arrive as real JSON
            -- (JSON body) OR as a JSON string inside a form field (the dashboard's
            -- api-client defaults to form-urlencoded). Accept both.
            local function as_table(v)
                if type(v) == "table" then return v end
                if type(v) == "string" and v ~= "" then
                    local ok, decoded = pcall(cjson.decode, v)
                    if ok and type(decoded) == "table" then return decoded end
                end
                return nil
            end
            local req_assignments = as_table(data.assignments) or {}
            local req_domain_uuids = as_table(data.domain_uuids)

            -- Persist the domain -> repo assignments the user made in the sync
            -- modal, so the mapping is remembered next time. A dry-run is a pure
            -- PREVIEW and must not mutate anything.
            if not is_dry then
                for dom_uuid, repo_uuid in pairs(req_assignments) do
                    local dom = DomainQueries.getDomain(dom_uuid)
                    if dom and tonumber(dom.namespace_id) == tonumber(self.namespace.id) then
                        DomainQueries.updateDomain(dom_uuid,
                            { sync_repo_uuid = (type(repo_uuid) == "string" and repo_uuid) or "" })
                    end
                end
            end

            -- Managed repos (uuid -> repo). A domain resolves to its assigned
            -- managed repo, else the default repo above.
            local RepoQ = require("queries.DomainSyncRepoQueries")
            local repo_by_uuid = {}
            for _, r in ipairs(RepoQ.list(self.namespace.id)) do repo_by_uuid[r.uuid] = r end
            local function resolve_repo(d)
                -- Prefer the in-flight assignment from the request (the user's
                -- current, possibly-unsaved choice); fall back to the stored one.
                local uuid = req_assignments[d.uuid] ~= nil and trim(req_assignments[d.uuid]) or trim(d.sync_repo_uuid)
                if uuid ~= "" and repo_by_uuid[uuid] then return repo_by_uuid[uuid] end
                return default_repo
            end

            local WslproxyServer = require("helper.wslproxy-server")
            local rows = DomainQueries.getAllForNamespace(self.namespace.id)

            -- Only sync the selected domains (the sync modal sends the checked
            -- set). Omitted -> every domain in the environment (backward compat).
            local selected = nil
            if req_domain_uuids and #req_domain_uuids > 0 then
                selected = {}
                for _, u in ipairs(req_domain_uuids) do selected[tostring(u)] = true end
            end

            -- Named, reusable JSON-format templates (per-domain choice wins; else
            -- the Sync Settings default; else the built-in format).
            local RTQ = require("queries.RenderTemplateQueries")
            local function template_content(uuid, want_type)
                if not uuid or uuid == "" then return nil end
                local tpl = RTQ.getByUuid(self.namespace.id, uuid)
                if tpl and tpl.template_type == want_type and tpl.content and tpl.content ~= "" then
                    return tpl.content
                end
                return nil
            end

            -- Attached shared rules are fetched LIVE from WSL Proxy (if connected)
            -- and pushed only when missing; otherwise domains fall back to
            -- template-generated rules (backward compatible).
            local fetch_rule = nil
            do
                local WslproxyClient = require("lib.wslproxy-client")
                local wc = WslproxyClient.for_namespace(self.namespace.id)
                if wc then
                    fetch_rule = function(rid)
                        local _, raw, ferr = wc.get_rule(rid)
                        if raw and raw ~= "" then return raw, nil end
                        return nil, ferr or "fetch failed"
                    end
                end
            end

            -- Group the (selected) domains by their resolved repo.
            local groups, order = {}, {}
            for _, d in ipairs(rows or {}) do
                if (d.environment or "prod") == env and (not selected or selected[tostring(d.uuid)]) then
                    local rp = resolve_repo(d)
                    local key = tostring(rp.owner) .. "/" .. tostring(rp.repo) .. "@" .. tostring(rp.branch)
                    if not groups[key] then
                        groups[key] = { repo = rp, rows = {} }
                        table.insert(order, key)
                    end
                    table.insert(groups[key].rows, d)
                end
            end
            if #order == 0 then
                return err_resp(400, "No domains selected for environment '" .. env .. "'")
            end

            local base_opts = {
                default_rule_id = eff.default_rule_id,
                default_backend = eff.default_backend,
                sync_rules      = eff.sync_rules,
                resolve_template = function(uuid, want_type) return template_content(uuid, want_type) end,
                fetch_rule = fetch_rule,
            }
            -- Per-group server/rule template = the repo has none, so use the
            -- namespace default (per-domain choice still wins inside the renderer).
            base_opts.server_template = eff.server_template
            base_opts.rule_template = eff.rule_template

            -- DRY RUN: render each group; no token, no commit, no existence check.
            if is_dry then
                local out = {}
                for _, key in ipairs(order) do
                    local g = groups[key]
                    local built = WslproxyServer.build_sync_files(g.rows, env, eff.data_base, base_opts)
                    table.insert(out, { repo = g.repo.owner .. "/" .. g.repo.repo, branch = g.repo.branch,
                        repo_name = g.repo.name, count = #built.files, rules = built.rules_count,
                        warnings = built.warnings, skipped = built.skipped, files = built.rendered })
                end
                return ok_resp({ dry_run = true, environment = env, repos = out })
            end

            -- Resolve + decrypt a GitHub token PER repo (each repo carries its own
            -- integration). Memoised so repos sharing an integration decrypt once.
            local ok_sq, ServiceQueries = pcall(require, "queries.ServiceQueries")
            local token_cache = {}
            local function resolve_token(integration_id)
                if not integration_id or integration_id == "" then
                    return nil, "no GitHub integration set for this repo — configure it in Sync Settings"
                end
                if token_cache[integration_id] then
                    return token_cache[integration_id].token, token_cache[integration_id].err
                end
                local tok, err
                if not ok_sq then
                    err = "services module unavailable"
                else
                    local integ = ServiceQueries.getGithubIntegration(integration_id, true)
                    if not integ then err = "GitHub integration not found"
                    elseif tonumber(integ.namespace_id) ~= tonumber(self.namespace.id) then
                        err = "Integration belongs to another namespace"
                    else
                        tok = integ.github_token_decrypted
                        if not tok or tok == "" then err = "Could not decrypt the GitHub integration token" end
                    end
                end
                token_cache[integration_id] = { token = tok, err = err }
                return tok, err
            end

            local GithubRepo = require("lib.github-repo")
            local Global = require("helper.global")

            -- One PR per repo group. Never fast-forwards a base branch directly.
            local results, any_ok, any_fail = {}, false, false
            for _, key in ipairs(order) do
                local g = groups[key]
                local repo_label = tostring(g.repo.owner) .. "/" .. tostring(g.repo.repo)

                -- Guard: a repo must have owner/repo and a usable token.
                if not g.repo.owner or g.repo.owner == "" or not g.repo.repo or g.repo.repo == "" then
                    table.insert(results, { repo = repo_label, branch = g.repo.branch, repo_name = g.repo.name,
                        ok = false, error = "repo not configured — assign these domains to a repo or set a default in Sync Settings" })
                    any_fail = true
                else
                    local token, terr = resolve_token(g.repo.github_integration_id)
                    if not token then
                        table.insert(results, { repo = repo_label, branch = g.repo.branch, repo_name = g.repo.name,
                            ok = false, error = terr })
                        any_fail = true
                    else
                        local opts = {}
                        for k, v in pairs(base_opts) do opts[k] = v end
                        opts.rule_exists_in_repo = function(path)
                            return GithubRepo.file_exists({ token = token, owner = g.repo.owner, repo = g.repo.repo, branch = g.repo.branch }, path)
                        end

                        local built = WslproxyServer.build_sync_files(g.rows, env, eff.data_base, opts)
                        if #built.files == 0 then
                            table.insert(results, { repo = repo_label, branch = g.repo.branch, repo_name = g.repo.name,
                                ok = false, error = "nothing to sync (rules skipped or unrenderable)", warnings = built.warnings })
                            any_fail = true
                        else
                            local short = tostring(Global.generateUUID()):gsub("%-", ""):sub(1, 6)
                            local new_branch = "opsapi-domains/sync-" .. env .. "-"
                                .. os.date("!%Y%m%d-%H%M%S") .. "-" .. short
                            local commit_msg = data.message
                                or ("chore(domains): sync " .. #built.files .. " " .. env .. " domains from opsapi")
                            local pr_body = table.concat({
                                "Automated domain sync from opsapi — please review and merge.",
                                "",
                                "- Environment: `" .. env .. "`",
                                "- Repo: `" .. repo_label .. "` → `" .. g.repo.branch .. "`",
                                "- Files: " .. #built.files .. " (rules: " .. tostring(built.rules_count) .. ")",
                                "",
                                "Generated by the domains module.",
                            }, "\n")

                            local result, gerr = GithubRepo.sync_via_pull_request({
                                token = token, owner = g.repo.owner, repo = g.repo.repo,
                                base_branch = g.repo.branch, new_branch = new_branch,
                                message = commit_msg, files = built.files,
                                author_name = "opsapi-domain-sync", author_email = "domain-sync@opsapi",
                                pr_title = data.pr_title or commit_msg, pr_body = pr_body,
                            })
                            if not result then
                                table.insert(results, { repo = repo_label, branch = g.repo.branch, repo_name = g.repo.name,
                                    ok = false, error = tostring(gerr), warnings = built.warnings })
                                any_fail = true
                            else
                                table.insert(results, { repo = repo_label, branch = g.repo.branch, repo_name = g.repo.name,
                                    ok = true, base_branch = result.base, head_branch = result.branch, commit = result.commit,
                                    pr_url = result.pr_url, pr_number = result.pr_number,
                                    count = #built.files, rules = built.rules_count,
                                    warnings = built.warnings, skipped = built.skipped, files = built.rendered })
                                any_ok = true
                            end
                        end
                    end
                end
            end

            return { status = any_ok and 200 or 502,
                json = { success = any_ok, data = { environment = env, any_failed = any_fail, repos = results } } }
        end)
    ))

    -- ========================================================================
    -- PIPELINE (opsapi-driven: sync → dns-reconcile → wslproxy-register → auto-tag)
    -- ========================================================================

    app:post("/api/v2/domains/pipeline/run", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local data = parse_body(self)
            -- Resolve target from saved Sync Settings; request params override.
            local SyncSettings = require("queries.DomainSyncSettingsQueries")
            local eff, missing = SyncSettings.resolve(self.namespace.id, data)
            if #missing > 0 then
                return err_resp(400, "Missing " .. table.concat(missing, ", ")
                    .. " — configure Sync Settings once (repo + GitHub auth)")
            end
            if not eff.github_integration_id then
                return err_resp(400, "No GitHub integration linked — configure Sync Settings")
            end

            local DomainPipeline = require("helper.domain-pipeline")
            local run, err = DomainPipeline.start({
                namespace_id = self.namespace.id,
                environment = eff.environment,
                owner = eff.owner,
                repo = eff.repo,
                branch = eff.branch,
                github_integration_id = eff.github_integration_id,
                triggered_by_uuid = self.current_user.uuid,
            })
            if not run then return err_resp(400, err) end
            return { status = 202, json = { success = true, data = run } }
        end)
    ))

    app:get("/api/v2/domains/pipeline/runs", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local Q = require("queries.DomainPipelineRunQueries")
            return ok_resp(Q.list(self.namespace.id, self.params.limit))
        end)
    ))

    app:get("/api/v2/domains/pipeline/runs/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local Q = require("queries.DomainPipelineRunQueries")
            local run = Q.get(self.params.uuid)
            if not run then return err_resp(404, "Pipeline run not found") end
            if not self.is_platform_admin and tonumber(run.namespace_id) ~= tonumber(self.namespace.id) then
                return err_resp(403, "Access denied")
            end
            return ok_resp(run)
        end)
    ))

    -- ========================================================================
    -- SYNC SETTINGS (persisted per-namespace target: repo + branch + GitHub auth)
    -- ========================================================================

    app:get("/api/v2/domains/sync-settings", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local SyncSettings = require("queries.DomainSyncSettingsQueries")
            local s = SyncSettings.get(self.namespace.id)
            -- Enrich with the linked integration's display name (no token).
            local integration_name = nil
            if s and s.github_integration_id then
                local ok_sq, ServiceQueries = pcall(require, "queries.ServiceQueries")
                if ok_sq then
                    local integ = ServiceQueries.getGithubIntegration(s.github_integration_id, false)
                    if integ then integration_name = integ.name or integ.github_username end
                end
            end
            return ok_resp({ settings = s, integration_name = integration_name })
        end)
    ))

    app:put("/api/v2/domains/sync-settings", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local data = parse_body(self)

            -- Inline GitHub auth is OPTIONAL. Saving the sync target (owner/repo/
            -- branch) must never be blocked by GitHub-token validation, so we
            -- only validate + encrypt + link a Services integration when a
            -- GENUINE new token is supplied. A nil / empty / whitespace-only /
            -- masked ("********") value means "leave auth unchanged" — the caller
            -- may instead pick an existing integration via github_integration_id,
            -- or save no auth at all and add it later. (A real-but-invalid token
            -- still returns a clear 400 so the user knows it was rejected.)
            local integration_id = data.github_integration_id
            local token = data.github_token
            if type(token) == "string" then
                token = token:gsub("^%s+", ""):gsub("%s+$", "")
            end
            if type(token) == "string" and token ~= "" and token ~= "********" then
                local ok_sq, ServiceQueries = pcall(require, "queries.ServiceQueries")
                if not ok_sq then return err_resp(500, "services module unavailable") end
                local created, cerr = ServiceQueries.createGithubIntegration(self.namespace.id, {
                    name = data.integration_name or "Domain Sync",
                    github_token = token,
                    github_username = data.github_username,
                    created_by = self.current_user and self.current_user.uuid,
                })
                if not created then return err_resp(400, cerr or "GitHub token validation failed") end
                integration_id = created.uuid
            end

            local SyncSettings = require("queries.DomainSyncSettingsQueries")
            local saved = SyncSettings.upsert(self.namespace.id, {
                -- Callers may paste a repo URL instead of owner+repo; upsert
                -- derives owner/repo (and branch) from it. owner/repo are still
                -- honoured when sent explicitly (e.g. an older client).
                repo_url = data.repo_url,
                owner = data.owner,
                repo = data.repo,
                branch = data.branch,
                github_integration_id = integration_id,
                data_base = data.data_base,
                default_environment = data.default_environment,
                -- Rule generation: a set-once backend (used when a domain has no
                -- proxy_target), an optional shared rule id, and a toggle.
                default_backend = data.default_backend,
                default_rule_id = data.default_rule_id,
                sync_rules = data.sync_rules,
            })
            if not saved then return err_resp(500, "Failed to save sync settings") end
            return ok_resp(saved)
        end)
    ))

    -- Convenience: list the namespace's GitHub integrations (masked) for the
    -- Sync-Settings picker — gated on domains, so a domains admin needn't hold
    -- the separate services permission.
    app:get("/api/v2/domains/github-integrations", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local ok_sq, ServiceQueries = pcall(require, "queries.ServiceQueries")
            if not ok_sq then return ok_resp({}) end
            local list = ServiceQueries.getGithubIntegrations(self.namespace.id) or {}
            return ok_resp(list)
        end)
    ))

    -- ========================================================================
    -- SYNC REPOS (managed multi-repo targets; the settings row is the default)
    -- ========================================================================

    app:get("/api/v2/domains/sync-repos", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local Q = require("queries.DomainSyncRepoQueries")
            return ok_resp(Q.list(self.namespace.id))
        end)
    ))

    app:post("/api/v2/domains/sync-repos", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local data = parse_body(self)
            local Q = require("queries.DomainSyncRepoQueries")
            local repo, err = Q.create(self.namespace.id, {
                name = data.name, repo_url = data.repo_url,
                owner = data.owner, repo = data.repo, branch = data.branch,
                github_integration_id = data.github_integration_id,
            })
            if not repo then return err_resp(400, err or "Failed to add repo") end
            return { status = 201, json = { success = true, data = repo } }
        end)
    ))

    app:put("/api/v2/domains/sync-repos/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local data = parse_body(self)
            local Q = require("queries.DomainSyncRepoQueries")
            local repo, err = Q.update(self.namespace.id, self.params.uuid, {
                name = data.name, repo_url = data.repo_url,
                owner = data.owner, repo = data.repo, branch = data.branch,
                github_integration_id = data.github_integration_id,
            })
            if not repo then return err_resp(err == "Repo not found" and 404 or 400, err or "Update failed") end
            return ok_resp(repo)
        end)
    ))

    app:delete("/api/v2/domains/sync-repos/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "delete", function(self)
            require("queries.DomainSyncRepoQueries").delete(self.namespace.id, self.params.uuid)
            return ok_resp({ deleted = true })
        end)
    ))

    -- ========================================================================
    -- WSL PROXY CONNECTION + shared rules (before /:uuid)
    --
    -- A namespace connects its WSL Proxy control plane once (URL + email +
    -- password, stored AES-encrypted). Domains then ATTACH a shared rule chosen
    -- from that live API (see the /wslproxy/rules dropdown) instead of minting
    -- one rule per domain. The password is never returned; it is decrypted
    -- server-side only to log in and list/fetch rules.
    -- ========================================================================

    app:get("/api/v2/domains/wslproxy/status", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local WC = require("queries.WslproxyConnectionQueries")
            return ok_resp(WC.status(self.namespace.id))
        end)
    ))

    -- Connect (or replace) — validates by a LIVE login before persisting, so a
    -- bad URL/credential fails fast and nothing invalid is stored.
    app:post("/api/v2/domains/wslproxy/connect", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local data = parse_body(self)
            local api_url = trim(data.api_url)
            local email = trim(data.email)
            local password = data.password
            if api_url == "" then return err_resp(400, "api_url is required") end
            if not password or password == "" then return err_resp(400, "password is required") end

            local WslproxyClient = require("lib.wslproxy-client")
            local ok, verr = WslproxyClient.verify({ api_url = api_url, email = email, password = password })
            if not ok then return err_resp(400, verr or "Could not connect to WSL Proxy") end

            local WC = require("queries.WslproxyConnectionQueries")
            local saved, serr = WC.save({
                namespace_id = self.namespace.id, api_url = api_url, email = email, password = password,
            })
            if not saved then return err_resp(500, serr or "Failed to save connection") end
            return ok_resp(saved)
        end)
    ))

    app:delete("/api/v2/domains/wslproxy/disconnect", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "delete", function(self)
            require("queries.WslproxyConnectionQueries").delete(self.namespace.id)
            return ok_resp({ disconnected = true })
        end)
    ))

    -- Searchable list of shared rules for the domain form's rule dropdown.
    app:get("/api/v2/domains/wslproxy/rules", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local WslproxyClient = require("lib.wslproxy-client")
            local client, cerr = WslproxyClient.for_namespace(self.namespace.id)
            if not client then return err_resp(409, cerr or "Connect WSL Proxy first") end
            local rules, rerr = client.list_rules(self.params.search, self.params.environment)
            if not rules then return err_resp(502, rerr or "Failed to list WSL Proxy rules") end
            return ok_resp(rules)
        end)
    ))

    -- ========================================================================
    -- CREDENTIALS (before /:uuid)
    -- ========================================================================

    app:get("/api/v2/domains/credentials", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            return ok_resp(DomainCredentialQueries.list(self.namespace.id))
        end)
    ))

    app:post("/api/v2/domains/credentials", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local data = parse_body(self)
            if not data.secret or data.secret == "" then
                return err_resp(400, "secret (API token) is required")
            end
            local cred, cerr = DomainCredentialQueries.save({
                namespace_id = self.namespace.id,
                provider = data.provider or "cloudflare",
                label = data.label,
                secret = data.secret,
                account_id = data.account_id,
                email = data.email,
            })
            if not cred then return err_resp(500, cerr or "Failed to save credential") end
            return ok_resp(cred)
        end)
    ))

    app:post("/api/v2/domains/credentials/verify", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local client, cerr = cloudflare_client(self.namespace.id)
            if not client then return err_resp(400, cerr) end
            local res, verr = client:verify_token()
            if not res then return err_resp(400, verr) end
            return ok_resp({ valid = true, status = res.status })
        end)
    ))

    app:delete("/api/v2/domains/credentials/:provider", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "delete", function(self)
            DomainCredentialQueries.delete(self.namespace.id, self.params.provider)
            return ok_resp({ message = "Credential deleted" })
        end)
    ))

    -- ========================================================================
    -- CLOUDFLARE ZONES (before /:uuid)
    -- ========================================================================

    app:get("/api/v2/domains/cloudflare/zones", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local client, cerr = cloudflare_client(self.namespace.id)
            if not client then return err_resp(400, cerr) end
            local zones, zerr = client:list_zones({ name = self.params.name })
            if not zones then return err_resp(400, zerr) end
            return ok_resp(zones)
        end)
    ))

    -- ========================================================================
    -- SYNC CONFIGS (before /:uuid)
    -- ========================================================================

    app:get("/api/v2/domains/sync-configs", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            return ok_resp(DomainSyncConfigQueries.list(self.namespace.id))
        end)
    ))

    app:post("/api/v2/domains/sync-configs", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "create", function(self)
            local data = parse_body(self)
            if not data.name or data.name == "" then return err_resp(400, "name is required") end
            if not data.github_repo or data.github_repo == "" then
                return err_resp(400, "github_repo (owner/repo) is required")
            end
            local cfg = DomainSyncConfigQueries.create({
                namespace_id = self.namespace.id,
                name = data.name,
                destination_type = data.destination_type or "github",
                github_repo = data.github_repo,
                github_branch = data.github_branch or "main",
                file_path = data.file_path or "domains.json",
                commit_author_name = data.commit_author_name,
                commit_author_email = data.commit_author_email,
                github_token_secret_ref = data.github_token_secret_ref,
                github_token_secret_key = data.github_token_secret_key or "github-token",
                opsapi_base_url = data.opsapi_base_url,
                opsapi_token_secret_key = data.opsapi_token_secret_key or "opsapi-token",
                schedule = data.schedule or "0 3 * * *",
                is_enabled = data.is_enabled ~= nil and data.is_enabled or true,
                metadata = "{}",
            })
            if not cfg then return err_resp(500, "Failed to create sync config") end
            return { status = 201, json = { success = true, data = cfg } }
        end)
    ))

    local function load_owned_sync(self, uuid)
        local cfg = DomainSyncConfigQueries.get(uuid)
        if not cfg then return nil, err_resp(404, "Sync config not found") end
        if not self.is_platform_admin and tonumber(cfg.namespace_id) ~= tonumber(self.namespace.id) then
            return nil, err_resp(403, "Access denied")
        end
        return cfg, nil
    end

    app:get("/api/v2/domains/sync-configs/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local cfg, e = load_owned_sync(self, self.params.uuid)
            if not cfg then return e end
            return ok_resp(cfg)
        end)
    ))

    app:put("/api/v2/domains/sync-configs/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local cfg, e = load_owned_sync(self, self.params.uuid)
            if not cfg then return e end
            local data = parse_body(self)
            local updated = DomainSyncConfigQueries.update(self.params.uuid, data)
            if not updated then return err_resp(500, "Failed to update sync config") end
            return ok_resp(updated)
        end)
    ))

    app:delete("/api/v2/domains/sync-configs/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "delete", function(self)
            local cfg, e = load_owned_sync(self, self.params.uuid)
            if not cfg then return e end
            DomainSyncConfigQueries.delete(self.params.uuid)
            return ok_resp({ message = "Sync config deleted" })
        end)
    ))

    -- Render the scheduled CronJob manifest.
    app:get("/api/v2/domains/sync-configs/:uuid/manifest", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local cfg, e = load_owned_sync(self, self.params.uuid)
            if not cfg then return e end
            local Manifest = require("helper.domain-sync-manifest")
            local yaml, merr = Manifest.render_cronjob(cfg, {
                namespace_uuid = self.namespace.uuid,
                namespace_slug = self.namespace.slug,
                k8s_namespace = self.params.k8s_namespace,
                opsapi_base_url_override = self.params.opsapi_base_url,
            })
            if not yaml then return err_resp(400, merr) end
            return ok_resp({ kind = "CronJob", filename = "domain-sync-cronjob.yaml", manifest = yaml })
        end)
    ))

    -- Render a run-once Job manifest ("sync now") and mark the config as triggered.
    app:post("/api/v2/domains/sync-configs/:uuid/run-now", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local cfg, e = load_owned_sync(self, self.params.uuid)
            if not cfg then return e end
            local Manifest = require("helper.domain-sync-manifest")
            local yaml, merr = Manifest.render_job(cfg, {
                namespace_uuid = self.namespace.uuid,
                namespace_slug = self.namespace.slug,
                k8s_namespace = self.params.k8s_namespace,
                opsapi_base_url_override = self.params.opsapi_base_url,
            })
            if not yaml then return err_resp(400, merr) end
            DomainSyncConfigQueries.recordRun(self.params.uuid, "manifest_generated", nil)
            return ok_resp({
                kind = "Job",
                filename = "domain-sync-run-once.yaml",
                manifest = yaml,
                apply_hint = "kubectl apply -f domain-sync-run-once.yaml",
            })
        end)
    ))

    -- ========================================================================
    -- BULK REFRESH (before /:uuid)
    -- ========================================================================

    app:post("/api/v2/domains/refresh-expiry", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local DomainExpiry = require("helper.domain-expiry")
            local summary = DomainExpiry.refresh_namespace(self.namespace.id)
            return ok_resp(summary)
        end)
    ))

    -- ========================================================================
    -- CREATE
    -- ========================================================================

    app:post("/api/v2/domains", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "create", function(self)
            local data = parse_body(self)
            if not data.domain_name or data.domain_name == "" then
                return err_resp(400, "domain_name is required")
            end

            local metadata = data.metadata
            if metadata and type(metadata) == "table" then metadata = cjson.encode(metadata) end

            local created, cerr = DomainQueries.createDomain({
                namespace_id = self.namespace.id,
                domain_name = (data.domain_name):lower(),
                registrar = data.registrar,
                dns_provider = data.dns_provider or "cloudflare",
                cloudflare_zone_id = data.cloudflare_zone_id,
                status = data.status or "active",
                alert_threshold_days = tonumber(data.alert_threshold_days) or 30,
                auto_renew = data.auto_renew == true or data.auto_renew == "true",
                owner_user_uuid = data.owner_user_uuid or self.current_user.uuid,
                notes = data.notes,
                -- WSL Proxy vhost fields
                environment = data.environment or "prod",
                wslproxy_rule_id = data.wslproxy_rule_id,
                ssl_email = data.ssl_email,
                ssl_enabled = data.ssl_enabled == nil and true or (data.ssl_enabled == true or data.ssl_enabled == "true"),
                ssl_auto_renew = data.ssl_auto_renew == nil and true or (data.ssl_auto_renew == true or data.ssl_auto_renew == "true"),
                ssl_force_https = data.ssl_force_https == nil and true or (data.ssl_force_https == true or data.ssl_force_https == "true"),
                ssl_staging = data.ssl_staging == true or data.ssl_staging == "true",
                wslproxy_root = data.wslproxy_root or "/var/www/html",
                listen_ports = data.listen_ports or "80",
                proxy_target = data.proxy_target,
                -- WSL Proxy rule match path (default "/"). The rule id itself is
                -- auto-generated (opsapi-<domain>) by the renderer.
                rule_path = data.rule_path or "/",
                -- Per-domain template choice + assigned sync repo (blank -> default).
                server_template_uuid = data.server_template_uuid,
                rule_template_uuid = data.rule_template_uuid,
                sync_repo_uuid = data.sync_repo_uuid,
                metadata = metadata or "{}",
            })
            if not created then
                -- A same-name collision is a client error (409), not a 500.
                if cerr and cerr.code == "duplicate" then
                    return err_resp(409, cerr.message)
                end
                return err_resp(500, (cerr and cerr.message) or "Failed to create domain")
            end
            return { status = 201, json = { success = true, data = created } }
        end)
    ))

    -- ========================================================================
    -- SINGLE-DOMAIN ROUTES (/:uuid ...)
    -- ========================================================================

    app:get("/api/v2/domains/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local domain, e = load_owned_domain(self, self.params.uuid)
            if not domain then return e end
            return ok_resp(domain)
        end)
    ))

    app:put("/api/v2/domains/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local domain, e = load_owned_domain(self, self.params.uuid)
            if not domain then return e end
            local data = parse_body(self)
            if data.metadata ~= nil and type(data.metadata) == "table" then
                data.metadata = cjson.encode(data.metadata)
            end
            if data.domain_name then data.domain_name = (data.domain_name):lower() end
            local updated = DomainQueries.updateDomain(self.params.uuid, data)
            if not updated then return err_resp(500, "Failed to update domain") end
            return ok_resp(updated)
        end)
    ))

    app:delete("/api/v2/domains/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "delete", function(self)
            local domain, e = load_owned_domain(self, self.params.uuid)
            if not domain then return e end
            DomainQueries.deleteDomain(self.params.uuid)
            return ok_resp({ message = "Domain deleted successfully" })
        end)
    ))

    app:post("/api/v2/domains/:uuid/refresh-expiry", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local domain, e = load_owned_domain(self, self.params.uuid)
            if not domain then return e end
            local DomainExpiry = require("helper.domain-expiry")
            local updated, result = DomainExpiry.refresh(domain)
            if not updated then return err_resp(500, "Failed to refresh expiry") end
            return ok_resp({ domain = updated, check = result })
        end)
    ))

    -- ------------------------------------------------------------------
    -- Cloudflare DNS records for a specific domain (two-way)
    -- ------------------------------------------------------------------

    app:get("/api/v2/domains/:uuid/cloudflare/records", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "read", function(self)
            local domain, e = load_owned_domain(self, self.params.uuid)
            if not domain then return e end
            local client, cerr = cloudflare_client(domain.namespace_id)
            if not client then return err_resp(400, cerr) end
            local zone_id, zerr = domain_zone_id(client, domain)
            if not zone_id then return err_resp(400, zerr) end
            local records, rerr = client:list_dns_records(zone_id, {
                type = self.params.type, name = self.params.name,
            })
            if not records then return err_resp(400, rerr) end
            return ok_resp({ zone_id = zone_id, records = records })
        end)
    ))

    app:post("/api/v2/domains/:uuid/cloudflare/records", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local domain, e = load_owned_domain(self, self.params.uuid)
            if not domain then return e end
            local data = parse_body(self)
            local client, cerr = cloudflare_client(domain.namespace_id)
            if not client then return err_resp(400, cerr) end
            local zone_id, zerr = domain_zone_id(client, domain)
            if not zone_id then return err_resp(400, zerr) end
            local record, rerr = client:create_dns_record(zone_id, {
                type = data.type,
                name = data.name,
                content = data.content,
                ttl = tonumber(data.ttl) or 1,
                proxied = data.proxied == true or data.proxied == "true",
                priority = tonumber(data.priority),
            })
            if not record then return err_resp(400, rerr) end
            return { status = 201, json = { success = true, data = record } }
        end)
    ))

    app:put("/api/v2/domains/:uuid/cloudflare/records/:record_id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local domain, e = load_owned_domain(self, self.params.uuid)
            if not domain then return e end
            local data = parse_body(self)
            local client, cerr = cloudflare_client(domain.namespace_id)
            if not client then return err_resp(400, cerr) end
            local zone_id, zerr = domain_zone_id(client, domain)
            if not zone_id then return err_resp(400, zerr) end
            local record, rerr = client:update_dns_record(zone_id, self.params.record_id, {
                type = data.type,
                name = data.name,
                content = data.content,
                ttl = tonumber(data.ttl) or 1,
                proxied = data.proxied == true or data.proxied == "true",
                priority = tonumber(data.priority),
            })
            if not record then return err_resp(400, rerr) end
            return ok_resp(record)
        end)
    ))

    app:delete("/api/v2/domains/:uuid/cloudflare/records/:record_id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("domains", "update", function(self)
            local domain, e = load_owned_domain(self, self.params.uuid)
            if not domain then return e end
            local client, cerr = cloudflare_client(domain.namespace_id)
            if not client then return err_resp(400, cerr) end
            local zone_id, zerr = domain_zone_id(client, domain)
            if not zone_id then return err_resp(400, zerr) end
            local res, rerr = client:delete_dns_record(zone_id, self.params.record_id)
            if not res then return err_resp(400, rerr) end
            return ok_resp({ message = "DNS record deleted", id = res.id })
        end)
    ))
end
