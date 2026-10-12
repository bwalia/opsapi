-- Consent for the people the PA works with (PRD §6 Person: consent_basis, opted_out_at). Kept in pa_consent, one
-- row per person, rather than on crm_contacts. Set by a person (PUT /people/:id/consent) or from GoHighLevel (its
-- DND flag, and a consent_basis the webhook sends). An opt-out is never cleared by an integration, only by a person.
-- The PA never proposes contacting someone who opted out: such next actions are refused, and Today says don't.
local db = require("lapis.db")
local U = require("property_deals.util")

local K = {}

K.BASES = { "consent", "contract", "legitimate_interests", "legal_obligation" } -- as Property Deals' leads

local function valid_basis(v)
    for _, b in ipairs(K.BASES) do if v == b then return v end end
    return nil
end

--- d = { consent_basis?, opted_out? (true / false / nil = unchanged), source }. false only from a person.
function K.set(ns, person_uuid, d)
    local basis = valid_basis(d.consent_basis)
    if not basis and d.opted_out == nil then return end
    db.query([[
        INSERT INTO pa_consent (namespace_id, person_uuid, consent_basis, opted_out_at, source)
        VALUES (?, ?, ?, CASE WHEN ? THEN NOW() END, ?)
        ON CONFLICT (namespace_id, person_uuid) DO UPDATE SET
            consent_basis = COALESCE(EXCLUDED.consent_basis, pa_consent.consent_basis),
            opted_out_at = CASE WHEN ?::boolean IS NULL THEN pa_consent.opted_out_at
                                WHEN ? THEN COALESCE(pa_consent.opted_out_at, NOW()) END,
            source = EXCLUDED.source, updated_at = NOW()
    ]], ns, person_uuid, basis or db.NULL, d.opted_out == true, d.source or "human",
        d.opted_out == nil and db.NULL or d.opted_out, d.opted_out == true)
end

--- { consent_basis, opted_out_at } for a person (empty when nothing is recorded).
function K.get(ns, person_uuid)
    return U.one("SELECT consent_basis, opted_out_at FROM pa_consent WHERE namespace_id = ? AND person_uuid = ?",
        ns, person_uuid) or {}
end

--- Refuse a proposed contact with the person behind an opportunity who opted out. @return nil | message
function K.refusal(ns, opportunity_uuid)
    if not U.is_uuid(opportunity_uuid) then return nil end
    local r = U.one([[SELECT c.first_name FROM pa_opportunities o JOIN pa_consent k ON k.namespace_id = o.namespace_id
        AND k.person_uuid = o.person_uuid AND k.opted_out_at IS NOT NULL LEFT JOIN crm_contacts c ON c.uuid = o.person_uuid
        WHERE o.namespace_id = ? AND o.uuid = ?::uuid]], ns, opportunity_uuid)
    if not r then return nil end
    return (r.first_name ~= db.NULL and r.first_name or "This person") .. " asked not to be contacted"
end

return K
