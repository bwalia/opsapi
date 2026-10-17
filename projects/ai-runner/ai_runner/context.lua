-- Per-project context pack for AI runs: skills git URLs, MD refs, target repo.
-- Resolved before launch and frozen on the run / ar_task_work as context_snapshot.
local cjson = require("cjson.safe").new()
cjson.encode_empty_table_as_object(false)
local U = require("ai_runner.util")

local C = {}

local function as_list(v)
    if type(v) ~= "table" then return {} end
    if v[1] ~= nil then return v end
    local out = {}
    for _, x in pairs(v) do out[#out + 1] = x end
    return out
end

--- Normalize skills_git_urls from API/DB into a clean list.
function C.skills(raw)
    local out = {}
    for _, s in ipairs(as_list(raw)) do
        if type(s) == "table" and type(s.url) == "string" and s.url ~= "" then
            out[#out + 1] = {
                url = U.clean(s.url, 2000),
                ref = type(s.ref) == "string" and U.clean(s.ref, 255) or nil,
                path = type(s.path) == "string" and U.clean(s.path, 1024) or nil,
                label = type(s.label) == "string" and U.clean(s.label, 200) or nil,
            }
        elseif type(s) == "string" and s ~= "" then
            out[#out + 1] = { url = U.clean(s, 2000) }
        end
    end
    return out
end

--- Normalize md_refs: { path|url, label? }.
function C.md_refs(raw)
    local out = {}
    for _, m in ipairs(as_list(raw)) do
        if type(m) == "table" then
            local path = type(m.path) == "string" and m.path or nil
            local url = type(m.url) == "string" and m.url or nil
            if path or url then
                out[#out + 1] = {
                    path = path and U.clean(path, 1024) or nil,
                    url = url and U.clean(url, 2000) or nil,
                    label = type(m.label) == "string" and U.clean(m.label, 200) or nil,
                }
            end
        elseif type(m) == "string" and m ~= "" then
            if m:match("^https?://") then
                out[#out + 1] = { url = U.clean(m, 2000) }
            else
                out[#out + 1] = { path = U.clean(m, 1024) }
            end
        end
    end
    return out
end

--- Allowed executor tokens: machine | builtin | jobshout | provider:<uuid>
function C.allowed_executors(raw)
    local out, seen = {}, {}
    for _, e in ipairs(as_list(raw)) do
        if type(e) == "string" and e ~= "" then
            local t = e:lower()
            if (t == "machine" or t == "builtin" or t == "jobshout" or t:match("^provider:[0-9a-f%-]+$"))
                and not seen[t] then
                seen[t] = true
                out[#out + 1] = t
            end
        end
    end
    return out
end

--- Prompt block describing the project's ways-of-working pack (loaded before the agent starts).
function C.prompt_block(pack)
    pack = pack or {}
    local lines = {
        "Ways of working for this project (load these before you change code):",
    }
    if type(pack.target_repo_url) == "string" and pack.target_repo_url ~= "" then
        lines[#lines + 1] = "- Target repository for the pull request: " .. pack.target_repo_url
    end
    local skills = pack.skills_git_urls or {}
    if #skills > 0 then
        lines[#lines + 1] = "- Skills repositories (clone/read and follow):"
        for _, s in ipairs(skills) do
            local bit = "  - " .. (s.label and (s.label .. ": ") or "") .. tostring(s.url)
            if s.ref then bit = bit .. " @" .. s.ref end
            if s.path then bit = bit .. " (path " .. s.path .. ")" end
            lines[#lines + 1] = bit
        end
    end
    local mds = pack.md_refs or {}
    if #mds > 0 then
        lines[#lines + 1] = "- Reference markdown (read before coding):"
        for _, m in ipairs(mds) do
            local bit = "  - " .. (m.label and (m.label .. ": ") or "")
                .. tostring(m.path or m.url or "")
            lines[#lines + 1] = bit
        end
    end
    if #lines == 1 then
        return "(no project skills or reference files configured)"
    end
    return table.concat(lines, "\n")
end

--- Snapshot frozen onto the run / task work record.
function C.snapshot(ps, extras)
    extras = extras or {}
    local skills = C.skills(extras.skills_git_urls or ps.skills_git_urls)
    local md = C.md_refs(extras.md_refs or ps.md_refs)
    -- Optional toggles from Start dialog: only keep selected items when provided.
    if type(extras.selected_skill_urls) == "table" then
        local want = {}
        for _, u in ipairs(extras.selected_skill_urls) do want[tostring(u)] = true end
        local filtered = {}
        for _, s in ipairs(skills) do if want[s.url] then filtered[#filtered + 1] = s end end
        skills = filtered
    end
    if type(extras.selected_md) == "table" then
        local want = {}
        for _, k in ipairs(extras.selected_md) do want[tostring(k)] = true end
        local filtered = {}
        for _, m in ipairs(md) do
            local key = m.path or m.url or ""
            if want[key] then filtered[#filtered + 1] = m end
        end
        md = filtered
    end
    return {
        target_repo_url = type(ps.target_repo_url) == "string" and ps.target_repo_url or nil,
        base_branch = type(ps.base_branch) == "string" and ps.base_branch or nil,
        skills_git_urls = skills,
        md_refs = md,
        vault_configured = type(ps.vault_url) == "string" and ps.vault_url ~= ""
            and type(ps.vault_secret_path) == "string" and ps.vault_secret_path ~= ""
            and type(ps.vault_token_sealed) == "string" and ps.vault_token_sealed ~= "",
    }
end

function C.encode(snap)
    return cjson.encode(snap or {})
end

return C
