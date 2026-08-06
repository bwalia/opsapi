--[[
    Domain → WSL Proxy fields
    =========================

    Adds the metadata a domain needs to be rendered as a WSL Proxy vhost
    (server) file for a consumer repo (e.g. diy-tax-return-uk's
    .github/wslproxy/data/servers/<env>/host:<domain>.json).

    See helper/wslproxy-server.lua for the renderer and routes/domains.lua
    (sync-to-repo) for the commit path. Gated on FEATURES.SERVICES.

    Idempotent: ADD COLUMN IF NOT EXISTS.
]]

local db = require("lapis.db")

local function add_column(sql)
    pcall(function() db.query(sql) end)
end

return {
    [1] = function()
        -- to_regclass guards against running before the domains table exists.
        local exists = db.query("SELECT to_regclass('public.domains') IS NOT NULL AS ok")
        if not (exists and exists[1] and exists[1].ok) then return end

        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS environment TEXT DEFAULT 'prod']])
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS wslproxy_rule_id TEXT]])
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS ssl_email TEXT]])
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS ssl_enabled BOOLEAN DEFAULT TRUE]])
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS ssl_auto_renew BOOLEAN DEFAULT TRUE]])
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS ssl_force_https BOOLEAN DEFAULT TRUE]])
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS ssl_staging BOOLEAN DEFAULT FALSE]])
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS wslproxy_root TEXT DEFAULT '/var/www/html']])
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS listen_ports TEXT DEFAULT '80']])
        -- CNAME target used by the DNS reconcile (e.g. pop1.diytaxreturn.co.uk).
        add_column([[ALTER TABLE domains ADD COLUMN IF NOT EXISTS proxy_target TEXT]])
        -- Index by environment for per-env export.
        add_column([[CREATE INDEX IF NOT EXISTS domains_namespace_env_idx ON domains (namespace_id, environment)]])
    end,
}
