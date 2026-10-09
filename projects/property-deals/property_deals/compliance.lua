-- Compliance expiry (SPEC §3.4, run daily by jobs/compliance_expiry.lua).
local cjson = require("cjson")
local db = require("lapis.db")
local Notify = require("property_deals.notify")

local C = {}

--- Expire what has run out and warn about what will soon.
-- @return { expired, warned, pof_expired }
function C.expire(ns, settings)
    local sdk = require("helper.plugin-sdk")
    local E = require("property_deals.engine")
    local within = tonumber(settings and settings.expiring_within_days) or 14
    local out = { expired = 0, warned = 0, pof_expired = 0 }

    -- Passed checks past their date -> expired (stays signed by whoever passed it).
    for _, c in ipairs(db.query([[
        UPDATE property_deals_compliance_checks SET status = 'expired', updated_at = NOW()
        WHERE namespace_id = ? AND status = 'passed' AND expires_at IS NOT NULL AND expires_at < NOW()
        RETURNING uuid, check_type, deal_uuid
    ]], ns)) do
        out.expired = out.expired + 1
        sdk.emit(ns, "property_deals.compliance_check.expired", { uuid = c.uuid, check_type = c.check_type, deal_uuid = c.deal_uuid })
    end

    -- Expiring soon: warn once per check.
    local to = E.members_with_role(ns, "pd_compliance")
    if #to == 0 then to = E.managers(ns) end
    for _, c in ipairs(db.query([[
        UPDATE property_deals_compliance_checks
        SET data = data || jsonb_build_object('expiry_warned_at', NOW()), updated_at = NOW()
        WHERE namespace_id = ? AND status = 'passed' AND expires_at IS NOT NULL
          AND expires_at < NOW() + make_interval(days => ?) AND data->>'expiry_warned_at' IS NULL
        RETURNING uuid, check_type, deal_uuid, expires_at
    ]], ns, within)) do
        out.warned = out.warned + 1
        sdk.emit(ns, "property_deals.compliance_check.expiring", {
            uuid = c.uuid, check_type = c.check_type, deal_uuid = c.deal_uuid, expires_at = c.expires_at,
        })
        Notify.send(ns, to, { kind = "compliance_expiring", event = "property_deals.compliance_check.expiring",
            route = "deal", uuid = c.deal_uuid or c.uuid, deal_uuid = c.deal_uuid,
            title = "Compliance expiring", body = c.check_type .. " expires " .. tostring(c.expires_at):sub(1, 10) })
    end

    -- Buyer proof of funds past its date.
    local r = db.query([[
        UPDATE property_deals_buyer_profiles SET pof_status = 'expired', updated_at = NOW()
        WHERE namespace_id = ? AND pof_status IN ('received', 'verified') AND pof_expires_on < CURRENT_DATE
    ]], ns)
    out.pof_expired = r.affected_rows or 0
    if out.expired + out.warned + out.pof_expired > 0 then
        ngx.log(ngx.NOTICE, "[property_deals] compliance expiry ns=", ns, " ", cjson.encode(out))
    end
    return out
end

return C
