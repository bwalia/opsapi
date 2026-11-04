--[[
    Convert a lead to a deal: one action, nothing lost (plan §4.6)
    ==============================================================

    In one transaction:
      * account   the lead's company: an existing account with that name, else a new one
      * contact   an existing contact with the lead's email, else a new one (in the account)
      * deal      value from the lead (a person's value, else the AI's estimate), its
                  currency, expected close date, owner = the lead's owner, the
                  workspace's default pipeline and its first stage, linked back
                  to the lead (crm_deals.lead_id)
      * history   the lead's calls and meetings move onto the deal and contact;
                  its referrals follow the deal; notes, source and the AI summary
                  are kept on the deal
      * the lead  becomes `converted` (read-only), with history

    Plugins add their own record from the crm.lead.converted event (the outbox
    fires it from the status change), e.g. Property Deals' deal details.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local U = require("lib.crm.util")
local Settings = require("lib.crm.lead-settings")

local C = {}

C.DEFAULT_STAGES = { "prospecting", "qualification", "proposal", "negotiation", "closed_won", "closed_lost" }
C.STAGE_PROBABILITY = { prospecting = 10, qualification = 25, proposal = 50, negotiation = 75, closed_won = 100,
    closed_lost = 0, won = 100, lost = 0 }

--- The workspace's default pipeline (creates "Sales pipeline" the first time).
function C.default_pipeline(ns, actor)
    local p = U.one([[SELECT * FROM crm_pipelines WHERE namespace_id = ? AND deleted_at IS NULL
        ORDER BY is_default DESC, created_at ASC LIMIT 1]], ns)
    if p then return p end
    return db.query([[
        INSERT INTO crm_pipelines (uuid, namespace_id, name, description, stages, is_default, created_at, updated_at)
        VALUES (?, ?, 'Sales pipeline', 'Created for leads converted to deals', ?::jsonb, TRUE, NOW(), NOW())
        RETURNING *
    ]], require("helper.global").generateUUID(), ns, cjson.encode(C.DEFAULT_STAGES))[1]
end

local function first_stage(pipeline)
    local stages = U.json(pipeline.stages, {})
    local s = stages[1]
    if type(s) == "table" then s = s.key or s.name end
    return type(s) == "string" and s or "prospecting"
end

--- @param o { name?, value?, currency?, pipeline_uuid?, stage?, expected_close_date?, owner_user_uuid? }
-- @return { lead_uuid, contact_uuid, account_uuid?, deal_uuid } | nil, err
function C.convert(ns, uuid, actor, o)
    if not U.crm() then return U.fail(409, "LEAD_CRM_OFF", "Converting needs the CRM module in this deployment") end
    o = type(o) == "table" and o or {}
    local settings = Settings.get(ns)
    local value = o.value ~= nil and o.value ~= cjson.null and U.money(o.value) or nil
    if o.value ~= nil and o.value ~= cjson.null and o.value ~= "" and not value then
        return U.fail(422, "CONVERT_VALUE", "The deal value must be a positive amount", { value = "amount" })
    end
    local currency = U.nz(o.currency) and tostring(o.currency):upper() or nil
    if currency and not currency:match("^%u%u%u$") then
        return U.fail(422, "CONVERT_CURRENCY", "Use a 3-letter currency code", { currency = "e.g. GBP" })
    end
    local close = U.nz(o.expected_close_date) and U.date(o.expected_close_date) or nil
    if U.nz(o.expected_close_date) and not close then
        return U.fail(422, "CONVERT_CLOSE", "Expected close must be a date", { expected_close_date = "YYYY-MM-DD" })
    end
    local Global = require("helper.global")
    local Pipeline = require("lib.crm.lead-pipeline")
    return U.tx(function()
        local lead = Pipeline.find(ns, uuid, { lock = true })
        if not lead then return U.fail(404, "LEAD_NOT_FOUND", "Lead not found") end
        if lead.status == "converted" then return U.fail(409, "LEAD_CONVERTED", "This lead is already converted") end

        local owner = U.nz(o.owner_user_uuid) or U.nz(lead.owner_user_uuid) or actor
        if not owner then return U.fail(422, "CONVERT_OWNER", "Give the lead an owner first", { owner_user_uuid = "required" }) end

        -- Account (company)
        local account
        local company = U.nz(lead.company_name)
        if company then
            account = U.one([[SELECT * FROM crm_accounts WHERE namespace_id = ? AND lower(name) = lower(?) AND deleted_at IS NULL
                ORDER BY created_at LIMIT 1]], ns, company)
            if not account then
                account = db.query([[
                    INSERT INTO crm_accounts (uuid, namespace_id, name, email, phone, owner_user_uuid, status, metadata,
                        created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'active', ?::jsonb, NOW(), NOW()) RETURNING *
                ]], Global.generateUUID(), ns, company, db.NULL, db.NULL, owner, U.enc({ from_lead = lead.uuid }))[1]
            end
        end

        -- Contact (person): reuse by email
        local contact = not U.null(lead.converted_contact_id)
            and U.one("SELECT * FROM crm_contacts WHERE id = ? AND namespace_id = ?", lead.converted_contact_id, ns) or nil
        if not contact and U.nz(lead.email) then
            contact = U.one([[SELECT * FROM crm_contacts WHERE namespace_id = ? AND lower(email) = lower(?) AND deleted_at IS NULL
                ORDER BY created_at LIMIT 1]], ns, lead.email)
        end
        if not contact then
            local meta = U.json(lead.metadata, {})
            meta.from_lead = lead.uuid
            contact = db.query([[
                INSERT INTO crm_contacts (uuid, namespace_id, account_id, first_name, last_name, email, phone, job_title,
                    owner_user_uuid, status, metadata, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?::jsonb, NOW(), NOW()) RETURNING *
            ]], Global.generateUUID(), ns, account and account.id or db.NULL,
                U.nz(lead.first_name) or U.nz(lead.email) or "Contact", U.nz(lead.last_name) or db.NULL,
                U.nz(lead.email) or db.NULL, U.nz(lead.phone) or db.NULL, U.nz(lead.job_title) or db.NULL, owner, U.enc(meta))[1]
        elseif account and U.null(contact.account_id) then
            db.query("UPDATE crm_contacts SET account_id = ?, updated_at = NOW() WHERE id = ?", account.id, contact.id)
        end

        -- Deal
        local pipeline
        if U.nz(o.pipeline_uuid) then
            pipeline = U.one("SELECT * FROM crm_pipelines WHERE namespace_id = ? AND uuid = ? AND deleted_at IS NULL", ns, o.pipeline_uuid)
            if not pipeline then return U.fail(422, "CONVERT_PIPELINE", "Pipeline not found", { pipeline_uuid = "not found" }) end
        else
            pipeline = C.default_pipeline(ns, actor)
        end
        local stage = U.text(o.stage, 60) or first_stage(pipeline)
        local analysis = U.one([[SELECT result FROM crm_lead_analyses WHERE lead_id = ? AND status = 'done'
            ORDER BY created_at DESC LIMIT 1]], lead.id)
        local ai = analysis and U.json(analysis.result, {}) or {}
        local name = U.text(o.name, 200)
            or table.concat({ company or U.full_name(lead.first_name, lead.last_name) or "New deal",
                U.nz(ai.wants) and (" — " .. tostring(ai.wants):sub(1, 80)) or "" })
        local deal_value = value or tonumber(lead.estimated_value) or 0
        local deal = db.query([[
            INSERT INTO crm_deals (uuid, namespace_id, pipeline_id, account_id, contact_id, lead_id, name, value, currency,
                stage, probability, expected_close_date, owner_user_uuid, status, metadata, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?::jsonb, NOW(), NOW()) RETURNING *
        ]], Global.generateUUID(), ns, pipeline.id, account and account.id or db.NULL, contact.id, lead.id, name, deal_value,
            currency or U.nz(lead.currency) or settings.currency, stage, C.STAGE_PROBABILITY[stage] or 10,
            close or (not U.null(lead.expected_close_date) and lead.expected_close_date) or db.NULL, owner,
            U.enc({ from_lead = lead.uuid, source = U.nz(lead.source), lead_notes = U.nz(lead.notes),
                ai_summary = U.nz(lead.ai_summary), value_from = U.json(lead.metadata, {}).value_from,
                qualification = U.json(lead.qualification, {}) }))[1]

        -- The lead's calls and meetings now belong to the deal and the contact too.
        db.query([[UPDATE crm_activities SET deal_id = ?, contact_id = ?, account_id = COALESCE(account_id, ?), updated_at = NOW()
            WHERE lead_id = ? AND deleted_at IS NULL]], deal.id, contact.id, account and account.id or db.NULL, lead.id)
        if U.has_table("crm_deal_referrals") then
            db.query("UPDATE crm_deal_referrals SET deal_id = ?, updated_at = NOW() WHERE lead_id = ? AND deal_id IS NULL",
                deal.id, lead.id)
        end

        db.update("crm_leads", {
            status = "converted", converted_at = db.raw("NOW()"), converted_contact_id = contact.id,
            converted_deal_id = deal.id, stage_changed_at = db.raw("NOW()"), owner_user_uuid = owner,
            next_action_type = db.NULL, next_action_at = db.NULL, next_action_note = db.NULL, updated_at = db.raw("NOW()"),
        }, { id = lead.id })
        db.query([[INSERT INTO crm_lead_stage_history (namespace_id, lead_id, from_status, to_status, changed_by_uuid, reason)
            VALUES (?, ?, ?, 'converted', ?, ?)]], ns, lead.id, lead.status, actor or db.NULL, "converted to deal " .. deal.uuid)
        -- Planned calls on a converted lead now belong to the deal; nothing more is due on the lead itself.
        return { lead_uuid = lead.uuid, contact_uuid = contact.uuid, account_uuid = account and account.uuid or cjson.null,
            deal_uuid = deal.uuid, deal_name = deal.name, deal_value = tonumber(deal.value), currency = deal.currency,
            pipeline_uuid = pipeline.uuid, stage = deal.stage }
    end)
end

return C
