-- Property Deals uses the core lead conversion (one path), keeps the lead's
-- property, and joins a lead that core Convert already made a deal for.
--   docker exec -w /app opsapi lapis exec "assert(loadfile('/app/spec/lead-pipeline-e2e/pd_check.lua'))()"
-- Needs setup.lua's workspace and the property-deals project mounted.
local db = require("lapis.db")
local Global = require("helper.global")

local out, failures = {}, 0
local function check(name, ok, detail)
    if ok then out[#out + 1] = "  ok   - " .. name
    else failures = failures + 1; out[#out + 1] = "  FAIL - " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or "") end
end

local ns = db.query("SELECT id FROM namespaces WHERE slug = 'lead-pipeline-test'")[1].id
local owner = db.query("SELECT uuid FROM users WHERE email = 'lp-owner@e2e.invalid'")[1].uuid
local rep1 = db.query("SELECT uuid FROM users WHERE email = 'lp-rep1@e2e.invalid'")[1].uuid

local ok_pd, Deals = pcall(require, "property_deals.deals")
if not ok_pd then print("  skip - property-deals not mounted: " .. tostring(Deals)); return end

local function lead(email)
    return db.insert("crm_leads", { uuid = Global.generateUUID(), namespace_id = ns, first_name = "Pd", last_name = "Check",
        email = email, status = "contacting", source = "website", owner_user_uuid = rep1, metadata = '{"pipeline_started":true}',
        score = 0, estimated_value = 250000, currency = "GBP", created_at = db.raw("NOW()"), updated_at = db.raw("NOW()") },
        { returning = "*" })[1]
end

-- Outside a request the plugin registry may not be loaded: fall back to defaults.
local ok_s, settings = pcall(require("helper.plugin-sdk").settings, "property_deals", ns)
if not ok_s or type(settings) ~= "table" then settings = {} end
local ok, err = pcall(function()
    -- A lead with a property on it.
    local prop = db.insert("property_deals_properties", { namespace_id = ns, address_line1 = "1 Check Street " .. os.time(),
        postcode = "SW1A 1AA" }, { returning = "*" })[1]
    local l1 = lead("pd1." .. os.time() .. "@e2e.invalid")
    db.insert("property_deals_lead_details", { namespace_id = ns, lead_uuid = l1.uuid, property_uuid = prop.uuid })
    local deal = Deals.create(ns, { lead_uuid = l1.uuid, deal_type = "buy" }, owner, settings)
    local crm = db.query("SELECT * FROM crm_deals WHERE uuid = ?", deal.crm_deal_uuid)[1]
    local l1b = db.query("SELECT * FROM crm_leads WHERE id = ?", l1.id)[1]
    local det = db.query("SELECT property_uuid FROM property_deals_lead_details WHERE lead_uuid = ?", l1.uuid)[1]
    check("property deal takes the lead's property", deal.property_uuid == prop.uuid, deal.property_uuid)
    check("the lead keeps its property (was wiped before)", det.property_uuid == prop.uuid, det.property_uuid)
    check("the deal links back to the lead", tonumber(crm.lead_id) == tonumber(l1.id), crm.lead_id)
    check("the lead is converted with history", l1b.status == "converted" and tonumber(l1b.converted_deal_id) == tonumber(crm.id))
    check("deal owner is the lead's owner (not who clicked)", crm.owner_user_uuid == rep1, crm.owner_user_uuid)
    check("history row for the conversion", #db.query("SELECT 1 FROM crm_lead_stage_history WHERE lead_id = ? AND to_status = 'converted'", l1.id) == 1)
    local again = pcall(Deals.create, ns, { lead_uuid = l1.uuid, deal_type = "buy" }, owner, settings)
    check("a second property deal for the same lead is refused", again == false)

    -- Converted by core first, then a property deal: one CRM deal, not two.
    local l2 = lead("pd2." .. os.time() .. "@e2e.invalid")
    local conv = assert(require("lib.crm.lead-convert").convert(ns, l2.uuid, rep1, {}))
    local before = tonumber(db.query("SELECT COUNT(*) AS n FROM crm_deals WHERE lead_id = ?", l2.id)[1].n)
    local deal2 = Deals.create(ns, { lead_uuid = l2.uuid, deal_type = "buy" }, owner, settings)
    local after = tonumber(db.query("SELECT COUNT(*) AS n FROM crm_deals WHERE lead_id = ?", l2.id)[1].n)
    check("joins the deal core Convert made (still one CRM deal)", before == 1 and after == 1 and deal2.crm_deal_uuid == conv.deal_uuid,
        before .. "/" .. after)
end)
if not ok then failures = failures + 1; out[#out + 1] = "  FAIL - raised: " .. require("cjson").encode(type(err) == "table" and err or { tostring(err) }) end
out[#out + 1] = failures == 0 and "all passed" or (failures .. " failed")
print(table.concat(out, "\n"))
