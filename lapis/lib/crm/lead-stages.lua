--[[
    Lead stages (docs/plans/LEAD_TO_CASH_PIPELINE.md §4)
    ====================================================

    The stage IS crm_leads.status. The set is fixed so reports and automation
    can rely on it; a workspace renames the labels (settings.stage_labels).

        new -> contacting -> qualified -> meeting -> converted
        any open stage -> nurture | lost;  nurture | lost -> back to an open stage

    `converted` is only reached through the convert action (it creates the
    contact and deal), and a converted lead never moves again: work continues
    on the deal. Pure module: no database, unit tested in spec/crm_lead_stages_spec.lua.
]]

local S = {}

S.ORDER = { "new", "contacting", "qualified", "meeting", "converted", "nurture", "lost" }

-- The working funnel, in order. Nurture/lost are parked, converted is the exit.
S.FUNNEL = { "new", "contacting", "qualified", "meeting", "converted" }

S.OPEN = { new = true, contacting = true, qualified = true, meeting = true }
S.PARKED = { nurture = true, lost = true }

S.LABELS = {
    new = "New", contacting = "Contacting", qualified = "Qualified", meeting = "Meeting",
    converted = "Converted", nurture = "Nurture", lost = "Lost",
}

-- Older clients (and the old Leads page) still say "contacted".
S.ALIASES = { contacted = "contacting", meeting_booked = "meeting", nurturing = "nurture" }

local RANK = {}
for i, s in ipairs(S.FUNNEL) do RANK[s] = i end

local VALID = {}
for _, s in ipairs(S.ORDER) do VALID[s] = true end

--- The canonical stage for a client value, or nil when it isn't one.
function S.normalise(v)
    if type(v) ~= "string" then return nil end
    v = v:lower():gsub("^%s+", ""):gsub("%s+$", "")
    v = S.ALIASES[v] or v
    return VALID[v] and v or nil
end

function S.valid(v) return VALID[v] == true end

--- Position in the funnel (1..5); 0 for nurture/lost.
function S.rank(stage) return RANK[stage] or 0 end

function S.is_open(stage) return S.OPEN[stage] == true end

--- Can a lead move `from` -> `to` through the stage action?
-- @return true | nil, code, message
function S.can_move(from, to)
    if not VALID[to] then return nil, "invalid_stage", "Unknown stage" end
    if from == to then return nil, "same_stage", "The lead is already in that stage" end
    if from == "converted" then
        return nil, "converted", "This lead is converted. Work continues on its deal."
    end
    if to == "converted" then
        return nil, "use_convert", "Use “Convert to deal” to convert a lead"
    end
    return true
end

--- Labels with the workspace's renames applied (only known stages, non-empty strings).
function S.labels(overrides)
    local out = {}
    for k, v in pairs(S.LABELS) do out[k] = v end
    if type(overrides) == "table" then
        for k, v in pairs(overrides) do
            if VALID[k] and type(v) == "string" and v:match("%S") then out[k] = v:sub(1, 40) end
        end
    end
    return out
end

return S
