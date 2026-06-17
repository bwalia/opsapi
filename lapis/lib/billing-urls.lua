--[[
    Billing URL helpers — server-controlled redirects
    ==================================================

    Shared by the Connect and Checkout flows. Centralises the two pieces of the
    secure-redirect model so neither flow trusts client-supplied URLs:

      opsapi_base()   our own public base, used to build the Stripe callback
                      URLs (return/refresh/success/cancel). Prefer the
                      configured OPSAPI_PUBLIC_URL; derive from the request only
                      as a dev fallback.

      dashboard_url() a SAFE final redirect for a namespace — the ORIGIN comes
                      from the namespace's allow-list (or FRONTEND_URL), never
                      from raw input; the path is server-controlled.
]]

local Global = require("helper.global")
local NamespaceQueries = require("queries.NamespaceQueries")

local M = {}

function M.opsapi_base()
    local base = Global.getEnvVar("OPSAPI_PUBLIC_URL")
    if base and base ~= "" then return (base:gsub("/+$", "")) end
    local scheme = ngx.var.http_x_forwarded_proto or ngx.var.scheme or "https"
    local host = ngx.var.http_x_forwarded_host or ngx.var.http_host or ngx.var.host
    if not host or host == "" then return nil end
    local prefix = ngx.var.http_x_forwarded_prefix
    if prefix and prefix ~= "" then
        prefix = "/" .. prefix:gsub("^/+", ""):gsub("/+$", "")
    else
        prefix = ""
    end
    return scheme .. "://" .. host .. prefix
end

-- Resolve a safe dashboard URL for `namespace_id`.
--   path_env_key  env var that can override the path (e.g. BILLING_DASHBOARD_PATH)
--   default_path  fallback path (e.g. "/settings/billing")
--   query         optional table of query params to append
-- Returns the URL, or nil if no origin is known for the namespace.
function M.dashboard_url(namespace_id, path_env_key, default_path, query)
    local origin
    local origins = NamespaceQueries.getAllowedRedirectOrigins(namespace_id)
    if origins and #origins > 0 then origin = origins[1] end
    if not origin or origin == "" then
        local fe = Global.getEnvVar("FRONTEND_URL")
        if fe and fe ~= "" then origin = fe end
    end
    if not origin or origin == "" then return nil end
    origin = origin:gsub("/+$", "")

    local path = (path_env_key and Global.getEnvVar(path_env_key)) or default_path
    if path:sub(1, 1) ~= "/" then path = "/" .. path end

    local qs = ""
    if query then
        local parts = {}
        for k, v in pairs(query) do
            parts[#parts + 1] = ngx.escape_uri(k) .. "=" .. ngx.escape_uri(tostring(v))
        end
        if #parts > 0 then qs = "?" .. table.concat(parts, "&") end
    end
    return origin .. path .. qs
end

return M
