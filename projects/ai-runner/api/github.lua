-- GitHub for the built-in runner (docs/AI_RUNNER.md §28.3): the platform's GitHub App, installed by a workspace on
-- the repositories it chooses. Connecting an installation proves, through GitHub sign-in, that the person can reach
-- it, so nobody attaches someone else's installation by guessing its number.
--   GET    /github                                ai_runs.create or ai_runners.manage: { configured, can_manage,
--                                                 install_url (managers), installations }
--   POST   /github/authorize { installation_id }  ai_runners.manage -> { url }: GitHub sign-in, which comes back
--                                                 to the dashboard's /dashboard/ai-runner/github with a code
--   POST   /github/installations { code, state }  ai_runners.manage -> 201 the installation, connected
--   DELETE /github/installations/:uuid            ai_runners.manage
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local db = require("lapis.db")
local sdk = require("helper.plugin-sdk")
local U = require("ai_runner.util")
local R = require("ai_runner.runs")
local B = require("ai_runner.builtin")
local G = require("ai_runner.github")

local function body(self)
    local b, err = sdk.body(self)
    if not b then U.fail(400, err) end
    return b
end

local function configured()
    local c = G.config()
    if not c.configured then
        U.fail(409, "GitHub isn't set up on this server yet: a platform admin adds the GitHub App under AI Runs "
            .. "platform settings")
    end
    return c
end

-- Where GitHub sends the person back: the dashboard page that finishes the connection (the App's callback URL).
local function redirect_uri()
    local base = R.platform().dashboard_url
    if base == "" then base = R.frontend_url() end
    return base .. "/dashboard/ai-runner/github"
end

local function view(i)
    return { uuid = i.uuid, installation_id = tonumber(i.installation_id), account_login = U.null(i.account_login),
        account_type = U.null(i.account_type), repository_selection = U.null(i.repository_selection),
        created_by = U.null(i.created_by), created_by_name = U.null(i.created_by_name), created_at = i.created_at }
end

return function(app)
    app:get("/github", sdk.handler({}, U.guard(function(self)
        local manage = sdk.can(self, "ai_runners", "manage")
        if not manage and not sdk.can(self, "ai_runs", "create") then return sdk.error(403, "Permission denied") end
        local c = G.config()
        local rows = db.query("SELECT i.*, " .. R.name_sql("u") .. [[ AS created_by_name
            FROM ar_github_installations i LEFT JOIN users u ON u.uuid = i.created_by
            WHERE i.namespace_id = ? ORDER BY lower(i.account_login), i.id]], sdk.namespace_id(self))
        for k, i in ipairs(rows) do rows[k] = view(i) end
        return sdk.ok({ configured = c.configured, can_manage = manage, installations = U.array(rows),
            install_url = U.null(manage and c.configured and (c.web_url .. "/apps/" .. c.app_slug
                .. "/installations/new") or nil),
            web_url = c.web_url })
    end)))

    app:post("/github/authorize", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local c = configured()
        local id = tonumber(body(self).installation_id)
        if not id or id < 1 or id ~= math.floor(id) or id > 1e15 then
            U.invalid({ installation_id = "must be the installation id GitHub gave" })
        end
        local state = G.sign_state({ ns = sdk.namespace_id(self), user = sdk.user(self).uuid, installation_id = id })
        return sdk.ok({ url = G.authorize_url(c, state, redirect_uri()) })
    end)))

    app:post("/github/installations", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local c = configured()
        local ns = sdk.namespace_id(self)
        local d, errors = sdk.validate(body(self), { code = { required = true, max = 200 },
            state = { required = true, max = 2000 } })
        if not d then U.invalid(errors) end
        local st = G.read_state(d.state)
        -- The state names this workspace and this person: a link someone else started can't be finished here.
        if not st or st.ns ~= ns or st.user ~= sdk.user(self).uuid then
            return sdk.error(400, "This GitHub sign-in expired or was started elsewhere; connect again")
        end
        local inst, err = G.verify_installation(c, d.code, redirect_uri(), st.installation_id)
        if not inst then return sdk.error(403, "GitHub didn't confirm the installation: " .. tostring(err)) end
        local row = U.one([[
            INSERT INTO ar_github_installations (namespace_id, installation_id, account_login, account_type,
                repository_selection, created_by)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (namespace_id, installation_id) DO UPDATE SET account_login = EXCLUDED.account_login,
                account_type = EXCLUDED.account_type, repository_selection = EXCLUDED.repository_selection,
                updated_at = NOW()
            RETURNING *
        ]], ns, inst.installation_id, U.clean(tostring(inst.account_login or ""), 255),
            U.clean(tostring(inst.account_type or ""), 40), U.clean(tostring(inst.repository_selection or ""), 20),
            sdk.user(self).uuid)
        B.refresh(ns, true)
        return sdk.created(view(row))
    end)))

    app:delete("/github/installations/:uuid", sdk.handler({ permission = "ai_runners.manage" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        if not U.is_uuid(self.params.uuid) then return sdk.not_found("Installation") end
        local row = U.one("DELETE FROM ar_github_installations WHERE uuid = ? AND namespace_id = ? RETURNING uuid",
            self.params.uuid, ns)
        if not row then return sdk.not_found("Installation") end
        B.refresh(ns, true)
        return sdk.ok({ uuid = row.uuid, removed = true })
    end)))
end
