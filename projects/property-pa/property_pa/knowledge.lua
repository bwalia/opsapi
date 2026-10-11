-- Versioned, approved knowledge (build prompt rule 9). A rule (pa_knowledge) has versions; only an approved
-- version is used by the PA. Anyone may propose (the PA too, flagged proposed_by_ai); company and team rules are
-- approved by a manager (property_pa_knowledge.manage); a personal rule by its owner. Approving a version
-- supersedes the previous approved one, so the history is never lost.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local K = {}

local SELECT = [[
    SELECT k.uuid, k.key, k.domain, k.scope, k.owner_user_uuid, k.status, k.current_version,
           v.title, v.rule, v.rationale, v.triggers, v.approved_by_user_uuid, v.approved_at, k.updated_at
    FROM pa_knowledge k
    LEFT JOIN pa_knowledge_versions v ON v.knowledge_uuid = k.uuid AND v.version = k.current_version
]]

local function visible(user_uuid)
    return "(k.scope <> 'personal' OR k.owner_user_uuid = " .. db.escape_literal(user_uuid) .. ")"
end

local function fix(r)
    r.triggers = U.json(r.triggers)
    if type(r.triggers) ~= "table" then r.triggers = {} end
    setmetatable(r.triggers, cjson.array_mt)
    return r
end

--- Seed the first seller playbook (approved v1) once per workspace. @return number added
function K.ensure(ns, user_uuid)
    if U.one("SELECT 1 FROM pa_knowledge WHERE namespace_id = ? AND scope = 'company' LIMIT 1", ns) then return 0 end
    local n = 0
    U.tx(function()
        for _, r in ipairs(require("property_pa.seed.seller_playbook")) do
            local k = db.query([[
                INSERT INTO pa_knowledge (namespace_id, key, domain, scope, status, current_version)
                VALUES (?, ?, ?, 'company', 'approved', 1) ON CONFLICT DO NOTHING RETURNING uuid
            ]], ns, r.key, r.domain)[1]
            if k then
                db.query([[
                    INSERT INTO pa_knowledge_versions (namespace_id, knowledge_uuid, version, title, rule, rationale,
                        triggers, status, proposed_by_user_uuid, approved_by_user_uuid, approved_at)
                    VALUES (?, ?::uuid, 1, ?, ?, ?, ?::jsonb, 'approved', ?, ?, NOW())
                ]], ns, k.uuid, r.title, r.rule, r.rationale, cjson.encode(r.triggers), user_uuid or db.NULL,
                    user_uuid or db.NULL)
                n = n + 1
            end
        end
    end)
    return n
end

--- Approved rules this person may use: company + team + their own personal ones. params: domain?, trigger?, q?
function K.list(ns, user_uuid, params)
    params = params or {}
    local where = { "k.namespace_id = " .. db.escape_literal(ns), visible(user_uuid) }
    if params.status ~= "all" then where[#where + 1] = "k.status = 'approved'" end
    if params.domain and params.domain:match("^[a-z_]+$") then where[#where + 1] = "k.domain = " .. db.escape_literal(params.domain) end
    if params.trigger and params.trigger:match("^[a-z0-9_]+$") then
        where[#where + 1] = "(jsonb_exists(v.triggers, " .. db.escape_literal(params.trigger) .. ") OR jsonb_exists(v.triggers, 'always'))"
    end
    if params.q and params.q ~= "" then
        local q = db.escape_literal("%" .. params.q:gsub("[%%_\\]", "\\%0"):sub(1, 100) .. "%")
        where[#where + 1] = "(v.title ILIKE " .. q .. " OR v.rule ILIKE " .. q .. " OR k.key ILIKE " .. q .. ")"
    end
    local rows = db.query(SELECT .. " WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY CASE k.scope WHEN 'personal' THEN 0 WHEN 'team' THEN 1 ELSE 2 END, k.domain, k.key LIMIT 200")
    for _, r in ipairs(rows) do fix(r) end
    return U.array(rows)
end

function K.get(ns, uuid, user_uuid)
    if not U.is_uuid(uuid) then return nil end
    local r = U.one(SELECT .. " WHERE k.namespace_id = ? AND k.uuid = ?::uuid AND " .. visible(user_uuid), ns, uuid)
    if not r then return nil end
    fix(r)
    r.versions = U.array(db.query([[
        SELECT version, title, rule, rationale, triggers, status, proposed_by_user_uuid, proposed_by_ai,
               approved_by_user_uuid, approved_at, created_at
        FROM pa_knowledge_versions WHERE namespace_id = ? AND knowledge_uuid = ?::uuid ORDER BY version DESC
    ]], ns, uuid))
    for _, v in ipairs(r.versions) do fix(v) end
    return r
end

--- Propose a rule or a new version of one. d = { key, domain?, scope?, title, rule, rationale?, triggers? }
-- @return { knowledge_uuid, version }
function K.propose(ns, d, user_uuid, by_ai)
    local scope = d.scope or "company"
    return U.tx(function()
        local owner = scope == "personal" and user_uuid or nil
        local k
        if scope == "personal" then
            k = U.one("SELECT uuid FROM pa_knowledge WHERE namespace_id = ? AND scope = 'personal' AND owner_user_uuid = ? AND key = ?",
                ns, user_uuid, d.key)
        else
            k = U.one("SELECT uuid FROM pa_knowledge WHERE namespace_id = ? AND scope = ? AND key = ?", ns, scope, d.key)
        end
        if not k then
            k = db.insert("pa_knowledge", { namespace_id = ns, key = d.key, domain = d.domain or "general", scope = scope,
                owner_user_uuid = owner or db.NULL, status = "draft", current_version = 0 }, { returning = { "uuid" } })[1]
        end
        local nextv = U.one("SELECT COALESCE(MAX(version), 0) + 1 AS v FROM pa_knowledge_versions WHERE knowledge_uuid = ?::uuid",
            k.uuid).v
        db.query([[
            INSERT INTO pa_knowledge_versions (namespace_id, knowledge_uuid, version, title, rule, rationale, triggers,
                status, proposed_by_user_uuid, proposed_by_ai)
            VALUES (?, ?::uuid, ?, ?, ?, ?, ?::jsonb, 'proposed', ?, ?)
        ]], ns, k.uuid, nextv, d.title, d.rule, d.rationale or db.NULL, cjson.encode(setmetatable(d.triggers or {},
            cjson.array_mt)), user_uuid, by_ai == true)
        return { knowledge_uuid = k.uuid, version = nextv, status = "proposed" }
    end)
end

--- Approve or reject a proposed version. can_manage = caller has property_pa_knowledge.manage.
function K.decide(ns, uuid, version, approve, user_uuid, can_manage)
    local k = U.is_uuid(uuid) and U.one("SELECT uuid, scope, owner_user_uuid FROM pa_knowledge WHERE namespace_id = ? AND uuid = ?::uuid",
        ns, uuid)
    if not k then U.fail(404, "Knowledge not found") end
    if k.scope == "personal" then
        if k.owner_user_uuid ~= user_uuid then U.fail(404, "Knowledge not found") end
    elseif not can_manage then
        U.fail(403, "Only a manager can approve company or team knowledge")
    end
    local v = U.one("SELECT status FROM pa_knowledge_versions WHERE knowledge_uuid = ?::uuid AND version = ?", uuid, version)
    if not v then U.fail(404, "Version not found") end
    if v.status ~= "proposed" then U.fail(409, "Version is already " .. v.status) end
    U.tx(function()
        if approve then
            db.query("UPDATE pa_knowledge_versions SET status = 'superseded' WHERE knowledge_uuid = ?::uuid AND status = 'approved'", uuid)
            db.query([[UPDATE pa_knowledge_versions SET status = 'approved', approved_by_user_uuid = ?, approved_at = NOW()
                WHERE knowledge_uuid = ?::uuid AND version = ?]], user_uuid, uuid, version)
            db.query([[UPDATE pa_knowledge SET status = 'approved', current_version = ?, updated_at = NOW()
                WHERE uuid = ?::uuid]], version, uuid)
        else
            db.query([[UPDATE pa_knowledge_versions SET status = 'rejected', approved_by_user_uuid = ?, approved_at = NOW()
                WHERE knowledge_uuid = ?::uuid AND version = ?]], user_uuid, uuid, version)
        end
    end)
    return K.get(ns, uuid, user_uuid)
end

--- Retire a rule (no longer used; history kept).
function K.retire(ns, uuid, user_uuid, can_manage)
    local k = U.is_uuid(uuid) and U.one("SELECT scope, owner_user_uuid FROM pa_knowledge WHERE namespace_id = ? AND uuid = ?::uuid",
        ns, uuid)
    if not k or (k.scope == "personal" and k.owner_user_uuid ~= user_uuid) then U.fail(404, "Knowledge not found") end
    if k.scope ~= "personal" and not can_manage then U.fail(403, "Only a manager can retire company or team knowledge") end
    db.query("UPDATE pa_knowledge SET status = 'retired', updated_at = NOW() WHERE uuid = ?::uuid", uuid)
    return K.get(ns, uuid, user_uuid)
end

--- Proposed versions waiting for a decision (managers see company/team; everyone sees their personal ones).
function K.pending(ns, user_uuid, can_manage)
    local rows = db.query([[
        SELECT k.uuid, k.key, k.scope, v.version, v.title, v.rule, v.rationale, v.triggers, v.proposed_by_user_uuid,
               v.proposed_by_ai, v.created_at
        FROM pa_knowledge_versions v JOIN pa_knowledge k ON k.uuid = v.knowledge_uuid
        WHERE k.namespace_id = ? AND v.status = 'proposed'
          AND ((k.scope = 'personal' AND k.owner_user_uuid = ?) OR (k.scope <> 'personal' AND ?))
        ORDER BY v.created_at
    ]], ns, user_uuid, can_manage == true)
    for _, r in ipairs(rows) do fix(r) end
    return U.array(rows)
end

--- The approved rules as text for the agent, each with its key and version (so answers can cite them).
function K.text(ns, user_uuid, params, max)
    local parts = {}
    for _, r in ipairs(K.list(ns, user_uuid, params)) do
        parts[#parts + 1] = string.format("[%s v%d, %s] %s: %s", r.key, r.current_version, r.scope, r.title, r.rule)
    end
    local t = table.concat(parts, "\n")
    max = max or 8000
    return #t > max and (t:sub(1, max) .. "\n…") or t
end

return K
