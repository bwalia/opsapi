local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local PatientAccessControlModel = Model:extend("patient_access_controls", {
    timestamp = true,
    relations = {
        { "patient", belongs_to = "PatientModel", key = "patient_id" }
    }
})

local JSON_FIELDS = { "scope", "data_categories", "ip_whitelist" }

function PatientAccessControlModel:getByPatient(patient_id)
    return self:select("WHERE patient_id = ? AND status = 'active' ORDER BY created_at DESC", patient_id)
end

function PatientAccessControlModel:getByGrantee(granted_to)
    return self:select(
        "WHERE granted_to = ? AND status = 'active' AND (expires_at IS NULL OR expires_at > NOW()) ORDER BY created_at DESC",
        granted_to
    )
end

function PatientAccessControlModel:getByShareToken(token)
    return self:select(
        "WHERE share_token = ? AND status = 'active' AND (token_expires_at IS NULL OR token_expires_at > NOW()) LIMIT 1",
        token
    )
end

function PatientAccessControlModel:getExpired()
    return self:select("WHERE status = 'active' AND expires_at IS NOT NULL AND expires_at <= NOW()")
end

function PatientAccessControlModel:revokeAccess(id, reason)
    local record = self:find(id)
    if not record then return nil end
    record:update({
        status = "revoked",
        revoked_at = Global.getCurrentTimestamp(),
        revoked_reason = reason,
        updated_at = Global.getCurrentTimestamp()
    })
    return record
end

function PatientAccessControlModel:checkAccess(patient_id, granted_to, scope_item)
    local accesses = self:select(
        "WHERE patient_id = ? AND granted_to = ? AND status = 'active' AND (expires_at IS NULL OR expires_at > NOW())",
        patient_id, granted_to
    )

    for _, access in ipairs(accesses) do
        if access.scope then
            local ok, scopes = pcall(cJson.decode, access.scope)
            if ok then
                for _, s in ipairs(scopes) do
                    if s == "all" or s == scope_item then
                        return access
                    end
                end
            end
        end
    end

    return nil
end

function PatientAccessControlModel:getWithParsedData(id)
    local record = self:find(id)
    if not record then return nil end

    for _, field in ipairs(JSON_FIELDS) do
        if record[field] then
            local ok, parsed = pcall(cJson.decode, record[field])
            if ok then record[field] = parsed end
        end
    end

    return record
end

return PatientAccessControlModel
