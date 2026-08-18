--[[
    Website revalidation notifier
    =============================
    When CMS blog content (a cms_post) is created / updated / soft-deleted in the
    workstation namespace, tell the workstation-website repo to rebuild + redeploy
    its static site by firing a GitHub `repository_dispatch: content-updated`
    event. That workflow re-fetches published posts from this API and re-syncs the
    live S3 root — the "revalidate" step for a statically-served site. See
    workstation-website/docs/architecture.md.

    Guarantees (why each matters for a content-save path):
      * Non-blocking — the GitHub call runs in an ngx.timer AFTER the response is
        sent, so a slow or down GitHub never delays or fails saving a post.
      * Never throws — the whole scheduling path is pcall-wrapped; a bug here can
        never break a create/update/delete.
      * Coalesced — a burst of edits schedules a SINGLE dispatch after a short
        debounce window (the rebuild re-fetches ALL content, so only the last
        change in a window matters). Uses the shared `cache` dict; degrades to
        one-timer-per-change if the dict is unavailable.
      * Opt-in per env — a no-op unless WEBSITE_DISPATCH_TOKEN is set, so int /
        test opsapi stay silent and only the env that owns publishing fires.
      * Namespace-scoped — when WEBSITE_NAMESPACE_ID is set, only that namespace's
        posts trigger a rebuild, so other tenants' CMS activity is ignored. Unset
        = fire for any namespace (single-tenant default).

    Env (must also be whitelisted in nginx.conf `env` directives):
      WEBSITE_DISPATCH_TOKEN     GitHub PAT with contents:write on the repo.
                                 Unset = notifier disabled.
      WEBSITE_NAMESPACE_ID       Only this namespace's posts fire a rebuild.
                                 Unset = any namespace.
      WEBSITE_REPO_OWNER         default "bwalia"
      WEBSITE_REPO_NAME          default "workstation-website"
      WEBSITE_DISPATCH_EVENT     default "content-updated"
      WEBSITE_DISPATCH_DEBOUNCE  seconds to coalesce a burst, default 60
]]

local GithubRepo = require("lib.github-repo")

local WebsiteRevalidate = {}

-- Only one dispatch may be scheduled per debounce window; this key in the shared
-- `cache` dict is the guard (add() succeeds only when it is absent).
local SCHED_KEY = "website_revalidate:scheduled"

local function env(name, default)
    local v = os.getenv(name)
    if v == nil or v == "" then return default end
    return v
end

-- Returns the resolved config, or nil when the notifier is disabled (no token).
local function resolve_config()
    local token = env("WEBSITE_DISPATCH_TOKEN")
    if not token then return nil end
    return {
        token = token,
        owner = env("WEBSITE_REPO_OWNER", "bwalia"),
        repo = env("WEBSITE_REPO_NAME", "workstation-website"),
        event_type = env("WEBSITE_DISPATCH_EVENT", "content-updated"),
        debounce = tonumber(env("WEBSITE_DISPATCH_DEBOUNCE", "60")) or 60,
        namespace_id = tonumber(env("WEBSITE_NAMESPACE_ID")),  -- nil = any namespace
    }
end

-- ngx.timer callback: runs outside the request. Fires exactly one dispatch and
-- clears the guard so the next window can schedule again.
local function fire(premature, cfg, reason)
    if premature then return end
    local dict = ngx.shared.cache
    if dict then dict:delete(SCHED_KEY) end
    local ok, err = GithubRepo.repository_dispatch({
        token = cfg.token,
        owner = cfg.owner,
        repo = cfg.repo,
        event_type = cfg.event_type,
        client_payload = { reason = reason, at = os.date("!%Y-%m-%dT%H:%M:%SZ") },
    })
    if ok then
        ngx.log(ngx.NOTICE, "website-revalidate: dispatched '", cfg.event_type,
            "' to ", cfg.owner, "/", cfg.repo, " (", tostring(reason), ")")
    else
        ngx.log(ngx.ERR, "website-revalidate: dispatch failed: ", tostring(err))
    end
end

--- Schedule a coalesced site rebuild. Safe to call on every content mutation:
--- never blocks, never throws, no-op when disabled, off-request, or the post is
--- in a namespace other than the configured website namespace.
-- @param reason string        e.g. "cms_post.created" — for logs / client_payload
-- @param namespace_id number  the mutated post's namespace (for scoping)
function WebsiteRevalidate.notify(reason, namespace_id)
    local ok, err = pcall(function()
        local cfg = resolve_config()
        if not cfg then return end                          -- disabled (no token)
        -- Namespace gate: when configured, ignore other tenants' posts.
        if cfg.namespace_id and tonumber(namespace_id) ~= cfg.namespace_id then return end
        if not (ngx and ngx.timer and ngx.timer.at) then return end  -- off-request

        local dict = ngx.shared.cache
        if dict then
            -- First change in the window schedules the timer; the rest fold into
            -- it. add() succeeds only while the key is absent; the TTL is a
            -- safety net in case the timer never runs.
            local added = dict:add(SCHED_KEY, 1, cfg.debounce + 30)
            if not added then return end
        end

        local scheduled, terr = ngx.timer.at(cfg.debounce, fire, cfg, reason)
        if not scheduled then
            if dict then dict:delete(SCHED_KEY) end          -- let a later change retry
            ngx.log(ngx.ERR, "website-revalidate: could not schedule timer: ", tostring(terr))
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "website-revalidate: notify error: ", tostring(err))
    end
end

return WebsiteRevalidate
