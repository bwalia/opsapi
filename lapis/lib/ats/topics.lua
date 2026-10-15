--[[
    ATS — topics an interview never raises (snazzy BannedTopics, KitValidator.swift).
    A keyword screen for kits and for what candidates volunteer; it errs towards
    flagging, and a person reviews what it finds. The Swift regexes are expanded
    here into Lua patterns with word frontiers; keep both lists in step.
]]

local T = require("lib.ats.text")

local B, E = T.B, T.E

local function words(list)
    local out = {}
    for _, w in ipairs(list) do out[#out + 1] = B .. w .. E end
    return out
end

local Topics = {}

Topics.list = {
    { name = "age", patterns = words({ "how old", "your age", "date of birth", "born in", "year you were born",
        "retirement age", "young", "digital native", "recent graduates? only", "i'?m %d%d years old", "i am %d%d" }) },
    { name = "marital or family status", patterns = words({ "married", "marital", "husband", "wife", "spouse",
        "divorc%w*", "childcare", "have kids", "have children", "have any kids", "have any children", "my kids",
        "my children", "my son", "my daughter" }) },
    { name = "pregnancy", patterns = words({ "pregnan%w*", "maternity", "paternity", "start a family",
        "starting a family", "expecting a baby" }) },
    { name = "religion", patterns = words({ "religio%w*", "church", "mosque", "synagogue", "pray", "praying", "prayer",
        "prayers", "your faith", "my faith" }) },
    { name = "nationality or ethnicity", patterns = words({ "nationality", "ethnic%w*", "race", "where are you from",
        "where are you really from", "native speaker", "native english speaker", "mother tongue", "citizenship",
        "immigra%w*", "accent" }) },
    { name = "health or disability", patterns = words({ "disab%w*", "health", "medical", "illness", "sick leave",
        "sick days", "medication", "diagnos%w*", "mental health", "depression", "anxiety", "adhd", "autis%w*",
        "dyslexi%w*", "cancer", "wheelchair" }) },
    { name = "sexual orientation or gender identity", patterns = words({ "sexual%w*", "gay", "lesbian", "bisexual",
        "transgender", "gender identity", "boyfriend", "girlfriend", "partner'?s gender" }) },
    { name = "union membership", patterns = words({ "trade union", "union member%w*", "unioni[sz]%w*" }) },
    { name = "political views", patterns = words({ "political views?", "political party", "political parties",
        "political affiliation", "political beliefs?", "political opinions?", "vote[ds]? for", "which party" }) },
    { name = "appearance", patterns = words({ "photo of you", "appearance", "how you look", "height and weight",
        "attractive" }) },
    { name = "criminal record", patterns = words({ "criminal", "convict%w*", "arrest%w*", "prison", "jail" }) },
}

--- Everyday phrases that contain a topic's words but aren't about it.
Topics.benign = {
    "health and safety", "health & safety", "health check", "healthcheck", "system health", "service health",
    "race condition", "data race", "race to", "office politics", "european union", "union of", "union type",
    "sexual harassment policy", "faith in the team", "team health", "account health", "customer health",
    "health score", "health metrics", "health of the", "healthy", "data health", "pipeline health", "code health",
}

--- The banned topics a text touches (names only).
function Topics.find(text, allow_criminal_record)
    local lower = tostring(text or ""):lower()
    for _, phrase in ipairs(Topics.benign) do lower = T.replace(lower, phrase, " ") end
    local found = {}
    for _, topic in ipairs(Topics.list) do
        if not (allow_criminal_record and topic.name == "criminal record") then
            for _, p in ipairs(topic.patterns) do
                if lower:find(p) then
                    found[#found + 1] = topic.name
                    break
                end
            end
        end
    end
    return found
end

--- The sentences of a text that touch a banned topic: {first, last} byte ranges.
function Topics.sentences(text)
    local out = {}
    for _, s in ipairs(T.sentences(text)) do
        if #Topics.find(s.text) > 0 then out[#out + 1] = s end
    end
    return out
end

local SALARY_HISTORY = (function()
    local list = {}
    for _, a in ipairs({ "current", "previous", "last", "past", "present" }) do
        for _, b in ipairs({ "salary", "pay", "wage", "compensation" }) do list[#list + 1] = a .. " " .. b end
    end
    list[#list + 1] = "salary history"
    for _, a in ipairs({ "do", "did" }) do
        for _, b in ipairs({ "earn", "make", "get paid" }) do list[#list + 1] = "how much " .. a .. " you " .. b end
        for _, b in ipairs({ "earn", "make" }) do list[#list + 1] = "what " .. a .. " you " .. b end
    end
    return words(list)
end)()

function Topics.asks_salary_history(text)
    local lower = tostring(text or ""):lower()
    for _, p in ipairs(SALARY_HISTORY) do
        if lower:find(p) then return true end
    end
    return false
end

return Topics
