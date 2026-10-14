--[[
    ATS — selection rates and impact ratios by self-ID group (port of Fairness.swift).
    Groups smaller than MIN_GROUP are not reported; an impact ratio below 0.8
    (the four-fifths guideline) is a warning for a person to look into.
]]

local F = {}

F.MIN_GROUP = 10
F.WARN_BELOW = 0.8

F.QUESTIONS = {
    { id = "gender", label = "Gender", options = { "Woman", "Man", "Non-binary", "Another way", "Prefer not to say" } },
    { id = "age_band", label = "Age", options = { "Under 25", "25–39", "40–54", "55 or over", "Prefer not to say" } },
    { id = "ethnicity", label = "Ethnic group", options = { "Asian or Asian British",
        "Black, African, Caribbean or Black British", "Mixed or multiple", "White", "Another ethnic group",
        "Prefer not to say" } },
    { id = "disability", label = "Do you consider yourself disabled?", options = { "Yes", "No", "Prefer not to say" } },
}

--- self_ids: list of {key, answers}; outcomes: key -> true (advanced) / false (decided otherwise).
function F.report(question, self_ids, outcomes)
    local totals, groups = {}, {}
    for _, s in ipairs(self_ids) do
        local advanced = outcomes[s.key]
        local group = s.answers and s.answers[question]
        if advanced ~= nil and type(group) == "string" and group ~= "" then
            if not totals[group] then
                totals[group] = { 0, 0 }
                groups[#groups + 1] = group
            end
            totals[group][1] = totals[group][1] + 1
            if advanced then totals[group][2] = totals[group][2] + 1 end
        end
    end
    local best, reported = 0, {}
    for _, g in ipairs(groups) do
        local t = totals[g]
        if t[1] >= F.MIN_GROUP then
            reported[#reported + 1] = g
            best = math.max(best, t[2] / t[1])
        end
    end
    table.sort(reported)
    local rows = {}
    for _, g in ipairs(reported) do
        local t = totals[g]
        local rate = t[2] / t[1]
        local ratio = best > 0 and rate / best or 1
        rows[#rows + 1] = { group = g, total = t[1], selected = t[2], rate = rate, impact_ratio = ratio,
            warning = ratio < F.WARN_BELOW }
    end
    return { question = question, rows = rows, suppressed = #groups - #reported }
end

return F
