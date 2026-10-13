-- luacheck: max line length 140
--[[
    Shop → CRM lead rules (pure: no nginx, no DB)
    =============================================
    One open CRM lead per customer email. Every AI-advisor chat and every quote
    for that email attaches to it, so nothing gets lost to the 5-minute
    duplicate guard on public lead forms. The lead's metadata.shop holds:

      chat_sessions  [uuid, …]             advisor chats linked to this email
      quotes         [{uuid, number, total_minor}, …]
      requirements   {goal, models, …}     what the customer said they need
      improve_consent boolean              may we use their chats to improve advice

    Unit tested by spec/shop-leads-test.lua.
]]

local M = {}

M.MAX_LIST = 50          -- cap on chat_sessions / quotes kept in metadata
M.MAX_FIELD = 500        -- chars per requirements field
M.MAX_NOTES = 20000      -- chars of lead notes kept (oldest trimmed)

--- The things the advisor asks about. Anything else is dropped.
M.REQUIREMENT_KEYS = {
    "goal", "workloads", "models", "data_size", "team_size", "budget_gbp", "deadline", "in_house",
    "sector", "constraints",
}
local KEYSET = {}
for _, k in ipairs(M.REQUIREMENT_KEYS) do KEYSET[k] = true end

--- Lower-cased, trimmed email, or nil when it doesn't look like one.
function M.email(v)
    if type(v) ~= "string" then return nil end
    v = v:match("^%s*(.-)%s*$"):lower()
    if #v > 254 or not v:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then return nil end
    return v
end

local function clean_text(v)
    if type(v) == "number" then v = tostring(v) end
    if type(v) ~= "string" then return nil end
    v = v:gsub("%c", " "):match("^%s*(.-)%s*$")
    if v == "" then return nil end
    return v:sub(1, M.MAX_FIELD)
end

--- Whitelisted, trimmed requirements (lists joined with ", "). Empty table when nothing usable.
function M.requirements(input)
    local out = {}
    if type(input) ~= "table" then return out end
    for k, v in pairs(input) do
        if KEYSET[k] then
            if type(v) == "table" then
                local parts = {}
                for _, item in ipairs(v) do
                    local s = clean_text(item)
                    if s then parts[#parts + 1] = s end
                end
                v = table.concat(parts, ", ")
            end
            local s = clean_text(v)
            if s then out[k] = s end
        end
    end
    return out
end

--- Newer facts win; older facts the customer didn't repeat are kept.
function M.merge_requirements(old, new)
    local out = {}
    for k, v in pairs(type(old) == "table" and old or {}) do if KEYSET[k] then out[k] = v end end
    for k, v in pairs(M.requirements(new)) do out[k] = v end
    return out
end

--- One-line plain summary for the lead's notes, e.g. "Goal: … · Budget: £40000 · Deadline: …".
function M.requirements_line(req)
    local labels = {
        goal = "Goal", workloads = "Workloads", models = "Models", data_size = "Data", team_size = "Team",
        budget_gbp = "Budget (£)", deadline = "Deadline", in_house = "Already has", sector = "Sector",
        constraints = "Constraints",
    }
    local parts = {}
    for _, k in ipairs(M.REQUIREMENT_KEYS) do
        if req and req[k] then parts[#parts + 1] = labels[k] .. ": " .. req[k] end
    end
    return table.concat(parts, " · ")
end

local function push_unique(list, item, same)
    list = type(list) == "table" and list or {}
    for _, existing in ipairs(list) do
        if same(existing, item) then return list end
    end
    list[#list + 1] = item
    while #list > M.MAX_LIST do table.remove(list, 1) end
    return list
end

--- Merge one shop event into a lead's metadata table (mutates + returns it).
-- event: { chat_session_uuid?, quote = {uuid, number, total_minor}?, requirements?, improve_consent? }
function M.merge_metadata(meta, event)
    meta = type(meta) == "table" and meta or {}
    local shop = type(meta.shop) == "table" and meta.shop or {}
    if event.chat_session_uuid then
        shop.chat_sessions = push_unique(shop.chat_sessions, event.chat_session_uuid, function(a, b) return a == b end)
    end
    if type(event.quote) == "table" and event.quote.uuid then
        shop.quotes = push_unique(shop.quotes, event.quote, function(a, b) return type(a) == "table" and a.uuid == b.uuid end)
    end
    if event.requirements then
        shop.requirements = M.merge_requirements(shop.requirements, event.requirements)
    end
    -- Consent only ever moves by an explicit choice; a later event without it leaves it alone.
    if event.improve_consent ~= nil then shop.improve_consent = event.improve_consent == true end
    meta.shop = shop
    return meta
end

--- Append a dated line to existing notes, trimming the oldest text past MAX_NOTES.
function M.append_note(notes, line, stamp)
    if not line or line == "" then return notes end
    local entry = "[" .. stamp .. "] " .. line
    local out = (type(notes) == "string" and notes ~= "") and (notes .. "\n" .. entry) or entry
    if #out > M.MAX_NOTES then out = out:sub(#out - M.MAX_NOTES + 1) end
    return out
end

--- Split "Ada Lovelace" → "Ada", "Lovelace". Unknown → "Shop customer".
function M.split_name(name)
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
    if name == "" then return "Shop customer", nil end
    local first, last = name:match("^(%S+)%s+(.+)$")
    return first or name, last
end

return M
