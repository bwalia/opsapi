--[[
    Theme Routes
    ============

    REST API for the multi-tenant theme system. All endpoints are prefixed
    with /api/v2/themes. Writes are gated by the `themes` RBAC module with
    granular actions (read/create/update/delete/activate/publish/manage).

    Public endpoint:
      GET /api/v2/themes/active/styles.css

    The active stylesheet is served without auth so unauthenticated marketing
    pages / login screens can adopt the active tenant theme. Namespace is
    resolved from X-Namespace-Slug/X-Namespace-Id headers or query params.
    The response is safe to serve publicly: no user data, only design tokens.

    Route order is significant — specific paths come BEFORE :uuid catch-alls.

    Endpoints:
    ---------
      GET    /api/v2/themes                           list themes for ns
      GET    /api/v2/themes/presets                   platform starter themes
      GET    /api/v2/themes/marketplace               public published themes
      GET    /api/v2/themes/schema                    token schema (editor UI)
      GET    /api/v2/themes/active                    current active theme JSON
      GET    /api/v2/themes/active/styles.css         rendered CSS (public)
      POST   /api/v2/themes                           create (from scratch/preset)
      POST   /api/v2/themes/install/:source_uuid      install marketplace theme
      GET    /api/v2/themes/:uuid                     get single theme
      PUT    /api/v2/themes/:uuid                     update tokens/CSS
      DELETE /api/v2/themes/:uuid                     soft delete
      POST   /api/v2/themes/:uuid/activate            set as active
      POST   /api/v2/themes/:uuid/duplicate           clone into new theme
      POST   /api/v2/themes/:uuid/revert              revert to revision
      GET    /api/v2/themes/:uuid/revisions           list revisions
      GET    /api/v2/themes/:uuid/preview.css         preview CSS for editor
      POST   /api/v2/themes/:uuid/publish             set visibility=public
      POST   /api/v2/themes/:uuid/unpublish           set visibility=private
]]

local cjson = require("cjson.safe")
cjson.encode_empty_table_as_object(false)

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

local ThemeService = require("lib.theme-service")
local ThemeQueries = require("queries.ThemeQueries")
local ThemeRevisionQueries = require("queries.ThemeRevisionQueries")
local ThemeRenderer = require("lib.theme-renderer")
local ThemeTokenSchema = require("helper.theme-token-schema")
local ThemeCache = require("helper.theme-cache")

return function(app)

    -- =========================================================================
    -- Request helpers
    -- =========================================================================
    local function parse_body()
        ngx.req.read_body()
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then return post_args end

        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end

        local decoded = cjson.decode(body)
        if type(decoded) == "table" then return decoded end
        return {}
    end

    local function api_ok(status, data, extras)
        local payload = { success = true, data = data }
        if extras then
            for k, v in pairs(extras) do payload[k] = v end
        end
        return { status = status, json = payload }
    end

    local function api_err(status, err, extras)
        local payload = { success = false, error = err }
        if extras then
            for k, v in pairs(extras) do payload[k] = v end
        end
        return { status = status, json = payload }
    end

    -- Route service-layer result into an HTTP response.
    local function respond(result, success_status)
        if not result then
            return api_err(500, "unexpected empty service result")
        end
        if result.ok then
            return api_ok(success_status or 200, result.data)
        end
        local extras = {}
        if result.errors then extras.validation_errors = result.errors end
        return api_err(result.status or 500, result.error or "unknown error", extras)
    end

    -- Pick the project_code for this request. Precedence:
    --   explicit ?project_code=... query/body > namespace default > first enabled feature
    local function resolve_project_code(self, body)
        if body and body.project_code and body.project_code ~= "" then
            return body.project_code
        end
        if self.params and self.params.project_code and self.params.project_code ~= "" then
            return self.params.project_code
        end
        if self.namespace and self.namespace.default_project_code and self.namespace.default_project_code ~= "" then
            return self.namespace.default_project_code
        end
        local ok_cfg, ProjectConfig = pcall(require, "helper.project-config")
        if ok_cfg then
            local codes = ProjectConfig.parseProjectCodes()
            return codes[1] or "default"
        end
        return "default"
    end

    -- Normalise `tokens` when posted as a JSON string inside form-encoded body.
    local function normalise_tokens(raw)
        if raw == nil then return nil end
        if type(raw) == "table" then return raw end
        if type(raw) == "string" and raw ~= "" then
            local decoded = cjson.decode(raw)
            if type(decoded) == "table" then return decoded end
        end
        return raw
    end

    -- Resolve namespace identity from request even when auth is skipped (used
    -- by /active/styles.css so public pages can still pick up the right CSS).
    local function resolve_public_namespace(self)
        local ok_resolver, resolver = pcall(require, "middleware.namespace")
        if ok_resolver and resolver.resolveFromRequest then
            local ns = resolver.resolveFromRequest(self)
            if ns then return ns end
        end
        -- Fallback: header lookup
        local headers = ngx.req.get_headers() or {}
        local slug = headers["x-namespace-slug"] or self.params.namespace
        local id   = tonumber(headers["x-namespace-id"] or self.params.namespace_id)
        if id then
            local NamespaceQueries = pcall(require, "queries.NamespaceQueries") and require("queries.NamespaceQueries") or nil
            if NamespaceQueries and NamespaceQueries.getById then
                return NamespaceQueries.getById(id)
            end
        end
        if slug then
            local NamespaceQueries = pcall(require, "queries.NamespaceQueries") and require("queries.NamespaceQueries") or nil
            if NamespaceQueries and NamespaceQueries.getBySlug then
                return NamespaceQueries.getBySlug(slug)
            end
        end
        return nil
    end

    -- =========================================================================
    -- STATIC PATHS (must come before /:uuid)
    -- =========================================================================

    -- GET /api/v2/themes/schema — canonical token schema (drives editor UI)
    app:get("/api/v2/themes/schema", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "read", function(self)
            return api_ok(200, ThemeTokenSchema.getSchema())
        end)
    ))

    -- GET /api/v2/themes/presets — platform starter themes
    app:get("/api/v2/themes/presets", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "read", function(self)
            local project_code = resolve_project_code(self)
            local presets = ThemeQueries.listPresets(project_code)
            return api_ok(200, presets)
        end)
    ))

    -- GET /api/v2/themes/marketplace — public published themes
    app:get("/api/v2/themes/marketplace", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "read", function(self)
            local project_code = resolve_project_code(self)
            local result = ThemeQueries.listMarketplace(project_code, self.params)
            return api_ok(200, result.items, { meta = result.meta })
        end)
    ))

    -- GET /api/v2/themes/active — JSON view of the active theme
    app:get("/api/v2/themes/active", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "read", function(self)
            local project_code = resolve_project_code(self)
            local result = ThemeService.resolveActive(self.namespace.id, project_code)
            return respond(result, 200)
        end)
    ))

    -- GET /api/v2/themes/active/styles.css — rendered CSS (public, cached)
    -- Namespace resolved from request context without requiring JWT.
    app:get("/api/v2/themes/active/styles.css", function(self)
        local ns = resolve_public_namespace(self)
        local project_code
        if self.params and self.params.project_code and self.params.project_code ~= "" then
            project_code = self.params.project_code
        elseif ns and ns.default_project_code and ns.default_project_code ~= "" then
            project_code = ns.default_project_code
        else
            local ok_cfg, ProjectConfig = pcall(require, "helper.project-config")
            project_code = (ok_cfg and ProjectConfig.parseProjectCodes()[1]) or "default"
        end

        local namespace_id = ns and ns.id or nil
        local version = tonumber(self.params.v) or 0

        ngx.header["Content-Type"]  = "text/css; charset=utf-8"
        ngx.header["Cache-Control"] = "public, max-age=31536000, immutable"
        ngx.header["Vary"]          = "X-Namespace-Id, X-Namespace-Slug"

        -- Cache hit path
        local cached = ThemeCache.getCss(namespace_id, project_code, version)
        if cached then
            return { status = 200, layout = false, cached }
        end

        -- Miss: resolve + render + write-through
        local result = ThemeService.resolveActive(namespace_id, project_code)
        if not result.ok then
            return { status = 200, layout = false, "/* theme unavailable */" }
        end

        local theme = result.data and result.data.theme or nil
        local theme_uuid = theme and theme.uuid or nil
        local css = ThemeRenderer.render(result.data.resolved, { theme_uuid = theme_uuid })

        ThemeCache.setCss(namespace_id, project_code, version, css)
        return { status = 200, layout = false, css }
    end)

    -- =========================================================================
    -- COLLECTION
    -- =========================================================================

    -- GET /api/v2/themes — list themes visible to this namespace
    app:get("/api/v2/themes", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "read", function(self)
            local project_code = resolve_project_code(self)
            local result = ThemeQueries.list(self.namespace.id, project_code, self.params)
            return api_ok(200, result.items, { meta = result.meta })
        end)
    ))

    -- POST /api/v2/themes — create
    app:post("/api/v2/themes", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "create", function(self)
            local body = parse_body()
            local project_code = resolve_project_code(self, body)

            local input = {
                name              = body.name,
                slug              = body.slug,
                description       = body.description,
                parent_uuid       = body.parent_uuid,
                from_preset_slug  = body.from_preset_slug,
                tokens            = normalise_tokens(body.tokens),
                custom_css        = body.custom_css,
            }

            local user_id = self.current_user and self.current_user.id
            local result = ThemeService.create(self.namespace.id, project_code, user_id, input)
            return respond(result, 201)
        end)
    ))

    -- POST /api/v2/themes/install/:source_uuid — install public theme
    app:post("/api/v2/themes/install/:source_uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "create", function(self)
            local project_code = resolve_project_code(self)
            local user_id = self.current_user and self.current_user.id
            local result = ThemeService.install(self.namespace.id, project_code, user_id, self.params.source_uuid)
            return respond(result, 201)
        end)
    ))

    -- =========================================================================
    -- SINGLE-ITEM ROUTES
    -- =========================================================================

    -- GET /api/v2/themes/:uuid
    app:get("/api/v2/themes/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "read", function(self)
            local theme = ThemeQueries.getByUuid(self.params.uuid, self.namespace.id)
            if not theme then return api_err(404, "theme not found") end
            local tokens_row = ThemeQueries.getTokens(theme.id)
            return api_ok(200, {
                theme       = theme,
                tokens      = tokens_row and tokens_row.tokens or {},
                custom_css  = tokens_row and tokens_row.custom_css or "",
            })
        end)
    ))

    -- PUT /api/v2/themes/:uuid — update
    app:put("/api/v2/themes/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "update", function(self)
            local body = parse_body()
            local input = {
                name        = body.name,
                description = body.description,
                tokens      = normalise_tokens(body.tokens),
                custom_css  = body.custom_css,
                change_note = body.change_note,
            }
            local user_id = self.current_user and self.current_user.id
            local result = ThemeService.update(self.namespace.id, user_id, self.params.uuid, input)
            return respond(result, 200)
        end)
    ))

    -- DELETE /api/v2/themes/:uuid — soft delete
    app:delete("/api/v2/themes/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "delete", function(self)
            local project_code = resolve_project_code(self)
            local result = ThemeService.delete(self.namespace.id, project_code, self.params.uuid)
            return respond(result, 200)
        end)
    ))

    -- POST /api/v2/themes/:uuid/activate
    app:post("/api/v2/themes/:uuid/activate", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "activate", function(self)
            local project_code = resolve_project_code(self)
            local user_id = self.current_user and self.current_user.id
            local result = ThemeService.activate(self.namespace.id, project_code, user_id, self.params.uuid)
            return respond(result, 200)
        end)
    ))

    -- POST /api/v2/themes/:uuid/duplicate
    app:post("/api/v2/themes/:uuid/duplicate", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "create", function(self)
            local body = parse_body()
            local project_code = resolve_project_code(self, body)
            local user_id = self.current_user and self.current_user.id
            local result = ThemeService.duplicate(self.namespace.id, project_code, user_id, self.params.uuid, {
                name = body.name,
            })
            return respond(result, 201)
        end)
    ))

    -- POST /api/v2/themes/:uuid/revert
    app:post("/api/v2/themes/:uuid/revert", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "update", function(self)
            local body = parse_body()
            if not body.revision_uuid or body.revision_uuid == "" then
                return api_err(422, "revision_uuid is required")
            end
            local user_id = self.current_user and self.current_user.id
            local result = ThemeService.revert(self.namespace.id, user_id, self.params.uuid, body.revision_uuid)
            return respond(result, 200)
        end)
    ))

    -- GET /api/v2/themes/:uuid/revisions
    app:get("/api/v2/themes/:uuid/revisions", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "read", function(self)
            local theme = ThemeQueries.getByUuid(self.params.uuid, self.namespace.id)
            if not theme then return api_err(404, "theme not found") end
            local rows = ThemeRevisionQueries.list(theme.id, self.params)
            return api_ok(200, rows)
        end)
    ))

    -- GET /api/v2/themes/:uuid/preview.css
    -- Render a theme's CSS without committing. Editor uses this with a debounced
    -- fetch on every keystroke to refresh the live preview iframe.
    app:get("/api/v2/themes/:uuid/preview.css", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "read", function(self)
            local theme = ThemeQueries.getByUuid(self.params.uuid, self.namespace.id)
            if not theme then
                ngx.header["Content-Type"] = "text/css; charset=utf-8"
                return { status = 404, layout = false, "/* theme not found */" }
            end

            local ThemeResolver = require("lib.theme-resolver")
            local resolved = ThemeResolver.resolve(theme)
            local css = ThemeRenderer.render(resolved, { theme_uuid = theme.uuid })

            ngx.header["Content-Type"]  = "text/css; charset=utf-8"
            ngx.header["Cache-Control"] = "no-store"
            return { status = 200, layout = false, css }
        end)
    ))

    -- POST /api/v2/themes/:uuid/publish
    app:post("/api/v2/themes/:uuid/publish", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "publish", function(self)
            local user_id = self.current_user and self.current_user.id
            local result = ThemeService.publish(self.namespace.id, user_id, self.params.uuid)
            return respond(result, 200)
        end)
    ))

    -- POST /api/v2/themes/:uuid/unpublish
    app:post("/api/v2/themes/:uuid/unpublish", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requirePermission("themes", "publish", function(self)
            local user_id = self.current_user and self.current_user.id
            local result = ThemeService.unpublish(self.namespace.id, user_id, self.params.uuid)
            return respond(result, 200)
        end)
    ))
end
