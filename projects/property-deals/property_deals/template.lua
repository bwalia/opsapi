-- Workflow template definitions: validation, normalisation and publishing.
-- A definition is plain JSON (docs/property-deals/template-format.md). Every
-- published version is immutable; a deal pins the version it started on.
local cjson = require("cjson")

local T = {}

T.FORMAT = 1
T.OWNERS = { operator = true, manager = true, compliance = true, agent = true }
T.APPROVALS = { none = true, any_operator = true, manager = true, two_person = true }
T.DUE_FROM = { stage_entry = true, deal_created = true, task_done = true,
               target_exchange = true, target_completion = true }
T.PRIORITIES = { critical = true, high = true, medium = true, low = true }
T.SUBJECTS = { deal_party = true, deal = true, property = true, workspace = true }
T.DEAL_TYPES = { buy = true, sell = true, buy_and_assign = true, sourcing = true }

local KEY = "^[a-z][a-z0-9_]*$"

local function arr(t)
    return setmetatable(t or {}, cjson.array_mt)
end

local function is_list(v)
    if type(v) ~= "table" then return false end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return n == #v
end

--- Validate and normalise a definition (a decoded JSON object or a seed table).
-- @return normalised definition | nil, { "path: problem", ... }
function T.validate(def)
    local errs = {}
    local function bad(path, msg) errs[#errs + 1] = path .. ": " .. msg end

    if type(def) ~= "table" then return nil, { "definition: must be an object" } end
    if def.format ~= T.FORMAT then bad("format", "must be " .. T.FORMAT) end
    if type(def.key) ~= "string" or not def.key:match(KEY) then bad("key", "lowercase letters, digits and _") end
    if type(def.name) ~= "string" or def.name == "" then bad("name", "is required") end
    if def.deal_types ~= nil then
        if not is_list(def.deal_types) then
            bad("deal_types", "must be a list")
        else
            for i, dt in ipairs(def.deal_types) do
                if not T.DEAL_TYPES[dt] then bad("deal_types[" .. i .. "]", "unknown deal type") end
            end
        end
    end
    if not is_list(def.stages) or #def.stages == 0 then
        bad("stages", "needs at least one stage")
        return nil, errs
    end

    local stage_keys, task_keys, compliance_keys = {}, {}, {}
    for i, c in ipairs(is_list(def.compliance) and def.compliance or {}) do
        local p = "compliance[" .. i .. "]"
        if type(c.key) ~= "string" or not c.key:match(KEY) then
            bad(p .. ".key", "lowercase letters, digits and _")
        elseif compliance_keys[c.key] then
            bad(p .. ".key", "duplicate '" .. c.key .. "'")
        else
            compliance_keys[c.key] = true
        end
        if type(c.name) ~= "string" or c.name == "" then bad(p .. ".name", "is required") end
        if not T.SUBJECTS[c.subject] then bad(p .. ".subject", "deal_party, deal, property or workspace") end
        if c.expires_after_days ~= nil and (type(c.expires_after_days) ~= "number" or c.expires_after_days < 1) then
            bad(p .. ".expires_after_days", "must be a positive number")
        end
    end

    -- First pass: keys (tasks may depend on tasks in later stages' lists, gates on any task).
    for i, s in ipairs(def.stages) do
        local p = "stages[" .. i .. "]"
        if type(s.key) ~= "string" or not s.key:match(KEY) then
            bad(p .. ".key", "lowercase letters, digits and _")
        elseif stage_keys[s.key] then
            bad(p .. ".key", "duplicate stage '" .. s.key .. "'")
        else
            stage_keys[s.key] = true
        end
        if type(s.name) ~= "string" or s.name == "" then bad(p .. ".name", "is required") end
        if s.tasks ~= nil and not is_list(s.tasks) then bad(p .. ".tasks", "must be a list") end
        for j, t in ipairs(is_list(s.tasks) and s.tasks or {}) do
            local tp = p .. ".tasks[" .. j .. "]"
            if type(t.key) ~= "string" or not t.key:match(KEY) then
                bad(tp .. ".key", "lowercase letters, digits and _")
            elseif task_keys[t.key] then
                bad(tp .. ".key", "duplicate task '" .. t.key .. "' (task keys are unique per template)")
            else
                task_keys[t.key] = true
            end
        end
    end

    for i, s in ipairs(def.stages) do
        local p = "stages[" .. i .. "]"
        for j, t in ipairs(is_list(s.tasks) and s.tasks or {}) do
            local tp = p .. ".tasks[" .. j .. "]"
            if type(t.title) ~= "string" or t.title == "" then bad(tp .. ".title", "is required") end
            t.owner = t.owner or "operator"
            if not T.OWNERS[t.owner] then bad(tp .. ".owner", "operator, manager, compliance or agent") end
            t.approval = t.approval or "none"
            if not T.APPROVALS[t.approval] then bad(tp .. ".approval", "none, any_operator, manager or two_person") end
            if t.priority ~= nil and not T.PRIORITIES[t.priority] then bad(tp .. ".priority", "critical, high, medium or low") end
            if t.sla_minutes ~= nil and (type(t.sla_minutes) ~= "number" or t.sla_minutes < 1) then
                bad(tp .. ".sla_minutes", "must be a positive number")
            end
            local due = t.due
            if due == nil then
                bad(tp .. ".due", "is required")
            elseif type(due) ~= "table" or not T.DUE_FROM[due.from] then
                bad(tp .. ".due.from", "stage_entry, deal_created, task_done, target_exchange or target_completion")
            else
                local units = 0
                for _, u in ipairs({ "minutes", "hours", "working_days" }) do
                    if due[u] ~= nil then
                        units = units + 1
                        if type(due[u]) ~= "number" or due[u] % 1 ~= 0 then bad(tp .. ".due." .. u, "must be a whole number") end
                    end
                end
                if units ~= 1 then bad(tp .. ".due", "give exactly one of minutes, hours or working_days") end
                if due.from == "task_done" and not task_keys[due.task] then
                    bad(tp .. ".due.task", "must name a task in this template")
                end
            end
            t.depends_on = arr(t.depends_on)
            for k, dep in ipairs(t.depends_on) do
                if not task_keys[dep] then bad(tp .. ".depends_on[" .. k .. "]", "unknown task '" .. tostring(dep) .. "'") end
                if dep == t.key then bad(tp .. ".depends_on[" .. k .. "]", "a task can't depend on itself") end
            end
            if t.agent ~= nil and type(t.agent) ~= "table" then bad(tp .. ".agent", "must be an object") end
            t.blocking = t.blocking == true
            t.compliance = t.compliance == true
        end
        s.tasks = arr(s.tasks)

        local g = s.entry_gate
        if g ~= nil then
            if type(g) ~= "table" then
                bad(p .. ".entry_gate", "must be an object")
            else
                for k, key in ipairs(g.tasks_done or {}) do
                    if not task_keys[key] then bad(p .. ".entry_gate.tasks_done[" .. k .. "]", "unknown task '" .. key .. "'") end
                end
                for k, key in ipairs(g.compliance_passed or {}) do
                    if not compliance_keys[key] then
                        bad(p .. ".entry_gate.compliance_passed[" .. k .. "]", "unknown compliance item '" .. key .. "'")
                    end
                end
                g.tasks_done = arr(g.tasks_done)
                g.compliance_passed = arr(g.compliance_passed)
                g.documents = arr(g.documents)
                g.fields = arr(g.fields)
            end
        end
    end
    def.stages = arr(def.stages)
    def.compliance = arr(def.compliance)
    def.deal_types = arr(def.deal_types)

    if #errs > 0 then return nil, errs end
    return def
end

--- The stage entry for a key, and its index.
function T.stage(def, key)
    for i, s in ipairs(def.stages) do
        if s.key == key then return s, i end
    end
end

--- Every task definition in the template, by key.
function T.tasks_by_key(def)
    local out = {}
    for _, s in ipairs(def.stages) do
        for _, t in ipairs(s.tasks or {}) do out[t.key] = { task = t, stage = s.key } end
    end
    return out
end

return T
