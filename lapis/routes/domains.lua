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
            -- Resolve target from saved Sync Settings; request params override.
            local SyncSettings = require("queries.DomainSyncSettingsQueries")
            local eff, missing = SyncSettings.resolve(self.namespace.id, data)
            if #missing > 0 then
                return err_resp(400, "Missing " .. table.concat(missing, ", ")
                    .. " — set them here or configure Sync Settings once")
            end
            local env = eff.environment
            local owner = eff.owner
            local repo = eff.repo

            -- Render every domain in this namespace+env to a WSL Proxy server file
            -- (+ the opsapi-managed manifest used by the DNS reconcile).
            local WslproxyServer = require("helper.wslproxy-server")
            local rows = DomainQueries.getAllForNamespace(self.namespace.id)
            local built = WslproxyServer.build_sync_files(rows, env, eff.data_base)
            local files = built.files
            local rendered = built.rendered

            if built.count == 0 then
                return err_resp(400, "No domains for environment '" .. env .. "' to sync")
            end

            -- Dry-run: return the rendered files without committing.
            if data.dry_run == true or data.dry_run == "true" then
                return ok_resp({ dry_run = true, environment = env, count = #files, files = rendered })
            end

            -- Resolve the GitHub token from the linked services integration.
            if not eff.github_integration_id then
                return err_resp(400, "No GitHub integration linked — configure Sync Settings (repo + GitHub auth)")
            end
            local ok_sq, ServiceQueries = pcall(require, "queries.ServiceQueries")
            if not ok_sq then return err_resp(500, "services module unavailable") end
            local integration = ServiceQueries.getGithubIntegration(eff.github_integration_id, true)
            if not integration then return err_resp(404, "GitHub integration not found") end
            if tonumber(integration.namespace_id) ~= tonumber(self.namespace.id) then
                return err_resp(403, "Integration belongs to another namespace")
            end
            local token = integration.github_token_decrypted
            if not token or token == "" then
                return err_resp(400, "Could not decrypt the GitHub integration token")
            end

            local GithubRepo = require("lib.github-repo")
            local sha, gerr = GithubRepo.commit_files({
                token = token,
                owner = owner,
                repo = repo,
                branch = eff.branch,
                message = data.message or ("chore(domains): sync " .. #files .. " " .. env .. " domains from opsapi"),
                files = files,
                author_name = "opsapi-domain-sync",
                author_email = "domain-sync@opsapi",
            })
            if not sha then return err_resp(502, "GitHub commit failed: " .. tostring(gerr)) end

            return ok_resp({
                environment = env,
                repo = owner .. "/" .. repo,
                branch = eff.branch,
                commit = sha,
                count = #files,
                files = rendered,
            })
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
                owner = data.owner,
                repo = data.repo,
                branch = data.branch,
                github_integration_id = integration_id,
                data_base = data.data_base,
                default_environment = data.default_environment,
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

            local created = DomainQueries.createDomain({
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
                metadata = metadata or "{}",
            })
            if not created then return err_resp(500, "Failed to create domain") end
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
