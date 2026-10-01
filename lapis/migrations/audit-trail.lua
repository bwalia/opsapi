--[[
    Audit trail of business-record changes (helper/plugin-events.lua)
    ==================================================================
    [1] Event schema + the "core.audit" subscriptions + table triggers.
        (Also re-synced on every `lapis migrate` by ProjectMigrator.migrateAll,
        so OPSAPI_AUDIT_ENABLED changes take effect on the next deploy.)
    [2] Deleting a user also removes them from the audit trail: actor and IP
        are cleared, the record changes themselves stay (business history).
        Replaces the function from migrations/user-activity.lua [5].

    Gated on FEATURES.CORE: every deployment gets it.
]]

local db = require("lapis.db")

return {
    [1] = function()
        local PluginEvents = require("helper.plugin-events")
        PluginEvents.ensureSchema()
        PluginEvents.syncAudit()
        PluginEvents.syncTriggers()
    end,

    [2] = function()
        db.query([[
            CREATE OR REPLACE FUNCTION opsapi_forget_user_activity() RETURNS trigger LANGUAGE plpgsql AS $fn$
            BEGIN
                DELETE FROM user_activity WHERE user_uuid = OLD.uuid;
                DELETE FROM user_activity_daily WHERE user_uuid = OLD.uuid;
                DELETE FROM auth_events WHERE user_uuid = OLD.uuid;
                UPDATE audit_events
                SET actor_user_uuid = NULL, actor_ip = NULL,
                    metadata = COALESCE(metadata, '{}'::jsonb) - 'request_id' || '{"actor_erased": true}'::jsonb
                WHERE actor_user_uuid = OLD.uuid;
                RETURN NULL;
            END
            $fn$
        ]])
    end,
}
