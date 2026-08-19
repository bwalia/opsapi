--[[
    Website revalidation notifier
    =============================
    When CMS blog content (a cms_post) is created / updated / soft-deleted in the
    workstation namespace, tell the workstation-website to refresh. Two delivery
    modes, chosen by env — so the same code serves the static site today and the
    ISR (K3S) site after the cutover:

      * "revalidate" (ISR)  — POST WEBSITE_REVALIDATE_URL/api/revalidate with the
        shared secret. The Next server busts the `cms-posts` cache tag and the
        next request re-fetches: content live in SECONDS, no rebuild.
        Selected when WEBSITE_REVALIDATE_URL + WEBSITE_REVALIDATE_SECRET are set.
      * "dispatch" (static) — fire a GitHub `repository_dispatch: content-updated`
        that rebuilds + re-syncs the S3 static site (minutes).
        Selected when WEBSITE_DISPATCH_TOKEN is set.

    revalidate mode wins when both are configured, so the cutover is just setting
    the two revalidate env vars — no code change.

    Guarantees (why each matters for a content-save path):
      * Non-blocking — the outbound call runs in an ngx.timer AFTER the response
        is sent, so a slow/down website never delays or fails saving a post.
      * Never throws — the whole scheduling path is pcall-wrapped; a bug here can
        never break a create/update/delete.
      * Coalesced — a burst of edits schedules a SINGLE call after a short
        debounce window. Uses the shared `cache` dict; degrades to one-timer-
        per-change if the dict is unavailable.
      * Opt-in per env — a no-op unless a mode is configured, so int / test
        opsapi stay silent and only the env that owns publishing fires.
      * Namespace-scoped — when WEBSITE_NAMESPACE_ID is set, only that namespace's
        posts fire, so other tenants' CMS activity is ignored. Unset = any.

    Env (must also be whitelisted in nginx.conf `env` directives):
      -- ISR mode --
      WEBSITE_REVALIDATE_URL         website base URL; /api/revalidate is appended.
      WEBSITE_REVALIDATE_SECRET      shared secret (sent as x-revalidate-secret).
      WEBSITE_REVALIDATE_SSL_VERIFY  "false" to skip TLS verify (internal/self-
                                     signed). Default verify on.
      -- static mode --
      WEBSITE_DISPATCH_TOKEN         GitHub PAT with contents:write on the repo.
      WEBSITE_REPO_OWNER             default "bwalia"
      WEBSITE_REPO_NAME              default "workstation-website"
      WEBSITE_DISPATCH_EVENT         default "content-updated"
      -- both --
      WEBSITE_NAMESPACE_ID           only this namespace's posts fire. Unset = any.
      WEBSITE_DISPATCH_DEBOUNCE      seconds to coalesce a burst, default 60.
]]

local GithubRepo = require("lib.github-repo")
local cjson = require("cjson")

local WebsiteRevalidate = {}

-- Only one call may be scheduled per debounce window; this key in the shared
-- `cache` dict is the guard (add() succeeds only when it is absent).
local SCHED_KEY = "website_revalidate:scheduled"

local function env(name, default)
    local v = os.getenv(name)
    if v == nil or v == "" then return default end
    return v
end

-- Returns the resolved config, or nil when the notifier is disabled.
-- revalidate (ISR) mode takes precedence over dispatch (static) mode.
local function resolve_config()
    local debounce = tonumber(env("WEBSITE_DISPATCH_DEBOUNCE", "60")) or 60
    local namespace_id = tonumber(env("WEBSITE_NAMESPACE_ID"))  -- nil = any namespace

    local revalidate_url = env("WEBSITE_REVALIDATE_URL")
    local revalidate_secret = env("WEBSITE_REVALIDATE_SECRET")
    if revalidate_url and revalidate_secret then
        return {
            mode = "revalidate",
            url = revalidate_url:gsub("/+$", "") .. "/api/revalidate",
            secret = revalidate_secret,
            ssl_verify = env("WEBSITE_REVALIDATE_SSL_VERIFY", "true") ~= "false",
            debounce = debounce,
            namespace_id = namespace_id,
        }
    end

    local token = env("WEBSITE_DISPATCH_TOKEN")
    if token then
        return {
            mode = "dispatch",
            token = token,
            owner = env("WEBSITE_REPO_OWNER", "bwalia"),
            repo = env("WEBSITE_REPO_NAME", "workstation-website"),
            event_type = env("WEBSITE_DISPATCH_EVENT", "content-updated"),
            debounce = debounce,
            namespace_id = namespace_id,
        }
    end

    return nil  -- neither mode configured -> disabled
end

-- POST the ISR revalidate webhook. Returns ok, err.
local function post_revalidate(cfg, reason)
    local ok_req, http = pcall(require, "resty.http")
    if not ok_req then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(10000)
    local res, err = httpc:request_uri(cfg.url, {
        method = "POST",
        headers = {
            ["x-revalidate-secret"] = cfg.secret,
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "opsapi-website-revalidate",
        },
        body = cjson.encode({ reason = reason, at = os.date("!%Y-%m-%dT%H:%M:%SZ") }),
        ssl_verify = cfg.ssl_verify,
    })
    if not res then return nil, "request failed: " .. tostring(err) end
    if res.status >= 200 and res.status < 300 then return true, nil end
    return nil, "HTTP " .. tostring(res.status)
end

-- ngx.timer callback: runs outside the request. Fires exactly one call and
-- clears the guard so the next window can schedule again.
local function fire(premature, cfg, reason)
    if premature then return end
    local dict = ngx.shared.cache
    if dict then dict:delete(SCHED_KEY) end

    if cfg.mode == "revalidate" then
        local ok, err = post_revalidate(cfg, reason)
        if ok then
            ngx.log(ngx.NOTICE, "website-revalidate: revalidated ", cfg.url, " (", tostring(reason), ")")
        else
            ngx.log(ngx.ERR, "website-revalidate: revalidate POST failed: ", tostring(err))
        end
    else
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
end

--- Schedule a coalesced website refresh. Safe to call on every content mutation:
--- never blocks, never throws, no-op when disabled, off-request, or the post is
--- in a namespace other than the configured website namespace.
-- @param reason string        e.g. "cms_post.created" — for logs / payload
-- @param namespace_id number  the mutated post's namespace (for scoping)
function WebsiteRevalidate.notify(reason, namespace_id)
    local ok, err = pcall(function()
        local cfg = resolve_config()
        if not cfg then return end                          -- disabled (no mode set)
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
