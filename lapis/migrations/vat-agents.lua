--[[
    Accountants acting for clients (VAT plan phase 8).
    1. vat_agents         — an accountant's Agent Reference Number (ARN), per person.
    2. vat_agent_clients  — an accountant's request to act for a client's VAT
       registration (same namespace): HMRC invitation, the link the client opens to
       accept, and status. Access is granted only when HMRC's relationship check says
       the agent is authorised (status 'active').
    Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_agents (
                id SERIAL PRIMARY KEY,
                namespace_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                arn VARCHAR(20) NOT NULL,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, user_id)
            )
        ]])
    end,
    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_agent_clients (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                namespace_id INTEGER NOT NULL,
                agent_user_id INTEGER NOT NULL,
                arn VARCHAR(20) NOT NULL,
                registration_id INTEGER NOT NULL,
                client_vrn VARCHAR(9) NOT NULL,
                known_fact DATE NOT NULL,
                invitation_id VARCHAR(40),
                client_action_url TEXT,
                status VARCHAR(20) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'accepted', 'active', 'rejected', 'expired', 'cancelled', 'revoked')),
                expires_on TIMESTAMP,
                last_checked_at TIMESTAMP,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS uq_vat_agent_clients_live
            ON vat_agent_clients (agent_user_id, registration_id) WHERE status IN ('pending', 'accepted', 'active')]])
    end,
    [3] = function()
        -- Tax -> VAT clients, for accountants (module vat_agent). Skips without a Tax menu.
        local ok = db.query("SELECT to_regclass('public.menu_items') IS NOT NULL AS ok")[1]
        if not (ok and (ok.ok == true or ok.ok == "t")) then return end
        local parent = db.select("id FROM menu_items WHERE key = ? LIMIT 1", "tax")
        if not parent[1] or #db.select("id FROM menu_items WHERE key = ?", "tax_vat_clients") > 0 then return end
        local MigrationUtils = require("helper.migration-utils")
        local ts = MigrationUtils.getCurrentTimestamp()
        db.insert("menu_items", {
            uuid = MigrationUtils.generateUUID(), key = "tax_vat_clients", name = "VAT clients", icon = "Users",
            path = "/dashboard/tax/vat/clients", module = "vat_agent", required_action = "read", priority = 37,
            parent_id = parent[1].id, is_active = true, is_admin_only = false, always_show = false,
            settings = "{}", created_at = ts, updated_at = ts,
        })
    end,
}
