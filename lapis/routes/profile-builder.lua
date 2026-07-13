--[[
    Profile Builder Routes (Dynamic Profile Management)

    Full CRUD for profile categories, questions, options, rules, tags,
    lookup tables, touchpoints, answers, completion tracking, and audit logs.

    Route prefix: /api/v2/profile-builder
    Admin endpoints require admin or accountant role.
    Answer endpoints are user-scoped.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local IdentityLock = require("lib.identity_lock")

-- ─── Locked-field guard for the generic answers endpoint ──────────────────
-- The profile-builder /answers endpoint is the historical back-door for
-- NINO/UTR writes: users' Personal Details wizard writes `question_key`
-- values 'nino', 'ni_number', and 'utr_number' straight into
-- user_profile_answers, bypassing the dedicated NINO endpoints. Without
-- this guard the whole anti-fraud lock is a paper tiger.
--
-- Mapping (question_key → lock field):
--   'nino'         → nino   (older seed, still in flight for some tenants)
--   'ni_number'    → nino   (newer wizard-tree seed — see dynamic-profile-builder.lua:1710)
--   'utr_number'   → utr    (Personal Details, is_required=true)
local LOCK_FIELD_BY_QUESTION_KEY = {
    nino        = "nino",
    ni_number   = "nino",
    utr_number  = "utr",
}

-- =========================================================================
-- Helper Functions
-- =========================================================================

local function parseJsonBody(self)
    local params = self.params or {}
    local ct = ngx.req.get_headers()["content-type"]
    if ct and ct:find("application/json") then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body then
            local ok, parsed = pcall(cjson.decode, body)
            if ok and parsed then
                for k, v in pairs(parsed) do params[k] = v end
            end
        end
    end
    return params
end

local function requireAuth(self)
    local user = self.current_user
    if not user then
        return nil
    end
    return user
end

local function requireAdmin(self)
    local user = self.current_user
    if not user then
        return nil, "auth"
    end
    local user_uuid = user.uuid or user.id
    local ok, rows = pcall(db.query, [[
        SELECT r.role_name
        FROM user__roles ur
        JOIN roles r ON ur.role_id = r.id
        JOIN users u ON ur.user_id = u.id
        WHERE u.uuid = ?
        LIMIT 1
    ]], user_uuid)
    if ok and rows and #rows > 0 then
        local role = rows[1].role_name
        if role == "administrative" or role == "tax_admin" or role == "tax_accountant" then
            return user
        end
    end
    return nil, "forbidden"
end

local function getNamespaceId(self)
    local ns_header = ngx.req.get_headers()["x-namespace-id"]
    if ns_header and ns_header ~= "" then
        local n = tonumber(ns_header)
        if n then return n end
    end
    local user = self.current_user
    if user then
        local user_uuid = user.uuid or user.id
        -- Try user_namespace_settings first (correct table)
        local ok, rows = pcall(db.query, [[
            SELECT default_namespace_id FROM user_namespace_settings WHERE user_id = (
                SELECT id FROM users WHERE uuid = ? LIMIT 1
            ) LIMIT 1
        ]], user_uuid)
        if ok and rows and #rows > 0 and rows[1].default_namespace_id then
            return tonumber(rows[1].default_namespace_id)
        end
    end
    return 0 -- Default namespace
end

-- Resolve a user UUID to internal integer ID (cached per request via ngx.ctx)
local function resolveUserId(user_uuid)
    if not user_uuid then return 0 end
    if type(user_uuid) == "number" then return user_uuid end
    -- Check if already numeric string
    if tonumber(user_uuid) then return tonumber(user_uuid) end
    -- Resolve UUID → integer ID
    local cache_key = "uid:" .. tostring(user_uuid)
    if ngx.ctx[cache_key] then return ngx.ctx[cache_key] end
    local ok, rows = pcall(db.query, "SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    local id = (ok and rows and #rows > 0) and rows[1].id or 0
    ngx.ctx[cache_key] = id
    return id
end

local function auditLog(params)
    local user_id = resolveUserId(params.user_id)
    local ok, err = pcall(db.query, [[
        INSERT INTO profile_audit_logs (uuid, namespace_id, user_id, action, entity_type, entity_uuid, old_data_json, new_data_json, ip_address, created_at)
        VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]],
        params.namespace_id or 0,
        user_id,
        params.action or "unknown",
        params.entity_type or "unknown",
        params.entity_uuid or db.NULL,
        params.old_data_json or db.NULL,
        params.new_data_json or db.NULL,
        params.ip_address or db.NULL
    )
    if not ok then
        ngx.log(ngx.ERR, "[ProfileBuilder] audit log insert failed: ", tostring(err))
    end
end

-- Per-category cache refresh — written on each save so /schema can
-- render the per-category strip on first paint without re-running the
-- rule engine. Mirrors /completion-status's loop (same visibility +
-- dynamic-requirement evaluators) so the cache never disagrees with
-- the gate. If the two ever drift it shows up as the user staring at
-- "100% complete" on the category strip while the gate still says
-- "answer this required question" — exactly the rhyme we just fixed
-- in /completion-status.
--
-- Note: the cache row is intentionally NOT filtered by business profile
-- tags or namespace. Those filters belong to the live gate (which has
-- request context — Origin header, JWT namespace claim, etc.). The
-- per-category cache is a coarse "this category is done as far as the
-- raw question set goes" signal. The frontend's liveSchema and the
-- /completion-status endpoint do the request-time filtering.
--
-- Forward-declare the rule evaluators so this function's closure
-- captures them as upvalues even though their bodies appear later in
-- the file. Without this, ``evaluateVisibility``/``evaluateRequirement``
-- here would compile to global lookups against an empty _ENV and the
-- save handler would silently no-op the cache refresh at runtime.
local evaluateVisibility, evaluateRequirement

local function recalculateCompletion(user_id, user_uuid, category_id)
    local ok, err = pcall(function()
        local ok_qs, questions = pcall(db.query, [[
            SELECT id, is_required
            FROM profile_questions
            WHERE category_id = ? AND is_active = true AND is_archived = false
        ]], category_id)
        if not ok_qs or not questions then
            ngx.log(ngx.ERR, "[ProfileBuilder] recalculateCompletion questions query failed: ", tostring(questions))
            return
        end

        -- Pre-load the user's answers once; ipairs(questions) iterates
        -- over the SAME data the evaluators need.
        local answer_map = {}
        local ok_ans, ans_rows = pcall(db.query, [[
            SELECT question_id, answer_text, answer_number, answer_boolean,
                   answer_date, answer_json, is_draft
            FROM user_profile_answers
            WHERE user_id = ?
        ]], user_id)
        if ok_ans and ans_rows then
            for _, a in ipairs(ans_rows) do
                answer_map[a.question_id] = a
            end
        end

        local total, answered, required, req_answered = 0, 0, 0, 0
        for _, q in ipairs(questions) do
            local is_visible = evaluateVisibility(q.id, answer_map)
            if is_visible then
                local a = answer_map[q.id]
                -- Same is_draft = false convention as the legacy
                -- cache here — recalculateCompletion exists for the
                -- "committed answer count" downstream uses, distinct
                -- from /completion-status which treats drafts as
                -- answered for the gate cookie.
                local has_committed_answer = false
                if a and not a.is_draft then
                    has_committed_answer =
                        (a.answer_text ~= nil and a.answer_text ~= "")
                        or a.answer_number ~= nil
                        or a.answer_boolean ~= nil
                        or a.answer_date ~= nil
                        or (a.answer_json ~= nil and a.answer_json ~= "" and a.answer_json ~= "null" and a.answer_json ~= "[]")
                end
                local effectively_required = q.is_required
                    or evaluateRequirement(q.id, answer_map)

                total = total + 1
                if has_committed_answer then
                    answered = answered + 1
                end
                if effectively_required then
                    required = required + 1
                    if has_committed_answer then
                        req_answered = req_answered + 1
                    end
                end
            end
        end

        local pct = 0
        if total > 0 then
            pct = math.floor((answered / total) * 100)
        end

        local status = "not_started"
        if pct >= 100 then
            status = "complete"
        elseif pct > 0 then
            status = "in_progress"
        end

        db.query([[
            INSERT INTO profile_completion_status (uuid, user_id, user_uuid, category_id, total_questions, answered_questions, required_questions, required_answered, completion_percent, status, last_updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
            ON CONFLICT (user_id, category_id) DO UPDATE SET
                total_questions = EXCLUDED.total_questions,
                answered_questions = EXCLUDED.answered_questions,
                required_questions = EXCLUDED.required_questions,
                required_answered = EXCLUDED.required_answered,
                completion_percent = EXCLUDED.completion_percent,
                status = EXCLUDED.status,
                last_updated_at = NOW()
        ]], user_id, user_uuid, category_id, total, answered, required, req_answered, pct, status)
    end)
    if not ok then
        ngx.log(ngx.ERR, "[ProfileBuilder] recalculateCompletion failed: ", tostring(err))
    end
end

-- Evaluate auto-tag rules against user's current answers and assign/remove tags
local function evaluateTagRules(user_id, user_uuid)
    local ok, err = pcall(function()
        -- Get all active tag rules with their associated tag info
        local rules = db.query([[
            SELECT tr.id, tr.tag_id, tr.source_question_id, tr.operator, tr.expected_value,
                   pt.slug as tag_slug, pt.name as tag_name
            FROM profile_tag_rules tr
            JOIN profile_tags pt ON pt.id = tr.tag_id
            WHERE tr.is_active = true AND pt.is_active = true
        ]])
        if not rules or #rules == 0 then return end

        -- Get user's current answers indexed by question_id (include drafts for visibility)
        local answer_map = {}
        local answers = db.query([[
            SELECT question_id, answer_text, answer_number, answer_boolean, answer_date, answer_json
            FROM user_profile_answers
            WHERE user_id = ?
        ]], user_id)
        for _, a in ipairs(answers or {}) do
            answer_map[a.question_id] = a
        end

        -- Evaluate each rule
        local tags_to_add = {}
        local tags_to_remove = {}

        for _, rule in ipairs(rules) do
            local answer = answer_map[rule.source_question_id]
            local match = false

            if answer then
                -- Resolve actual value: check each field, handling boolean false correctly
                local actual
                if answer.answer_text and answer.answer_text ~= "" then
                    actual = answer.answer_text
                elseif answer.answer_boolean ~= nil then
                    actual = tostring(answer.answer_boolean)
                elseif answer.answer_number ~= nil then
                    actual = tostring(answer.answer_number)
                else
                    actual = ""
                end
                local expected = tostring(rule.expected_value or "")

                local num_actual = tonumber(actual) or 0
                local num_expected = tonumber(expected) or 0

                if rule.operator == "equals" then
                    match = actual == expected
                elseif rule.operator == "not_equals" then
                    match = actual ~= expected
                elseif rule.operator == "greater_than" then
                    match = num_actual > num_expected
                elseif rule.operator == "less_than" then
                    match = num_actual < num_expected
                elseif rule.operator == "greater_than_or_equal" then
                    match = num_actual >= num_expected
                elseif rule.operator == "less_than_or_equal" then
                    match = num_actual <= num_expected
                elseif rule.operator == "contains" then
                    match = actual:lower():find(expected:lower(), 1, true) ~= nil
                elseif rule.operator == "in_list" then
                    for item in expected:gmatch("[^,]+") do
                        if actual == item:match("^%s*(.-)%s*$") then
                            match = true
                            break
                        end
                    end
                elseif rule.operator == "is_not_empty" then
                    match = actual ~= "" and actual ~= "nil"
                elseif rule.operator == "is_empty" then
                    match = actual == "" or actual == "nil"
                end
            end

            if match then
                tags_to_add[rule.tag_id] = rule.tag_slug
            else
                tags_to_remove[rule.tag_id] = rule.tag_slug
            end
        end

        -- Remove tags that no longer match (only auto-assigned ones)
        for tag_id, _ in pairs(tags_to_remove) do
            if not tags_to_add[tag_id] then
                pcall(db.query, [[
                    DELETE FROM user_profile_tags
                    WHERE user_id = ? AND tag_id = ? AND assignment_source = 'auto'
                ]], user_id, tag_id)
            end
        end

        -- Add tags that match
        for tag_id, _ in pairs(tags_to_add) do
            local ok_tag, tag_err = pcall(db.query, [[
                INSERT INTO user_profile_tags (uuid, user_id, user_uuid, tag_id, assigned_by, assignment_source, is_active, created_at, updated_at)
                VALUES (gen_random_uuid()::text, ?, ?, ?, ?, 'auto', true, NOW(), NOW())
                ON CONFLICT (user_id, tag_id) DO UPDATE SET
                    assignment_source = 'auto',
                    is_active = true,
                    updated_at = NOW()
            ]], user_id, user_uuid, tag_id, user_id)
            if not ok_tag then
                ngx.log(ngx.ERR, "[ProfileBuilder] auto-tag assign failed for tag_id=", tag_id, ": ", tostring(tag_err))
            end
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "[ProfileBuilder] evaluateTagRules failed: ", tostring(err))
    end
end

-- Get user's assigned tags
local function getUserTags(user_id)
    local ok, rows = pcall(db.query, [[
        SELECT pt.uuid, pt.name, pt.slug, pt.color, pt.tag_type, pt.description,
               upt.assignment_source, upt.created_at as assigned_at
        FROM user_profile_tags upt
        JOIN profile_tags pt ON pt.id = upt.tag_id
        WHERE upt.user_id = ? AND pt.is_active = true
        ORDER BY pt.name ASC
    ]], user_id)
    if ok and rows then return rows end
    return {}
end

-- ─── Business-profile linkage helpers ──────────────────────────────────────
-- A question can be tagged with one or more business profile keys
-- (amazon_seller, landlord, sole_trader, …) — see migration step 36
-- (table profile_question_business_profiles, PK on (question_id, profile_key)).
--
-- Semantics: empty link set => question applies to ALL profiles. Non-empty =>
-- gates user-facing visibility to users whose tax_user_profiles.default_profile_key
-- is in the set.

-- Load the keys for ONE question. Returns an empty array on failure or no
-- linkage so callers can always treat the result as "applies to all".
local function loadQuestionBusinessProfiles(question_id)
    if not question_id then return {} end
    local ok, rows = pcall(db.query, [[
        SELECT profile_key FROM profile_question_business_profiles
        WHERE question_id = ? ORDER BY profile_key ASC
    ]], question_id)
    if not ok or not rows then return {} end
    local out = {}
    for i = 1, #rows do out[i] = rows[i].profile_key end
    return out
end

-- Bulk-load for the list endpoint — avoids the N+1 query pattern when
-- attaching business_profiles to dozens of questions in one response.
-- Returns a table indexed by question_id where each value is the array of
-- profile_keys for that question (always an array, never nil).
local function bulkLoadQuestionBusinessProfiles(question_ids)
    local out = {}
    if not question_ids or #question_ids == 0 then return out end
    -- Build the ANY($1::int[]) placeholder once, regardless of count.
    local placeholders = {}
    for i = 1, #question_ids do placeholders[i] = "?" end
    local sql = [[
        SELECT question_id, profile_key
        FROM profile_question_business_profiles
        WHERE question_id IN (]] .. table.concat(placeholders, ",") .. [[)
        ORDER BY question_id, profile_key
    ]]
    local ok, rows = pcall(db.query, sql, unpack(question_ids))
    if not ok or not rows then return out end
    for _, row in ipairs(rows) do
        local qid = row.question_id
        if not out[qid] then out[qid] = {} end
        out[qid][#out[qid] + 1] = row.profile_key
    end
    return out
end

-- Atomic write: replace the entire link set for one question. Caller passes
-- an array of profile_keys (or nil/empty to clear all links). De-duplicates,
-- trims, and shape-validates keys so the table never accumulates garbage.
--
-- Validation:
--   - Must be a string.
--   - After trimming, must match lower_snake_case (^[a-z][a-z0-9_]*$),
--     mirroring the convention used by register.lua's default_profile_key
--     and by FastAPI's profile_loader. Anything else is silently dropped
--     and logged at WARN — the admin UI's multi-select is catalogue-driven
--     so this only fires for direct API abuse.
--   - Length bounded to 100 chars (matches the schema VARCHAR limit).
--
-- Existence in the catalogue (DB classification_profiles + filesystem
-- profiles) is NOT validated here — Lua has no access to the FastAPI
-- registry. The admin UI enforces that contract.
local function replaceQuestionBusinessProfiles(question_id, keys)
    if not question_id then return end
    -- Always remove first so an empty input correctly clears the link set.
    db.query("DELETE FROM profile_question_business_profiles WHERE question_id = ?", question_id)
    if not keys or type(keys) ~= "table" or #keys == 0 then return end

    local seen = {}
    for _, raw in ipairs(keys) do
        if type(raw) == "string" then
            local key = raw:match("^%s*(.-)%s*$") -- trim
            if not key or key == "" or #key > 100 then
                if key and key ~= "" then
                    ngx.log(ngx.WARN, "[ProfileBuilder] dropping over-long business_profile key (len=", #key, ")")
                end
            elseif not key:match("^[a-z][a-z0-9_]*$") then
                ngx.log(ngx.WARN, "[ProfileBuilder] dropping malformed business_profile key: ", key)
            elseif not seen[key] then
                seen[key] = true
                local ok_ins = pcall(db.query, [[
                    INSERT INTO profile_question_business_profiles (question_id, profile_key, created_at)
                    VALUES (?, ?, NOW())
                    ON CONFLICT (question_id, profile_key) DO NOTHING
                ]], question_id, key)
                if not ok_ins then
                    ngx.log(ngx.WARN, "[ProfileBuilder] failed to insert business_profile link q=", question_id, " key=", key)
                end
            end
        end
    end
end

-- Evaluate a set of rules of a given type against the user's answer map.
--
-- This is the single source of truth for AND/OR / operator semantics —
-- both the visibility gate (rule_type='visibility') and the dynamic
-- requirement gate (rule_type='requirement') share it. Adding a future
-- rule_type (e.g. 'validation') plugs in by passing the new type string
-- without touching the operator table below.
--
-- Defaults must reflect rule SEMANTICS, not just absence:
--   * For visibility, "no rules" = visible (open by default).
--   * For requirement, "no rules" = NOT dynamically required (the
--     static is_required column handles the baseline).
-- Callers pass ``default_on_empty`` to control this.
--
-- Failure mode (query errored): we log loudly and return ``fail_safe``,
-- which the caller chooses to fit its own safety stance. Visibility
-- defaults fail-safe = true so users aren't locked out of questions
-- they can't see. Requirement defaults fail-safe = false so a transient
-- DB hiccup never inflates the gate denominator.
local function evaluateRuleSet(question_id, answer_map, rule_type,
                               default_on_empty, fail_safe)
    -- Use ``priority`` for the within-group ordering — that's the
    -- actual column on profile_question_rules. The original code used
    -- ``display_order``, which doesn't exist on this table, so the
    -- pcall would silently swallow the SQL error and the function
    -- would fall through to the early-return at "no rules" and treat
    -- the question as always-visible. Net effect: server-side
    -- visibility rules were a no-op for every conditional question,
    -- which surfaced as frontend-says-100-backend-says-96 mismatches
    -- in the completion gate.
    local ok, rules = pcall(db.query, [[
        SELECT rule_type, operator, expected_value, source_question_id, logic_group
        FROM profile_question_rules
        WHERE question_id = ? AND is_active = true AND rule_type = ?
        ORDER BY logic_group ASC, priority ASC
    ]], question_id, rule_type)
    if not ok then
        ngx.log(ngx.ERR, "[ProfileBuilder] evaluateRuleSet(",
            tostring(rule_type), ") query failed for question_id=",
            tostring(question_id), ": ", tostring(rules))
        return fail_safe
    end
    if not rules or #rules == 0 then
        return default_on_empty
    end

    -- Group rules by logic_group
    local groups = {}
    for _, r in ipairs(rules) do
        local g = r.logic_group or "AND"
        if not groups[g] then groups[g] = {} end
        table.insert(groups[g], r)
    end

    -- Evaluate AND groups (all must pass) and OR groups (any must pass)
    local and_result = true
    local or_result = false
    local has_or = false

    -- Boolean-aware equality. Rules authored against Yes/No questions
    -- store expected_value = "yes" / "no" (admin UI default), but the
    -- stored answer comes through as a boolean -> tostring("true").
    -- Naive ``actual == expected`` would never match "true" against
    -- "yes", so this helper normalises common yes/no/true/false/1/0
    -- spellings to a canonical bool on both sides before comparing.
    -- Falls back to lowercase string compare for non-boolean rules.
    local function parseBoolish(s)
        if s == nil then return nil end
        local lower = tostring(s):lower():gsub("^%s+", ""):gsub("%s+$", "")
        if lower == "true" or lower == "yes" or lower == "1" or lower == "y" then return true end
        if lower == "false" or lower == "no" or lower == "0" or lower == "n" then return false end
        return nil
    end
    local function looseEquals(a, b)
        local ab, bb = parseBoolish(a), parseBoolish(b)
        if ab ~= nil and bb ~= nil then return ab == bb end
        return tostring(a or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
            == tostring(b or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    end

    for group_name, group_rules in pairs(groups) do
        for _, rule in ipairs(group_rules) do
            local answer = answer_map[rule.source_question_id]
            local actual = ""
            if answer then
                if answer.answer_text and answer.answer_text ~= "" then
                    actual = answer.answer_text
                elseif answer.answer_boolean ~= nil then
                    actual = tostring(answer.answer_boolean)
                elseif answer.answer_number ~= nil then
                    actual = tostring(answer.answer_number)
                end
            end
            local expected = tostring(rule.expected_value or "")

            local match = false
            local num_actual = tonumber(actual) or 0
            local num_expected = tonumber(expected) or 0

            if rule.operator == "equals" then
                match = looseEquals(actual, expected)
            elseif rule.operator == "not_equals" then
                match = not looseEquals(actual, expected)
            elseif rule.operator == "greater_than" then
                match = num_actual > num_expected
            elseif rule.operator == "less_than" then
                match = num_actual < num_expected
            elseif rule.operator == "greater_than_or_equal" then
                match = num_actual >= num_expected
            elseif rule.operator == "less_than_or_equal" then
                match = num_actual <= num_expected
            elseif rule.operator == "between" then
                -- expected_value format: "min,max"
                local parts = {}
                for p in expected:gmatch("[^,]+") do table.insert(parts, tonumber(p:match("^%s*(.-)%s*$")) or 0) end
                if #parts >= 2 then match = num_actual >= parts[1] and num_actual <= parts[2] end
            elseif rule.operator == "in_list" then
                for item in expected:gmatch("[^,]+") do
                    if looseEquals(actual, item:match("^%s*(.-)%s*$")) then match = true; break end
                end
            elseif rule.operator == "not_in_list" then
                match = true
                for item in expected:gmatch("[^,]+") do
                    if looseEquals(actual, item:match("^%s*(.-)%s*$")) then match = false; break end
                end
            elseif rule.operator == "contains" then
                match = actual:lower():find(expected:lower(), 1, true) ~= nil
            elseif rule.operator == "not_contains" then
                match = actual:lower():find(expected:lower(), 1, true) == nil
            elseif rule.operator == "starts_with" then
                match = actual:sub(1, #expected):lower() == expected:lower()
            elseif rule.operator == "ends_with" then
                match = actual:sub(-#expected):lower() == expected:lower()
            elseif rule.operator == "matches_regex" then
                local ok_match = pcall(function() match = actual:match(expected) ~= nil end)
                if not ok_match then match = false end
            elseif rule.operator == "is_empty" then
                match = actual == "" or actual == "nil"
            elseif rule.operator == "is_not_empty" then
                match = actual ~= "" and actual ~= "nil"
            end

            if group_name == "OR" then
                has_or = true
                if match then or_result = true end
            else
                if not match then and_result = false end
            end
        end
    end

    if has_or then
        return and_result and or_result
    end
    return and_result
end

-- Thin wrappers — keep the call sites readable + lock in the semantic
-- defaults for each rule_type. New rule types should add a wrapper here
-- (not call evaluateRuleSet directly) so the defaults stay near the
-- definition.
--
-- These are ASSIGNED to the forward-declared locals at the top of the
-- file (not ``local function`` declarations) so any function defined
-- earlier in the chunk (e.g. recalculateCompletion) can capture them
-- as upvalues.
evaluateVisibility = function(question_id, answer_map)
    -- No rules → visible. Query failure → visible (don't lock out).
    return evaluateRuleSet(question_id, answer_map, "visibility", true, true)
end

evaluateRequirement = function(question_id, answer_map)
    -- No rules → NOT dynamically required (static is_required is the
    -- baseline). Query failure → not required (don't inflate the gate
    -- denominator on a transient DB hiccup; the user is the one who'd
    -- pay for that with a stuck cookie).
    return evaluateRuleSet(question_id, answer_map, "requirement", false, false)
end

local function getUserIdByUuid(user_uuid)
    local ok, rows = pcall(db.query, "SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    if ok and rows and #rows > 0 then
        return rows[1].id
    end
    return nil
end

local function getClientIp()
    return ngx.var.remote_addr or "unknown"
end

local PREFIX = "/api/v2/profile-builder"

-- =========================================================================
-- Route definitions
-- =========================================================================

return function(app)

    -- =====================================================================
    -- 1. GET /schema — Full schema for end-user
    -- =====================================================================
    app:get(PREFIX .. "/schema", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        local namespace_id = getNamespaceId(self)

        -- Include global categories (namespace_id = 0) and user's namespace categories
        local ns_filter = ""
        if namespace_id and namespace_id > 0 then
            ns_filter = " AND (namespace_id = " .. db.escape_literal(namespace_id) .. " OR namespace_id = 0)"
        end
        local ok_cats, categories = pcall(db.query, [[
            SELECT * FROM profile_categories
            WHERE is_active = true AND is_archived = false
            ]] .. ns_filter .. [[
            ORDER BY display_order ASC, name ASC
        ]])
        if not ok_cats then
            ngx.log(ngx.ERR, "[ProfileBuilder] schema categories query failed: ", tostring(categories))
            return { status = 500, json = { error = "Failed to load schema" } }
        end

        -- Pre-load all user answers indexed by question_id (include drafts for visibility/completion)
        local answer_map = {}
        if user_id then
            local ok_all_ans, all_ans = pcall(db.query, [[
                SELECT question_id, answer_text, answer_number, answer_boolean, answer_date, answer_json
                FROM user_profile_answers
                WHERE user_id = ?
            ]], user_id)
            if ok_all_ans and all_ans then
                for _, a in ipairs(all_ans) do
                    answer_map[a.question_id] = a
                end
            end
        end

        -- Resolve the user's business profile (e.g. amazon_seller, landlord)
        -- AND their identity-lock state in the same query (one DB round-trip
        -- instead of two).
        --
        -- Business profile is used below to gate which questions appear in
        -- the schema. Lock state is used to render `is_locked_for_user` on
        -- each NINO/UTR question so the FE can disable the field without
        -- probing a write and catching a 403.
        --
        -- Both fields fall through gracefully when the user has no
        -- tax_user_profiles row yet (new user → everything unlocked, no
        -- profile-key gating).
        local user_profile_key = nil
        local user_nino_locked_at = nil
        local user_utr_locked_at = nil
        if user_id then
            local ok_up, up_rows = pcall(db.query, [[
                SELECT default_profile_key, nino_locked_at, utr_locked_at
                FROM tax_user_profiles
                WHERE user_id = ? LIMIT 1
            ]], user_id)
            if ok_up and up_rows and #up_rows > 0 then
                local k = up_rows[1].default_profile_key
                if k and k ~= "" and k ~= cjson.null then
                    user_profile_key = k
                end
                user_nino_locked_at = up_rows[1].nino_locked_at
                user_utr_locked_at  = up_rows[1].utr_locked_at
            end
        end

        local result = {}
        for _, cat in ipairs(categories or {}) do
            -- Filter clause shape changes depending on whether the user has
            -- a profile_key. The link table is small (n_questions × few keys)
            -- and indexed on profile_key, so the NOT EXISTS / EXISTS combo
            -- is fast enough to inline per-category.
            local ok_q, questions
            if user_profile_key then
                ok_q, questions = pcall(db.query, [[
                    SELECT * FROM profile_questions pq
                    WHERE pq.category_id = ?
                      AND pq.is_active = true
                      AND pq.is_archived = false
                      AND (
                        NOT EXISTS (
                          SELECT 1 FROM profile_question_business_profiles
                          WHERE question_id = pq.id
                        )
                        OR EXISTS (
                          SELECT 1 FROM profile_question_business_profiles
                          WHERE question_id = pq.id AND profile_key = ?
                        )
                      )
                    ORDER BY pq.display_order ASC, pq.label ASC
                ]], cat.id, user_profile_key)
            else
                -- No profile chosen yet: only show questions that apply to
                -- everyone. Once the user picks a profile in /profile or
                -- /settings, profile-specific questions reveal themselves
                -- on the next schema fetch.
                ok_q, questions = pcall(db.query, [[
                    SELECT * FROM profile_questions pq
                    WHERE pq.category_id = ?
                      AND pq.is_active = true
                      AND pq.is_archived = false
                      AND NOT EXISTS (
                        SELECT 1 FROM profile_question_business_profiles
                        WHERE question_id = pq.id
                      )
                    ORDER BY pq.display_order ASC, pq.label ASC
                ]], cat.id)
            end
            if not ok_q then
                ngx.log(ngx.ERR, "[ProfileBuilder] schema questions query failed: ", tostring(questions))
                questions = {}
            end

            local q_list = {}
            for _, q in ipairs(questions or {}) do
                local ok_opts, options = pcall(db.query, [[
                    SELECT * FROM profile_question_options
                    WHERE question_id = ? AND is_active = true
                    ORDER BY display_order ASC, label ASC
                ]], q.id)
                if not ok_opts then options = {} end

                -- Use pre-loaded answer from answer_map
                local answer = answer_map[q.id]

                -- Evaluate visibility rules server-side
                local is_visible = evaluateVisibility(q.id, answer_map)

                -- Load rules for client-side real-time evaluation
                local rule_list = {}
                local ok_rules, q_rules = pcall(db.query, [[
                    SELECT pqr.uuid, pqr.rule_type, pqr.operator, pqr.logic_group,
                           pqr.expected_value, pqr.expected_values_json, pqr.priority,
                           pq_src.question_key as source_question_key,
                           pq_src.uuid as source_question_uuid
                    FROM profile_question_rules pqr
                    LEFT JOIN profile_questions pq_src ON pq_src.id = pqr.source_question_id
                    WHERE pqr.question_id = ? AND pqr.is_active = true
                    ORDER BY pqr.priority ASC
                ]], q.id)
                if ok_rules and q_rules then
                    for _, r in ipairs(q_rules) do
                        table.insert(rule_list, {
                            uuid = r.uuid,
                            rule_type = r.rule_type,
                            operator = r.operator,
                            logic_group = r.logic_group or "AND",
                            expected_value = r.expected_value,
                            expected_values_json = r.expected_values_json,
                            source_question_key = r.source_question_key,
                            source_question_uuid = r.source_question_uuid,
                            is_active = true, -- only active rules are returned
                        })
                    end
                end

                local opt_list = {}
                for _, o in ipairs(options or {}) do
                    table.insert(opt_list, {
                        uuid = o.uuid,
                        label = o.label,
                        value = o.value,
                        description = o.description,
                        display_order = o.display_order,
                        is_default = o.is_default,
                        is_active = o.is_active,
                        parent_option_id = o.parent_option_id,
                        metadata_json = o.metadata_json
                    })
                end

                -- Catalogue-sourced options: a question can pull its options live
                -- from a catalogue via config_json {"options_source":"income_types"},
                -- keeping a single source of truth instead of duplicating catalogue
                -- rows into profile_question_options.
                if q.config_json and q.config_json ~= "" then
                    local ok_cfg, cfg = pcall(cjson.decode, q.config_json)
                    if ok_cfg and type(cfg) == "table" and cfg.options_source == "income_types" then
                        local ok_it, it_rows = pcall(db.query, [[
                            SELECT uuid, income_type_key AS value, display_name AS label, display_order
                            FROM income_types WHERE is_active = true
                            ORDER BY display_order ASC, display_name ASC
                        ]])
                        if ok_it and it_rows then
                            opt_list = {}
                            for _, it in ipairs(it_rows) do
                                table.insert(opt_list, {
                                    uuid = it.uuid, value = it.value, label = it.label,
                                    display_order = it.display_order, is_active = true,
                                })
                            end
                        end
                    end
                end

                -- Identity-lock per-user computed flag. For NINO/UTR
                -- question_keys, resolves to true iff the user has already
                -- saved that field once (nino_locked_at / utr_locked_at is
                -- non-null on their tax_user_profiles row). Other questions
                -- are always false — this flag is orthogonal to the
                -- question-level `is_editable_by_user` admin flag.
                -- FE reads (is_locked_for_user OR NOT is_editable_by_user)
                -- to decide whether to disable the input.
                local is_locked_for_user = false
                local lock_field = LOCK_FIELD_BY_QUESTION_KEY[q.question_key]
                if lock_field == "nino" and user_nino_locked_at then
                    is_locked_for_user = true
                elseif lock_field == "utr" and user_utr_locked_at then
                    is_locked_for_user = true
                end

                table.insert(q_list, {
                    uuid = q.uuid,
                    question_key = q.question_key,
                    label = q.label,
                    description = q.description,
                    help_text = q.help_text,
                    placeholder = q.placeholder,
                    question_type = q.question_type,
                    is_required = q.is_required,
                    is_multi_value = q.is_multi_value,
                    is_editable_by_user = q.is_editable_by_user,
                    is_locked_for_user = is_locked_for_user,
                    is_visible = is_visible,
                    display_order = q.display_order,
                    validation_json = q.validation_json,
                    default_value = q.default_value,
                    config_json = q.config_json,
                    version = q.version,
                    options = opt_list,
                    rules = rule_list,
                    current_answer = answer and {
                        uuid = answer.uuid,
                        answer_text = answer.answer_text,
                        answer_number = answer.answer_number,
                        answer_boolean = answer.answer_boolean,
                        answer_date = answer.answer_date,
                        answer_json = answer.answer_json,
                        answer_file_url = answer.answer_file_url,
                        is_draft = answer.is_draft,
                        answered_at = answer.answered_at
                    } or nil
                })
            end

            local completion = nil
            if user_id then
                local ok_comp, comp_rows = pcall(db.query, [[
                    SELECT * FROM profile_completion_status
                    WHERE user_id = ? AND category_id = ?
                    LIMIT 1
                ]], user_id, cat.id)
                if ok_comp and comp_rows and #comp_rows > 0 then
                    local c = comp_rows[1]
                    completion = {
                        total_questions = c.total_questions,
                        answered_questions = c.answered_questions,
                        required_questions = c.required_questions,
                        required_answered = c.required_answered,
                        completion_percent = c.completion_percent,
                        status = c.status
                    }
                end
            end

            table.insert(result, {
                uuid = cat.uuid,
                name = cat.name,
                slug = cat.slug,
                description = cat.description,
                icon = cat.icon,
                display_order = cat.display_order,
                parent_id = cat.parent_id,
                visibility_rule_json = cat.visibility_rule_json,
                completion_rule_json = cat.completion_rule_json,
                questions = q_list,
                completion = completion
            })
        end

        -- Get user tags
        local user_tags = {}
        if user_id then
            user_tags = getUserTags(user_id)
        end

        -- Calculate overall completion
        local overall_completion = { total = 0, answered = 0, percent = 0 }
        for _, cat in ipairs(result) do
            if cat.completion then
                overall_completion.total = overall_completion.total + (cat.completion.total_questions or 0)
                overall_completion.answered = overall_completion.answered + (cat.completion.answered_questions or 0)
            else
                overall_completion.total = overall_completion.total + #cat.questions
            end
        end
        if overall_completion.total > 0 then
            overall_completion.percent = math.floor((overall_completion.answered / overall_completion.total) * 100)
        end

        return {
            status = 200,
            json = {
                schema = result,
                user_tags = user_tags,
                overall_completion = overall_completion
            }
        }
    end)

    -- =====================================================================
    -- 1b. GET /completion-status — Lightweight authoritative completion check
    --
    -- Single source of truth for "has this user finished the profile?".
    -- The /schema endpoint is heavy (full question tree, options, rules,
    -- per-category state) and was the wrong shape for "is this user
    -- done?" calls fired from the gate / Go-to-dashboard button.
    --
    -- This endpoint:
    --   1. Reads the user's answers + every active question in their
    --      namespace (global + per-tenant).
    --   2. Evaluates visibility per question using the same rules engine
    --      that the schema endpoint uses (after the boolean-aware
    --      ``looseEquals`` fix). Conditionally-hidden questions don't
    --      count in numerator OR denominator.
    --   3. Counts answered (non-null answer column) over visible total.
    --   4. Sets the ``profile_complete=true`` cookie (or clears it) so
    --      the Next.js middleware can hard-gate routes WITHOUT calling
    --      back into opsapi on every request.
    --   5. Returns ``{ is_complete, overall_percent, total, answered }``
    --      so the frontend can show a coherent state to the user.
    --
    -- Cookie is set with ``Path=/; SameSite=Lax`` and NO ``HttpOnly`` —
    -- the cookie is UX (a gating hint), not credentials. The actual
    -- authority remains this endpoint plus the same server-side
    -- per-route checks any feature-flag would have. Cookie expiry is
    -- session-only so a logout flushes the verdict naturally.
    -- =====================================================================
    app:get(PREFIX .. "/completion-status", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end
        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 401, json = { error = "User not found" } }
        end
        local namespace_id = getNamespaceId(self)

        -- Build the same namespace filter the schema endpoint uses so
        -- visibility is computed against EXACTLY the questions the user
        -- can see. Empty filter = the lapis global default scope.
        local ns_filter = ""
        if namespace_id and namespace_id > 0 then
            ns_filter = " AND (pq.namespace_id = " .. db.escape_literal(namespace_id) .. " OR pq.namespace_id = 0)"
        end

        -- Single answer_map used for BOTH visibility rule evaluation
        -- AND the answered count. Drafts are treated as real answers
        -- here on purpose: the frontend's isAnswered only checks for a
        -- non-empty value (not is_draft), and the user's perception is
        -- "I typed something in that box, it's answered". The is_draft
        -- flag is orthogonal — it tracks "the text field's value may
        -- still change as the user keeps typing", not "this isn't a
        -- real answer". The existing recalculateCompletion() helper
        -- filters drafts for a different signal ("officially committed
        -- answers used by tag rules"), but the gate cookie must match
        -- what the user sees on the /profile UI — otherwise text-only
        -- categories sit at 0% on the server while showing 100% to
        -- the user, exactly the trap we just hit.
        local answer_map = {}
        local ok_ans, ans_rows = pcall(db.query, [[
            SELECT question_id, answer_text, answer_number, answer_boolean,
                   answer_date, answer_json
            FROM user_profile_answers
            WHERE user_id = ?
        ]], user_id)
        if ok_ans and ans_rows then
            for _, a in ipairs(ans_rows) do
                answer_map[a.question_id] = a
            end
        end

        -- Resolve the user's business profile (e.g. amazon_seller,
        -- landlord). The schema endpoint uses this exact pattern to
        -- gate which questions ever surface in the UI:
        --
        --   * a question with NO business-profile tags applies to everyone
        --   * a question with tags only appears if the user's
        --     default_profile_key is in that set
        --
        -- Without applying the same filter here, completion-status
        -- inflates ``total`` with questions the user can never see —
        -- e.g. amazon_seller users were being counted on
        -- ``is_construction_worker`` (tagged construction_company)
        -- and the gate said 26/27 = 96% even though the frontend
        -- showed 100% (because frontend honours the tag filter via
        -- the schema response).
        --
        -- This mirrors lines 615-635 / 645-675 of the schema endpoint
        -- below; keep them in lock-step. ``default_profile_key`` is
        -- the singular wizard-primary pick (the wizard mirrors
        -- is_primary→default_profile_key on save, so this stays the
        -- right key to consult for non-multi-pick gating).
        local user_profile_key = nil
        local ok_up, up_rows = pcall(db.query, [[
            SELECT default_profile_key FROM tax_user_profiles
            WHERE user_id = ? LIMIT 1
        ]], user_id)
        if ok_up and up_rows and #up_rows > 0 then
            local k = up_rows[1].default_profile_key
            if k and k ~= "" and k ~= cjson.null then
                user_profile_key = k
            end
        end

        -- Active, non-archived questions in the user's scope, with the
        -- business-profile tag filter applied. Include question_key +
        -- label so ?debug=true can name them; cheap columns, no
        -- measurable perf impact.
        local bp_filter
        local query_params = {}
        if user_profile_key then
            bp_filter = [[
              AND (
                NOT EXISTS (
                  SELECT 1 FROM profile_question_business_profiles
                  WHERE question_id = pq.id
                )
                OR EXISTS (
                  SELECT 1 FROM profile_question_business_profiles
                  WHERE question_id = pq.id AND profile_key = ?
                )
              )]]
            table.insert(query_params, user_profile_key)
        else
            -- No business profile chosen yet: only universal questions
            -- (with no tag link set) surface. Strictest filter; matches
            -- schema endpoint's same-branch behaviour.
            bp_filter = [[
              AND NOT EXISTS (
                SELECT 1 FROM profile_question_business_profiles
                WHERE question_id = pq.id
              )]]
        end

        local ok_qs, questions = pcall(db.query, [[
            SELECT pq.id, pq.question_key, pq.label, pq.is_required
            FROM profile_questions pq
            JOIN profile_categories pc ON pc.id = pq.category_id
            WHERE pq.is_active = true AND pq.is_archived = false
              AND pc.is_active = true AND pc.is_archived = false
            ]] .. ns_filter .. bp_filter, unpack(query_params))
        if not ok_qs then
            ngx.log(ngx.ERR, "[ProfileBuilder] completion-status questions query failed: ", tostring(questions))
            return { status = 500, json = { error = "Failed to compute completion" } }
        end

        -- ?debug=true returns a per-question breakdown alongside the
        -- summary so the next-vs-backend gap can be pinpointed without
        -- adding instrumentation each time something rhymes with this.
        -- Cheap to emit; not gated by admin role because the user only
        -- ever sees their OWN answers.
        local debug_mode = self.params.debug == "true" or self.params.debug == "1"
        local debug_rows = debug_mode and {} or nil

        -- Two parallel counters because the system has two distinct
        -- questions:
        --
        --   "Are all required questions answered?"     → gate
        --   "How far through the whole form is the user?" → display
        --
        -- The denominator differs but the loop is one pass over the same
        -- visible-question set. Optional questions count toward
        -- ``total/answered`` (so the user's progress bar is honest about
        -- what's left) but do NOT count toward ``required_*`` (so they
        -- don't block dashboard access).
        --
        -- ``effectively_required`` combines static + dynamic:
        --   * Static — profile_questions.is_required (admin set this)
        --   * Dynamic — any active requirement rule on this question
        --              fires given the user's current answers
        -- The dynamic side is what catches cases like "Did you have
        -- rental income? → Yes → rental_property_count is now required."
        local total_visible = 0
        local answered = 0
        local required_visible = 0
        local required_answered = 0
        for _, q in ipairs(questions or {}) do
            local is_visible = evaluateVisibility(q.id, answer_map)
            local a = answer_map[q.id]   -- drafts INCLUDED — see note above answer_map
            local has_answer = false
            if a then
                has_answer = (a.answer_text ~= nil and a.answer_text ~= "")
                    or a.answer_number ~= nil
                    or a.answer_boolean ~= nil
                    or a.answer_date ~= nil
                    or (a.answer_json ~= nil and a.answer_json ~= "" and a.answer_json ~= "null" and a.answer_json ~= "[]")
            end
            local effectively_required = false
            if is_visible then
                total_visible = total_visible + 1
                if has_answer then
                    answered = answered + 1
                end
                -- Skip the requirement-rule query when the static flag
                -- already settles it true — fewer DB hits per request
                -- on the typical schema where most required questions
                -- have no dynamic rule.
                effectively_required = q.is_required
                    or evaluateRequirement(q.id, answer_map)
                if effectively_required then
                    required_visible = required_visible + 1
                    if has_answer then
                        required_answered = required_answered + 1
                    end
                end
            end
            if debug_mode then
                -- Stringify each answer column so the response is
                -- safe to JSON-encode regardless of underlying type
                -- (booleans / numbers / pgmoon's NULL sentinel).
                local function show(v)
                    if v == nil then return nil end
                    if type(v) == "boolean" then return tostring(v) end
                    if type(v) == "number" then return v end
                    return tostring(v)
                end
                table.insert(debug_rows, {
                    question_id = q.id,
                    question_key = q.question_key,
                    label = q.label,
                    is_required = q.is_required,
                    effectively_required = effectively_required,
                    is_visible = is_visible,
                    has_answer = has_answer,
                    counted_in_total = is_visible,
                    counted_in_answered = is_visible and has_answer,
                    counted_in_required = is_visible and effectively_required,
                    counted_in_required_answered = is_visible and effectively_required and has_answer,
                    answer = a and {
                        answer_text = show(a.answer_text),
                        answer_number = show(a.answer_number),
                        answer_boolean = show(a.answer_boolean),
                        answer_date = show(a.answer_date),
                        answer_json = show(a.answer_json),
                    } or nil,
                })
            end
        end

        -- Display percent — across ALL visible questions, so the
        -- progress bar honestly tells the user how much of the form
        -- has been filled in.
        local pct
        if total_visible == 0 then
            pct = 100
        else
            pct = math.floor((answered / total_visible) * 100)
        end

        -- Gate percent — only required-visible questions count.
        -- Vacuously 100 when there are no required questions in the
        -- user's scope (could happen for users with a business profile
        -- that only has optional questions, or for a freshly seeded
        -- schema with everything optional).
        local required_pct
        if required_visible == 0 then
            required_pct = 100
        else
            required_pct = math.floor((required_answered / required_visible) * 100)
        end

        -- The cookie + downstream "is_complete" gate is REQUIRED-ONLY.
        -- The display percent is independent and may stay below 100
        -- when the user has skipped optionals — that's a deliberate
        -- UX signal ("you've finished what's mandatory; here's what
        -- else you could add"), not a bug.
        local is_complete = required_visible == 0
                         or required_answered >= required_visible

        -- Two cookies — both onboarding-state gates the Next.js
        -- middleware reads verbatim:
        --   * profile_complete       — all visible/required questions answered
        --   * business_profile_set   — user picked at least one business type
        --                              (default_profile_key set on tax_user_profiles)
        --
        -- Set together in one response so the middleware never sees a
        -- half-state. Clearing uses Max-Age=0 so the browser drops the
        -- cookie immediately rather than waiting for session end.
        --
        -- Domain resolution — three sources of truth, first match wins:
        --   1. AUTH_COOKIE_DOMAIN              (explicit override)
        --   2. AUTH_COOKIE_TRUSTED_DOMAINS     (Origin allowlist —
        --                                       matches auth-cookies.lua)
        --   3. FRONTEND_URL                    (derived parent domain;
        --                                       a no-extra-config
        --                                       fallback so envs that
        --                                       only set FRONTEND_URL —
        --                                       like int — still emit
        --                                       a cross-subdomain
        --                                       cookie that the
        --                                       frontend middleware
        --                                       can actually read)
        -- No source → omit Domain (host-scoped — correct for local dev
        -- where api + app share the same host:port).
        --
        -- Why the FRONTEND_URL fallback exists: ops on int forgot to
        -- set AUTH_COOKIE_TRUSTED_DOMAINS but FRONTEND_URL was always
        -- there. Without a Domain attribute the cookie scoped to
        -- int-api.X only — the middleware on int.X never saw it →
        -- every navigation bounced back to /profile. The 3rd source
        -- closes that gap without adding a new env var to operators'
        -- runbooks.
        --
        -- Secure default-on; AUTH_COOKIE_INSECURE=true opts out for
        -- localhost HTTP. Same flag the refresh-token cookie honours.
        local has_business_profile = user_profile_key ~= nil

        local cookie_domain
        do
            -- Source 1: explicit override
            local override = os.getenv("AUTH_COOKIE_DOMAIN")
            if override and override ~= "" then
                cookie_domain = override
            end

            -- Source 2: trusted-domains allowlist matched against Origin
            if not cookie_domain then
                local raw = os.getenv("AUTH_COOKIE_TRUSTED_DOMAINS") or ""
                local allowed_list = {}
                for item in raw:gmatch("[^,%s]+") do table.insert(allowed_list, item:lower()) end
                local origin = (self.req and self.req.headers and
                    (self.req.headers["Origin"] or self.req.headers["origin"])) or nil
                if origin and #allowed_list > 0 then
                    local host = origin:gsub("^https?://", ""):gsub(":%d+$", ""):gsub("/.*$", ""):lower()
                    local best
                    for _, allowed in ipairs(allowed_list) do
                        local matches = host == allowed
                            or host:sub(-(#allowed + 1)) == "." .. allowed
                        if matches and (not best or #allowed > #best) then best = allowed end
                    end
                    if best then cookie_domain = "." .. best end
                end
            end

            -- Source 3: derive parent domain from FRONTEND_URL.
            -- Strip the first subdomain label so the cookie is visible
            -- on both the API subdomain and the app subdomain (assumed
            -- same parent, which is the standard same-origin-with-api
            -- pattern). E.g. https://int.diytaxreturn.co.uk → strip
            -- "int" → ".diytaxreturn.co.uk".
            -- Skip the strip when the host is already at parent
            -- (≤2 labels — example.com, etc.) because Domain=.com is
            -- rejected by browsers as a public suffix.
            if not cookie_domain then
                local frontend_url = os.getenv("FRONTEND_URL")
                if frontend_url and frontend_url ~= "" then
                    local host = frontend_url
                        :gsub("^https?://", "")
                        :gsub(":%d+$", "")
                        :gsub("/.*$", "")
                        :lower()
                    if host ~= "" then
                        local labels = {}
                        for label in host:gmatch("[^%.]+") do
                            table.insert(labels, label)
                        end
                        -- 3+ labels (foo.example.co.uk) → strip first
                        -- 2 labels (example.com) → leave as host-scoped
                        if #labels >= 3 then
                            local apex = table.concat(labels, ".", 2)
                            cookie_domain = "." .. apex
                        end
                    end
                end
            end
        end

        local secure_attr = os.getenv("AUTH_COOKIE_INSECURE") ~= "true"

        -- Build a single Set-Cookie header value for the given name.
        -- ``is_set=true`` sets the cookie to "true"; ``is_set=false``
        -- clears it via Max-Age=0. Domain/Secure attributes are shared
        -- with the refresh-token cookie (see helper/auth-cookies.lua).
        local function build_cookie(name, is_set)
            local parts = is_set
                and { name .. "=true", "Path=/", "SameSite=Lax" }
                or  { name .. "=",     "Path=/", "Max-Age=0", "SameSite=Lax" }
            if cookie_domain then table.insert(parts, "Domain=" .. cookie_domain) end
            if secure_attr then table.insert(parts, "Secure") end
            return table.concat(parts, "; ")
        end

        -- OpenResty allows ngx.header["Set-Cookie"] to be a table —
        -- each element becomes its own Set-Cookie response header,
        -- which is the correct way to emit multiple cookies in one
        -- response (a single comma-joined value gets misparsed by
        -- some browsers because Set-Cookie values can themselves
        -- contain commas in Expires=...).
        ngx.header["Set-Cookie"] = {
            build_cookie("profile_complete", is_complete),
            build_cookie("business_profile_set", has_business_profile),
        }

        -- Response carries both metrics. Old fields stay so any
        -- existing consumer keeps working; new ``required_*`` fields
        -- are additive. ``is_complete`` is now the required-only
        -- gate (see comment above the cookie block).
        local body = {
            is_complete = is_complete,
            overall_percent = pct,
            total = total_visible,
            answered = answered,
            required_percent = required_pct,
            required_total = required_visible,
            required_answered = required_answered,
            has_business_profile = has_business_profile,
        }
        if debug_mode then body.questions = debug_rows end
        return { status = 200, json = body }
    end)

    -- =====================================================================
    -- 2. GET /schema/preview — Admin: preview schema as a specific user
    -- =====================================================================
    app:get(PREFIX .. "/schema/preview", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local target_uuid = self.params.user_uuid
        if not target_uuid or target_uuid == "" then
            return { status = 400, json = { error = "user_uuid query parameter is required" } }
        end

        local target_user_id = getUserIdByUuid(target_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local namespace_id = getNamespaceId(self)

        -- Include global categories (namespace_id = 0) and user's namespace categories
        local ns_filter = ""
        if namespace_id and namespace_id > 0 then
            ns_filter = " AND (namespace_id = " .. db.escape_literal(namespace_id) .. " OR namespace_id = 0)"
        end
        local ok_cats, categories = pcall(db.query, [[
            SELECT * FROM profile_categories
            WHERE is_active = true AND is_archived = false
            ]] .. ns_filter .. [[
            ORDER BY display_order ASC, name ASC
        ]])
        if not ok_cats then
            return { status = 500, json = { error = "Failed to load schema" } }
        end

        local result = {}
        for _, cat in ipairs(categories or {}) do
            local ok_q, questions = pcall(db.query, [[
                SELECT * FROM profile_questions
                WHERE category_id = ? AND is_active = true AND is_archived = false
                ORDER BY display_order ASC, label ASC
            ]], cat.id)
            if not ok_q then questions = {} end

            local q_list = {}
            for _, q in ipairs(questions or {}) do
                local ok_opts, options = pcall(db.query, [[
                    SELECT * FROM profile_question_options
                    WHERE question_id = ? AND is_active = true
                    ORDER BY display_order ASC, label ASC
                ]], q.id)
                if not ok_opts then options = {} end

                local answer = nil
                local ok_ans, ans_rows = pcall(db.query, [[
                    SELECT * FROM user_profile_answers
                    WHERE user_id = ? AND question_id = ?
                    ORDER BY answered_at DESC LIMIT 1
                ]], target_user_id, q.id)
                if ok_ans and ans_rows and #ans_rows > 0 then
                    answer = ans_rows[1]
                end

                local opt_list = {}
                for _, o in ipairs(options or {}) do
                    table.insert(opt_list, {
                        uuid = o.uuid, label = o.label, value = o.value,
                        description = o.description, display_order = o.display_order,
                        is_default = o.is_default, parent_option_id = o.parent_option_id,
                        metadata_json = o.metadata_json
                    })
                end

                -- Catalogue-sourced options (see GET /schema) — resolve live from
                -- the income_types catalogue when the question opts in via config_json.
                if q.config_json and q.config_json ~= "" then
                    local ok_cfg, cfg = pcall(cjson.decode, q.config_json)
                    if ok_cfg and type(cfg) == "table" and cfg.options_source == "income_types" then
                        local ok_it, it_rows = pcall(db.query, [[
                            SELECT uuid, income_type_key AS value, display_name AS label, display_order
                            FROM income_types WHERE is_active = true
                            ORDER BY display_order ASC, display_name ASC
                        ]])
                        if ok_it and it_rows then
                            opt_list = {}
                            for _, it in ipairs(it_rows) do
                                table.insert(opt_list, {
                                    uuid = it.uuid, value = it.value, label = it.label,
                                    display_order = it.display_order, is_active = true,
                                })
                            end
                        end
                    end
                end

                table.insert(q_list, {
                    uuid = q.uuid, question_key = q.question_key, label = q.label,
                    description = q.description, help_text = q.help_text,
                    placeholder = q.placeholder, question_type = q.question_type,
                    is_required = q.is_required, is_multi_value = q.is_multi_value,
                    is_editable_by_user = q.is_editable_by_user, display_order = q.display_order,
                    validation_json = q.validation_json, default_value = q.default_value,
                    config_json = q.config_json, version = q.version,
                    options = opt_list,
                    answer = answer and {
                        uuid = answer.uuid, answer_text = answer.answer_text,
                        answer_number = answer.answer_number, answer_boolean = answer.answer_boolean,
                        answer_date = answer.answer_date, answer_json = answer.answer_json,
                        answer_file_url = answer.answer_file_url, is_draft = answer.is_draft,
                        answered_at = answer.answered_at
                    } or nil
                })
            end

            local completion = nil
            local ok_comp, comp_rows = pcall(db.query, [[
                SELECT * FROM profile_completion_status
                WHERE user_id = ? AND category_id = ? LIMIT 1
            ]], target_user_id, cat.id)
            if ok_comp and comp_rows and #comp_rows > 0 then
                local c = comp_rows[1]
                completion = {
                    total_questions = c.total_questions, answered_questions = c.answered_questions,
                    required_questions = c.required_questions, required_answered = c.required_answered,
                    completion_percent = c.completion_percent, status = c.status
                }
            end

            table.insert(result, {
                uuid = cat.uuid, name = cat.name, slug = cat.slug,
                description = cat.description, icon = cat.icon,
                display_order = cat.display_order, parent_id = cat.parent_id,
                questions = q_list, completion = completion
            })
        end

        return { status = 200, json = { schema = result, preview_user_uuid = target_uuid } }
    end)

    -- =====================================================================
    -- 2b. GET /business-wizard — tree of pickable business profiles
    --
    -- User-facing endpoint that powers the post-signup business-profile
    -- picker. Returns a nested tree of all classification_profiles rows
    -- that have ``wizard_label`` set, grouped by parent_profile_key:
    --
    --   tree: [
    --     { profile_key: "sole_trader", is_leaf: false,
    --       wizard_question: "What kind of work do you do?",
    --       wizard_label: "I work for myself as a sole trader",
    --       children: [
    --         { profile_key: "sole_trader_tradesperson", is_leaf: false,
    --           children: [
    --             { profile_key: "electrician", is_leaf: true, children: [] },
    --             …
    --           ] },
    --         …
    --       ] },
    --     { profile_key: "ltd_director", is_leaf: true, children: [] },
    --     { profile_key: "landlord",     is_leaf: true, children: [] },
    --     …
    --   ]
    --
    -- The FE walks this once and renders a 3-step wizard (root multi-select
    -- → drill into ticked branches → confirm). Leaves with children = [] are
    -- terminal picks; branches require a follow-up question.
    --
    -- ``wizard_label`` is the discriminator that lets us exclude DB rows
    -- that are catalog-only (rules-pack carriers) rather than wizard-visible.
    -- After migration 450_profile_business_wizard_tree, every active row
    -- has a wizard_label set, so the filter is currently a no-op — but
    -- it keeps the contract future-proof when admins add rule-only rows
    -- via the admin UI without exposing them in onboarding.
    --
    -- Returns the GLOBAL catalogue (namespace_id = 0). Per-tenant overrides
    -- are a future extension once a customer actually needs custom packs.
    -- =====================================================================
    app:get(PREFIX .. "/business-wizard", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        -- COALESCE parent_profile_key to '' so we don't have to fight
        -- pgmoon's NULL representation in Lua (ngx.null vs nil vs cjson.null
        -- depending on driver build) — empty-string is unambiguous.
        local ok, rows = pcall(db.query, [[
            SELECT profile_key,
                   display_name,
                   industry,
                   user_profile_type,
                   COALESCE(parent_profile_key, '') AS parent_profile_key,
                   wizard_question,
                   wizard_label,
                   display_order,
                   is_leaf
            FROM classification_profiles
            WHERE is_active = true
              AND wizard_label IS NOT NULL
              AND wizard_label <> ''
            ORDER BY display_order ASC, profile_key ASC
        ]])
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] business-wizard query failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load business profile wizard" } }
        end

        -- Single-pass build: map profile_key -> node, then a second pass to
        -- attach children to parents. O(n) and order-independent.
        local nodes_by_key = {}
        for _, r in ipairs(rows or {}) do
            nodes_by_key[r.profile_key] = {
                profile_key       = r.profile_key,
                display_name      = r.display_name,
                industry          = r.industry or "",
                user_profile_type = r.user_profile_type or "",
                wizard_question   = r.wizard_question,   -- may be nil for leaves
                wizard_label      = r.wizard_label,
                is_leaf           = (r.is_leaf == true) or (r.is_leaf == "t"),
                display_order     = tonumber(r.display_order) or 0,
                children          = {},
            }
        end

        local roots = {}
        for _, r in ipairs(rows or {}) do
            local node = nodes_by_key[r.profile_key]
            local parent_key = r.parent_profile_key
            if not parent_key or parent_key == "" then
                table.insert(roots, node)
            elseif nodes_by_key[parent_key] then
                table.insert(nodes_by_key[parent_key].children, node)
            else
                -- Parent referenced but parent row not in the visible set
                -- (e.g. parent has wizard_label NULL or is_active false).
                -- Surface as a root so the data isn't lost; log so the
                -- admin notices the inconsistency.
                ngx.log(ngx.WARN, "[ProfileBuilder] orphan wizard node: ",
                        r.profile_key, " (parent ", parent_key,
                        " not in visible set)")
                table.insert(roots, node)
            end
        end

        return { status = 200, json = { tree = roots } }
    end)

    -- =====================================================================
    -- 3. CATEGORIES CRUD
    -- =====================================================================

    -- GET /categories — list
    app:get(PREFIX .. "/categories", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local namespace_id = getNamespaceId(self)
        local include_archived = self.params.include_archived == "true"
        local parent_id = self.params.parent_id

        local where_parts = {}
        local where_vals = {}

        if not include_archived then
            table.insert(where_parts, "is_archived = false")
        end
        if namespace_id and namespace_id > 0 then
            table.insert(where_parts, "(namespace_id = ? OR namespace_id = 0)")
            table.insert(where_vals, namespace_id)
        end
        if parent_id and parent_id ~= "" then
            if parent_id == "null" then
                table.insert(where_parts, "parent_id IS NULL")
            else
                table.insert(where_parts, "parent_id = ?")
                table.insert(where_vals, tonumber(parent_id))
            end
        end

        -- Server-side typeahead. Mirrors the questions endpoint so the
        -- SearchableSelect on the questions modal Category picker can scale
        -- past a small table.
        local search = self.params.search
        if search and search ~= "" then
            local like = "%" .. search .. "%"
            table.insert(where_parts, "(name ILIKE ? OR slug ILIKE ?)")
            table.insert(where_vals, like)
            table.insert(where_vals, like)
        end

        local where_clause = ""
        if #where_parts > 0 then
            where_clause = " WHERE " .. table.concat(where_parts, " AND ")
        end

        -- Paging — same shape and defaults as /questions.
        local limit = tonumber(self.params.limit) or 100
        if limit < 1 then limit = 1 end
        if limit > 500 then limit = 500 end
        local offset = tonumber(self.params.offset) or 0
        if offset < 0 then offset = 0 end

        local sql = "SELECT * FROM profile_categories"
            .. where_clause
            .. " ORDER BY display_order ASC, name ASC LIMIT " .. limit .. " OFFSET " .. offset
        local ok, rows = pcall(db.query, sql, unpack(where_vals))
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] categories list failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load categories" } }
        end

        return { status = 200, json = { categories = rows or {}, total = #(rows or {}) } }
    end)

    -- GET /categories/:uuid — get one with question_count
    app:get(PREFIX .. "/categories/:uuid", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local cat_uuid = self.params.uuid
        local ok, rows = pcall(db.query, "SELECT * FROM profile_categories WHERE uuid = ? LIMIT 1", cat_uuid)
        if not ok then
            return { status = 500, json = { error = "Failed to load category" } }
        end
        if not rows or #rows == 0 then
            return { status = 404, json = { error = "Category not found" } }
        end

        local cat = rows[1]
        local ok_cnt, cnt_rows = pcall(db.query, [[
            SELECT COUNT(*) AS cnt FROM profile_questions
            WHERE category_id = ? AND is_active = true AND is_archived = false
        ]], cat.id)
        cat.question_count = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        return { status = 200, json = { category = cat } }
    end)

    -- POST /categories — create (admin only)
    app:post(PREFIX .. "/categories", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        if not params.name or params.name == "" then
            return { status = 400, json = { error = "name is required" } }
        end
        if not params.slug or params.slug == "" then
            return { status = 400, json = { error = "slug is required" } }
        end

        local namespace_id = getNamespaceId(self)
        local admin_uuid = admin.uuid or admin.id
        local admin_id = resolveUserId(admin_uuid)

        local ok, result = pcall(db.query, [[
            INSERT INTO profile_categories (uuid, namespace_id, name, slug, description, icon, display_order, parent_id, is_active, is_archived, visibility_rule_json, completion_rule_json, created_by, updated_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, true, false, ?, ?, ?, ?, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id or 0,
            params.name or "",
            params.slug or "",
            params.description or db.NULL,
            params.icon or db.NULL,
            params.display_order or 0,
            params.parent_id or db.NULL,
            params.visibility_rule_json or db.NULL,
            params.completion_rule_json or db.NULL,
            admin_id,
            admin_id
        )
        if not ok then
            local err_msg = tostring(result)
            ngx.log(ngx.ERR, "[ProfileBuilder] create category failed: ", err_msg)
            if err_msg:find("duplicate key") or err_msg:find("unique constraint") then
                return { status = 409, json = { error = "A category with this slug already exists" } }
            end
            return { status = 500, json = { error = "Failed to create category" } }
        end

        local cat = result and result[1] or nil
        if cat then
            auditLog({
                namespace_id = namespace_id,
                user_id = admin_uuid,
                action = "create",
                entity_type = "category",
                entity_uuid = cat.uuid,
                old_data_json = nil,
                new_data_json = cjson.encode(cat),
                ip_address = getClientIp()
            })
        end

        return { status = 201, json = { category = cat } }
    end)

    -- PUT /categories/:uuid — update (admin)
    app:put(PREFIX .. "/categories/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local cat_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_categories WHERE uuid = ? LIMIT 1", cat_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Category not found" } }
        end
        local old_cat = find_rows[1]

        local set_parts = {}
        local set_vals = {}
        local allowed = {"name", "slug", "description", "icon", "display_order", "parent_id", "is_active", "is_archived", "visibility_rule_json", "completion_rule_json"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)
        table.insert(set_parts, "updated_by = ?")
        table.insert(set_vals, admin_int_id)
        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, cat_uuid)

        local sql = "UPDATE profile_categories SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update category failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update category" } }
        end

        local updated = upd_result and upd_result[1] or nil
        if updated then
            auditLog({
                namespace_id = old_cat.namespace_id,
                user_id = admin_uuid,
                action = "update",
                entity_type = "category",
                entity_uuid = cat_uuid,
                old_data_json = cjson.encode(old_cat),
                new_data_json = cjson.encode(updated),
                ip_address = getClientIp()
            })
        end

        return { status = 200, json = { category = updated } }
    end)

    -- DELETE /categories/:uuid — archive (admin)
    app:delete(PREFIX .. "/categories/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local cat_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_categories WHERE uuid = ? LIMIT 1", cat_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Category not found" } }
        end

        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)
        local ok_upd, upd_err = pcall(db.query, [[
            UPDATE profile_categories SET is_archived = true, updated_by = ?, updated_at = NOW()
            WHERE uuid = ?
        ]], admin_int_id, cat_uuid)
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] archive category failed: ", tostring(upd_err))
            return { status = 500, json = { error = "Failed to archive category" } }
        end

        auditLog({
            namespace_id = find_rows[1].namespace_id,
            user_id = admin_uuid,
            action = "archive",
            entity_type = "category",
            entity_uuid = cat_uuid,
            old_data_json = cjson.encode(find_rows[1]),
            new_data_json = nil,
            ip_address = getClientIp()
        })

        return { status = 200, json = { message = "Category archived", uuid = cat_uuid } }
    end)

    -- PUT /categories/reorder — bulk update display_order (admin)
    app:put(PREFIX .. "/categories/reorder", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local items = params.items
        if not items or type(items) ~= "table" or #items == 0 then
            return { status = 400, json = { error = "items array is required with uuid and display_order" } }
        end

        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)
        for _, item in ipairs(items) do
            if item.uuid and item.display_order ~= nil then
                local ok, err = pcall(db.query, [[
                    UPDATE profile_categories SET display_order = ?, updated_by = ?, updated_at = NOW()
                    WHERE uuid = ?
                ]], item.display_order, admin_int_id, item.uuid)
                if not ok then
                    ngx.log(ngx.ERR, "[ProfileBuilder] reorder category failed: ", tostring(err))
                end
            end
        end

        return { status = 200, json = { message = "Categories reordered", count = #items } }
    end)

    -- =====================================================================
    -- 4. QUESTIONS CRUD
    -- =====================================================================

    -- GET /questions — list
    app:get(PREFIX .. "/questions", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local where_parts = {"1=1"}
        local where_vals = {}
        local include_archived = self.params.include_archived == "true"
        local include_options = self.params.include_options == "true"
        local include_rules = self.params.include_rules == "true"

        if not include_archived then
            table.insert(where_parts, "pq.is_archived = false")
        end

        if self.params.category_id and self.params.category_id ~= "" then
            -- category_id param is a uuid, look up the actual id
            local ok_cat, cat_rows = pcall(db.query, "SELECT id FROM profile_categories WHERE uuid = ? LIMIT 1", self.params.category_id)
            if ok_cat and cat_rows and #cat_rows > 0 then
                table.insert(where_parts, "pq.category_id = ?")
                table.insert(where_vals, cat_rows[1].id)
            else
                return { status = 200, json = { questions = {}, total = 0 } }
            end
        end

        if self.params.question_type and self.params.question_type ~= "" then
            table.insert(where_parts, "pq.question_type = ?")
            table.insert(where_vals, self.params.question_type)
        end

        if self.params.is_active ~= nil and self.params.is_active ~= "" then
            table.insert(where_parts, "pq.is_active = ?")
            table.insert(where_vals, self.params.is_active == "true")
        end

        if self.params.touchpoint and self.params.touchpoint ~= "" then
            table.insert(where_parts, [[
                pq.id IN (
                    SELECT pqt.question_id FROM profile_question_touchpoints pqt
                    JOIN profile_touchpoints pt ON pt.id = pqt.touchpoint_id
                    WHERE pt.uuid = ?
                )
            ]])
            table.insert(where_vals, self.params.touchpoint)
        end

        -- Business-profile filter. Semantics:
        --   "applies to this profile" === question has no link rows at all
        --   (= applies to all), OR has a link row whose profile_key matches.
        -- That keeps the default-all behaviour intact while letting an admin
        -- ask "show me the questions that target landlord".
        if self.params.business_profile and self.params.business_profile ~= "" then
            table.insert(where_parts, [[
                (NOT EXISTS (
                    SELECT 1 FROM profile_question_business_profiles
                    WHERE question_id = pq.id
                ) OR EXISTS (
                    SELECT 1 FROM profile_question_business_profiles
                    WHERE question_id = pq.id AND profile_key = ?
                ))
            ]])
            table.insert(where_vals, self.params.business_profile)
        end

        -- Server-side typeahead. `search` matches case-insensitive substring
        -- against question label, key, description, AND the joined category
        -- name — so the admin can type either the question wording or the
        -- group it lives in to narrow it down. Used by the SearchableSelect
        -- on /admin/profile-builder/rules so we don't ship the whole table
        -- to the browser on every page open.
        local search = self.params.search
        if search and search ~= "" then
            local like = "%" .. search .. "%"
            table.insert(where_parts, [[
                (pq.label ILIKE ?
                 OR pq.question_key ILIKE ?
                 OR pq.description ILIKE ?
                 OR pc.name ILIKE ?)
            ]])
            table.insert(where_vals, like)
            table.insert(where_vals, like)
            table.insert(where_vals, like)
            table.insert(where_vals, like)
        end

        -- Paging. Default to a reasonable upper bound so a caller that
        -- forgets to set limit can't accidentally pull the whole table; the
        -- typeahead UI never needs more than a few dozen rows per request.
        local limit = tonumber(self.params.limit) or 100
        if limit < 1 then limit = 1 end
        if limit > 500 then limit = 500 end
        local offset = tonumber(self.params.offset) or 0
        if offset < 0 then offset = 0 end

        local sql = "SELECT pq.*, pc.uuid as category_uuid, pc.name as category_name FROM profile_questions pq LEFT JOIN profile_categories pc ON pc.id = pq.category_id WHERE "
            .. table.concat(where_parts, " AND ")
            .. " ORDER BY pq.display_order ASC, pq.label ASC LIMIT " .. limit .. " OFFSET " .. offset
        local ok, rows = pcall(db.query, sql, unpack(where_vals))
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] questions list failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load questions" } }
        end

        if include_options or include_rules then
            for _, q in ipairs(rows or {}) do
                if include_options then
                    local ok_opts, opts = pcall(db.query, [[
                        SELECT * FROM profile_question_options WHERE question_id = ? AND is_active = true ORDER BY display_order ASC
                    ]], q.id)
                    q.options = (ok_opts and opts) or {}
                end
                if include_rules then
                    local ok_rules, rules = pcall(db.query, [[
                        SELECT * FROM profile_question_rules WHERE question_id = ? AND is_active = true ORDER BY priority ASC
                    ]], q.id)
                    q.rules = (ok_rules and rules) or {}
                end
            end
        end

        -- Attach business_profiles (string[]) to each row. Bulk-loaded so
        -- the list endpoint never goes N+1, regardless of page size.
        local q_ids = {}
        for _, q in ipairs(rows or {}) do q_ids[#q_ids + 1] = q.id end
        local bp_by_q = bulkLoadQuestionBusinessProfiles(q_ids)
        for _, q in ipairs(rows or {}) do
            q.business_profiles = bp_by_q[q.id] or {}
        end

        return { status = 200, json = { questions = rows or {}, total = #(rows or {}) } }
    end)

    -- GET /questions/:uuid — get one with options + rules
    app:get(PREFIX .. "/questions/:uuid", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local ok, rows = pcall(db.query, "SELECT * FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok or not rows or #rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end

        local question = rows[1]

        local ok_opts, opts = pcall(db.query, [[
            SELECT * FROM profile_question_options WHERE question_id = ? AND is_active = true ORDER BY display_order ASC
        ]], question.id)
        question.options = (ok_opts and opts) or {}

        local ok_rules, rules = pcall(db.query, [[
            SELECT * FROM profile_question_rules WHERE question_id = ? AND is_active = true ORDER BY priority ASC
        ]], question.id)
        question.rules = (ok_rules and rules) or {}

        question.business_profiles = loadQuestionBusinessProfiles(question.id)

        return { status = 200, json = { question = question } }
    end)

    -- POST /questions — create (admin)
    app:post(PREFIX .. "/questions", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)

        if not params.category_uuid or params.category_uuid == "" then
            return { status = 400, json = { error = "category_uuid is required" } }
        end
        if not params.question_key or params.question_key == "" then
            return { status = 400, json = { error = "question_key is required" } }
        end
        if not params.label or params.label == "" then
            return { status = 400, json = { error = "label is required" } }
        end
        if not params.question_type or params.question_type == "" then
            return { status = 400, json = { error = "question_type is required" } }
        end

        local ok_cat, cat_rows = pcall(db.query, "SELECT id, namespace_id FROM profile_categories WHERE uuid = ? LIMIT 1", params.category_uuid)
        if not ok_cat or not cat_rows or #cat_rows == 0 then
            return { status = 404, json = { error = "Category not found" } }
        end
        local category = cat_rows[1]

        local namespace_id = category.namespace_id or getNamespaceId(self)
        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)

        local lookup_table_id = db.NULL
        if params.lookup_table_uuid and params.lookup_table_uuid ~= "" then
            local ok_lt, lt_rows = pcall(db.query, "SELECT id FROM profile_lookup_tables WHERE uuid = ? LIMIT 1", params.lookup_table_uuid)
            if ok_lt and lt_rows and #lt_rows > 0 then
                lookup_table_id = lt_rows[1].id
            end
        end

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_questions (uuid, namespace_id, category_id, question_key, label, description, help_text, placeholder, question_type, is_required, is_multi_value, is_editable_by_user, display_order, validation_json, default_value, config_json, lookup_table_id, version, is_active, is_archived, created_by, updated_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, false, ?, ?, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id or 0,
            category.id,
            params.question_key,
            params.label,
            params.description or db.NULL,
            params.help_text or db.NULL,
            params.placeholder or db.NULL,
            params.question_type,
            params.is_required or false,
            params.is_multi_value or false,
            params.is_editable_by_user ~= false,
            params.display_order or 0,
            params.validation_json or db.NULL,
            params.default_value or db.NULL,
            params.config_json or db.NULL,
            lookup_table_id,
            params.version or 1,
            admin_int_id,
            admin_int_id
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create question failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create question" } }
        end

        local question = ins_result and ins_result[1] or nil
        if question then
            -- Persist business-profile links from the request body. Empty /
            -- missing array clears any existing links (which would only
            -- happen on a re-POST to an existing uuid — defensive).
            replaceQuestionBusinessProfiles(question.id, params.business_profiles)
            question.business_profiles = loadQuestionBusinessProfiles(question.id)

            auditLog({
                namespace_id = namespace_id,
                user_id = admin_uuid,
                action = "create",
                entity_type = "question",
                entity_uuid = question.uuid,
                old_data_json = nil,
                new_data_json = cjson.encode(question),
                ip_address = getClientIp()
            })
        end

        return { status = 201, json = { question = question } }
    end)

    -- PUT /questions/:uuid — update (admin)
    app:put(PREFIX .. "/questions/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end
        local old_q = find_rows[1]
        -- Snapshot the OLD business-profile link set BEFORE any mutation so
        -- the audit log's old_data_json gives a real diff (the LHS would
        -- otherwise lose that field after the replace).
        old_q.business_profiles = loadQuestionBusinessProfiles(old_q.id)

        local set_parts = {}
        local set_vals = {}
        local allowed = {"question_key", "label", "description", "help_text", "placeholder", "question_type", "is_required", "is_multi_value", "is_editable_by_user", "display_order", "validation_json", "default_value", "config_json", "version", "is_active", "is_archived"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.category_uuid and params.category_uuid ~= "" then
            local ok_cat, cat_rows = pcall(db.query, "SELECT id FROM profile_categories WHERE uuid = ? LIMIT 1", params.category_uuid)
            if ok_cat and cat_rows and #cat_rows > 0 then
                table.insert(set_parts, "category_id = ?")
                table.insert(set_vals, cat_rows[1].id)
            end
        end

        if params.lookup_table_uuid ~= nil then
            if params.lookup_table_uuid == "" or params.lookup_table_uuid == cjson.null then
                table.insert(set_parts, "lookup_table_id = NULL")
            else
                local ok_lt, lt_rows = pcall(db.query, "SELECT id FROM profile_lookup_tables WHERE uuid = ? LIMIT 1", params.lookup_table_uuid)
                if ok_lt and lt_rows and #lt_rows > 0 then
                    table.insert(set_parts, "lookup_table_id = ?")
                    table.insert(set_vals, lt_rows[1].id)
                end
            end
        end

        -- A `business_profiles` array in the body counts as an update too —
        -- the admin may want to re-tag a question without changing any other
        -- field. We treat `nil` as "leave existing links alone" and an array
        -- (even an empty one) as "replace the link set with this".
        local bp_provided = params.business_profiles ~= nil
            and type(params.business_profiles) == "table"

        if #set_parts == 0 and not bp_provided then
            return { status = 400, json = { error = "No fields to update" } }
        end

        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)

        local updated = old_q
        if #set_parts > 0 then
            table.insert(set_parts, "updated_by = ?")
            table.insert(set_vals, admin_int_id)
            table.insert(set_parts, "updated_at = NOW()")
            table.insert(set_vals, q_uuid)

            local sql = "UPDATE profile_questions SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
            local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
            if not ok_upd then
                ngx.log(ngx.ERR, "[ProfileBuilder] update question failed: ", tostring(upd_result))
                return { status = 500, json = { error = "Failed to update question" } }
            end
            updated = upd_result and upd_result[1] or old_q
        end

        if bp_provided then
            replaceQuestionBusinessProfiles(updated.id, params.business_profiles)
        end
        updated.business_profiles = loadQuestionBusinessProfiles(updated.id)

        -- Audit fires for ANY successful change — column updates OR
        -- business-profile re-tagging. Skipping the latter would hide
        -- ops-relevant scope changes from the trail. old_q + updated both
        -- carry business_profiles so the diff is meaningful either way.
        if updated and (#set_parts > 0 or bp_provided) then
            auditLog({
                namespace_id = old_q.namespace_id,
                user_id = admin_uuid,
                action = "update",
                entity_type = "question",
                entity_uuid = q_uuid,
                old_data_json = cjson.encode(old_q),
                new_data_json = cjson.encode(updated),
                ip_address = getClientIp()
            })
        end

        return { status = 200, json = { question = updated } }
    end)

    -- DELETE /questions/:uuid — archive (admin)
    app:delete(PREFIX .. "/questions/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end

        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)
        local ok_upd, upd_err = pcall(db.query, [[
            UPDATE profile_questions SET is_archived = true, updated_by = ?, updated_at = NOW()
            WHERE uuid = ?
        ]], admin_int_id, q_uuid)
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] archive question failed: ", tostring(upd_err))
            return { status = 500, json = { error = "Failed to archive question" } }
        end

        auditLog({
            namespace_id = find_rows[1].namespace_id,
            user_id = admin_uuid,
            action = "archive",
            entity_type = "question",
            entity_uuid = q_uuid,
            old_data_json = cjson.encode(find_rows[1]),
            new_data_json = nil,
            ip_address = getClientIp()
        })

        return { status = 200, json = { message = "Question archived", uuid = q_uuid } }
    end)

    -- PUT /questions/reorder — bulk reorder (admin)
    app:put(PREFIX .. "/questions/reorder", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local items = params.items
        if not items or type(items) ~= "table" or #items == 0 then
            return { status = 400, json = { error = "items array is required with uuid and display_order" } }
        end

        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)
        for _, item in ipairs(items) do
            if item.uuid and item.display_order ~= nil then
                local ok, err = pcall(db.query, [[
                    UPDATE profile_questions SET display_order = ?, updated_by = ?, updated_at = NOW()
                    WHERE uuid = ?
                ]], item.display_order, admin_int_id, item.uuid)
                if not ok then
                    ngx.log(ngx.ERR, "[ProfileBuilder] reorder question failed: ", tostring(err))
                end
            end
        end

        return { status = 200, json = { message = "Questions reordered", count = #items } }
    end)

    -- =====================================================================
    -- 5. QUESTION OPTIONS
    -- =====================================================================

    -- GET /questions/:uuid/options
    app:get(PREFIX .. "/questions/:uuid/options", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok_q or not q_rows or #q_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT * FROM profile_question_options WHERE question_id = ? ORDER BY display_order ASC, label ASC
        ]], q_rows[1].id)
        if not ok then
            return { status = 500, json = { error = "Failed to load options" } }
        end

        return { status = 200, json = { options = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /questions/:uuid/options (admin)
    app:post(PREFIX .. "/questions/:uuid/options", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local q_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", q_uuid)
        if not ok_q or not q_rows or #q_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end
        local question_id = q_rows[1].id

        if not params.label or params.label == "" then
            return { status = 400, json = { error = "label is required" } }
        end
        if not params.value or params.value == "" then
            return { status = 400, json = { error = "value is required" } }
        end

        local parent_option_id = nil
        if params.parent_option_uuid and params.parent_option_uuid ~= "" then
            local ok_po, po_rows = pcall(db.query, "SELECT id FROM profile_question_options WHERE uuid = ? LIMIT 1", params.parent_option_uuid)
            if ok_po and po_rows and #po_rows > 0 then
                parent_option_id = po_rows[1].id
            end
        end

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_question_options (uuid, question_id, label, value, description, display_order, is_default, is_active, parent_option_id, metadata_json, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, true, ?, ?, NOW(), NOW())
            RETURNING *
        ]],
            question_id,
            params.label,
            params.value,
            params.description or db.NULL,
            params.display_order or 0,
            params.is_default or false,
            parent_option_id or db.NULL,
            params.metadata_json or db.NULL
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create option failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create option" } }
        end

        return { status = 201, json = { option = ins_result and ins_result[1] or nil } }
    end)

    -- PUT /questions/:questionUuid/options/:optionUuid (admin)
    app:put(PREFIX .. "/questions/:questionUuid/options/:optionUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local option_uuid = self.params.optionUuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_question_options WHERE uuid = ? LIMIT 1", option_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Option not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"label", "value", "description", "display_order", "is_default", "is_active", "metadata_json"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.parent_option_uuid ~= nil then
            if params.parent_option_uuid == "" or params.parent_option_uuid == cjson.null then
                table.insert(set_parts, "parent_option_id = NULL")
            else
                local ok_po, po_rows = pcall(db.query, "SELECT id FROM profile_question_options WHERE uuid = ? LIMIT 1", params.parent_option_uuid)
                if ok_po and po_rows and #po_rows > 0 then
                    table.insert(set_parts, "parent_option_id = ?")
                    table.insert(set_vals, po_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, option_uuid)

        local sql = "UPDATE profile_question_options SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update option failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update option" } }
        end

        return { status = 200, json = { option = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /questions/:questionUuid/options/:optionUuid (admin)
    app:delete(PREFIX .. "/questions/:questionUuid/options/:optionUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local option_uuid = self.params.optionUuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_question_options WHERE uuid = ? LIMIT 1", option_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Option not found" } }
        end

        local ok_del, del_err = pcall(db.query, [[
            UPDATE profile_question_options SET is_active = false, updated_at = NOW() WHERE uuid = ?
        ]], option_uuid)
        if not ok_del then
            ngx.log(ngx.ERR, "[ProfileBuilder] delete option failed: ", tostring(del_err))
            return { status = 500, json = { error = "Failed to delete option" } }
        end

        return { status = 200, json = { message = "Option deactivated", uuid = option_uuid } }
    end)

    -- PUT /questions/:uuid/options/reorder (admin)
    app:put(PREFIX .. "/questions/:uuid/options/reorder", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local items = params.items
        if not items or type(items) ~= "table" or #items == 0 then
            return { status = 400, json = { error = "items array is required with uuid and display_order" } }
        end

        for _, item in ipairs(items) do
            if item.uuid and item.display_order ~= nil then
                local ok, err = pcall(db.query, [[
                    UPDATE profile_question_options SET display_order = ?, updated_at = NOW() WHERE uuid = ?
                ]], item.display_order, item.uuid)
                if not ok then
                    ngx.log(ngx.ERR, "[ProfileBuilder] reorder option failed: ", tostring(err))
                end
            end
        end

        return { status = 200, json = { message = "Options reordered", count = #items } }
    end)

    -- =====================================================================
    -- 6. RULES
    -- =====================================================================

    -- GET /rules
    app:get(PREFIX .. "/rules", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local where_parts = {"1=1"}
        local where_vals = {}

        if self.params.question_uuid and self.params.question_uuid ~= "" then
            local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", self.params.question_uuid)
            if ok_q and q_rows and #q_rows > 0 then
                table.insert(where_parts, "pqr.question_id = ?")
                table.insert(where_vals, q_rows[1].id)
            else
                return { status = 200, json = { rules = {}, total = 0 } }
            end
        end

        if self.params.rule_type and self.params.rule_type ~= "" then
            table.insert(where_parts, "pqr.rule_type = ?")
            table.insert(where_vals, self.params.rule_type)
        end

        if self.params.is_active ~= nil and self.params.is_active ~= "" then
            table.insert(where_parts, "pqr.is_active = ?")
            table.insert(where_vals, self.params.is_active == "true")
        end

        local sql = "SELECT pqr.*, pq_target.uuid as question_uuid, pq_target.question_key as question_key, pq_target.label as question_label, pq_source.uuid as source_question_uuid, pq_source.question_key as source_question_key, pq_source.label as source_question_label FROM profile_question_rules pqr LEFT JOIN profile_questions pq_target ON pq_target.id = pqr.question_id LEFT JOIN profile_questions pq_source ON pq_source.id = pqr.source_question_id WHERE " .. table.concat(where_parts, " AND ") .. " ORDER BY pqr.priority ASC"
        local ok, rows = pcall(db.query, sql, unpack(where_vals))
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] rules list failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load rules" } }
        end

        return { status = 200, json = { rules = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /rules (admin)
    app:post(PREFIX .. "/rules", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)

        if not params.question_uuid or params.question_uuid == "" then
            return { status = 400, json = { error = "question_uuid is required" } }
        end
        if not params.rule_name or params.rule_name == "" then
            return { status = 400, json = { error = "rule_name is required" } }
        end
        if not params.rule_type or params.rule_type == "" then
            return { status = 400, json = { error = "rule_type is required" } }
        end

        local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.question_uuid)
        if not ok_q or not q_rows or #q_rows == 0 then
            return { status = 404, json = { error = "Question not found" } }
        end
        local question_id = q_rows[1].id

        local source_question_id = nil
        if params.source_question_uuid and params.source_question_uuid ~= "" then
            local ok_sq, sq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.source_question_uuid)
            if ok_sq and sq_rows and #sq_rows > 0 then
                source_question_id = sq_rows[1].id
            end
        end

        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_question_rules (uuid, question_id, rule_name, rule_type, operator, logic_group, source_question_id, source_field, expected_value, expected_values_json, priority, is_active, created_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, ?, NOW(), NOW())
            RETURNING *
        ]],
            question_id,
            params.rule_name or db.NULL,
            params.rule_type,
            params.operator or db.NULL,
            params.logic_group or db.NULL,
            source_question_id or db.NULL,
            params.source_field or db.NULL,
            params.expected_value or db.NULL,
            params.expected_values_json or db.NULL,
            params.priority or 0,
            admin_int_id
        )
        if not ok_ins then
            local err_msg = tostring(ins_result)
            ngx.log(ngx.ERR, "[ProfileBuilder] create rule failed: ", err_msg)
            if err_msg:find("duplicate key") or err_msg:find("unique constraint") then
                return { status = 409, json = { error = "A rule with this configuration already exists" } }
            end
            return { status = 500, json = { error = "Failed to create rule" } }
        end

        return { status = 201, json = { rule = ins_result and ins_result[1] or nil } }
    end)

    -- PUT /rules/:uuid (admin)
    app:put(PREFIX .. "/rules/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local rule_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_question_rules WHERE uuid = ? LIMIT 1", rule_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Rule not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"rule_name", "rule_type", "operator", "logic_group", "source_field", "expected_value", "expected_values_json", "priority", "is_active"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        -- Resolve question_uuid → question_id (target question this rule applies to)
        if params.question_uuid and params.question_uuid ~= "" then
            local ok_tq, tq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.question_uuid)
            if ok_tq and tq_rows and #tq_rows > 0 then
                table.insert(set_parts, "question_id = ?")
                table.insert(set_vals, tq_rows[1].id)
            end
        end

        -- Resolve source_question_uuid → source_question_id (trigger question)
        if params.source_question_uuid ~= nil then
            if params.source_question_uuid == "" or params.source_question_uuid == cjson.null then
                table.insert(set_parts, "source_question_id = NULL")
            else
                local ok_sq, sq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.source_question_uuid)
                if ok_sq and sq_rows and #sq_rows > 0 then
                    table.insert(set_parts, "source_question_id = ?")
                    table.insert(set_vals, sq_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, rule_uuid)

        local sql = "UPDATE profile_question_rules SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update rule failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update rule" } }
        end

        return { status = 200, json = { rule = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /rules/:uuid (admin)
    app:delete(PREFIX .. "/rules/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local rule_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_question_rules WHERE uuid = ? LIMIT 1", rule_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Rule not found" } }
        end

        local ok_del, del_err = pcall(db.query, "UPDATE profile_question_rules SET is_active = false, updated_at = NOW() WHERE uuid = ?", rule_uuid)
        if not ok_del then
            ngx.log(ngx.ERR, "[ProfileBuilder] delete rule failed: ", tostring(del_err))
            return { status = 500, json = { error = "Failed to delete rule" } }
        end

        return { status = 200, json = { message = "Rule deactivated", uuid = rule_uuid } }
    end)

    -- =====================================================================
    -- 7. ANSWERS (end-user)
    -- =====================================================================

    -- GET /answers — user's current answers
    app:get(PREFIX .. "/answers", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 200, json = { answers = {}, total = 0 } }
        end

        local category_slug = self.params.category_slug

        local sql
        local vals = {user_id}
        if category_slug and category_slug ~= "" then
            sql = [[
                SELECT upa.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid,
                       pc.slug AS category_slug, pc.name AS category_name
                FROM user_profile_answers upa
                JOIN profile_questions pq ON pq.id = upa.question_id
                JOIN profile_categories pc ON pc.id = pq.category_id
                WHERE upa.user_id = ? AND pc.slug = ?
                ORDER BY pq.display_order ASC
            ]]
            table.insert(vals, category_slug)
        else
            sql = [[
                SELECT upa.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid
                FROM user_profile_answers upa
                JOIN profile_questions pq ON pq.id = upa.question_id
                WHERE upa.user_id = ?
                ORDER BY pq.display_order ASC
            ]]
        end

        local ok, rows = pcall(db.query, sql, unpack(vals))
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] answers list failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load answers" } }
        end

        return { status = 200, json = { answers = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /answers — save answers (upsert)
    app:post(PREFIX .. "/answers", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local params = parseJsonBody(self)
        local answers = params.answers
        if not answers or type(answers) ~= "table" or #answers == 0 then
            return { status = 400, json = { error = "answers array is required" } }
        end

        local namespace_id = getNamespaceId(self)
        local saved = 0
        local errors = {}
        local affected_category_ids = {}

        for i, ans in ipairs(answers) do
            if not ans.question_uuid or ans.question_uuid == "" then
                table.insert(errors, { index = i, error = "question_uuid is required" })
            else
                local ok_q, q_rows = pcall(db.query, "SELECT id, version, category_id, question_key FROM profile_questions WHERE uuid = ? AND is_active = true LIMIT 1", ans.question_uuid)
                if not ok_q or not q_rows or #q_rows == 0 then
                    table.insert(errors, { index = i, error = "Question not found: " .. ans.question_uuid })
                else
                    local question = q_rows[1]
                    affected_category_ids[question.category_id] = true

                    -- ─── Identity-lock guard for NINO / UTR back-door ─────────
                    -- If this question_key is one of the identity fields
                    -- (nino / ni_number / utr_number) AND the user's lock is
                    -- already stamped, the write must be rejected — same rule
                    -- the dedicated /nino endpoints enforce.
                    -- assertNotLocked raises a catalog 403 via Errors.raise,
                    -- which the app-level error middleware catches and turns
                    -- into the standard error envelope with support_url etc.
                    -- No need to trap here — letting it bubble is correct.
                    local lock_field = LOCK_FIELD_BY_QUESTION_KEY[question.question_key]
                    if lock_field then
                        IdentityLock.assertNotLocked(user_uuid, namespace_id or 0, lock_field)
                    end

                    -- Get existing answer for history
                    local old_answer = nil
                    local ok_old, old_rows = pcall(db.query, [[
                        SELECT * FROM user_profile_answers WHERE user_id = ? AND question_id = ? LIMIT 1
                    ]], user_id, question.id)
                    if ok_old and old_rows and #old_rows > 0 then
                        old_answer = old_rows[1]
                    end

                    local ok_upsert, upsert_err = pcall(db.query, [[
                        INSERT INTO user_profile_answers (uuid, user_id, user_uuid, namespace_id, question_id, question_version, answer_text, answer_number, answer_boolean, answer_date, answer_json, answer_file_url, is_draft, answered_at, updated_at)
                        VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                        ON CONFLICT (user_id, question_id) DO UPDATE SET
                            question_version = EXCLUDED.question_version,
                            answer_text = EXCLUDED.answer_text,
                            answer_number = EXCLUDED.answer_number,
                            answer_boolean = EXCLUDED.answer_boolean,
                            answer_date = EXCLUDED.answer_date,
                            answer_json = EXCLUDED.answer_json,
                            answer_file_url = EXCLUDED.answer_file_url,
                            is_draft = EXCLUDED.is_draft,
                            answered_at = NOW(),
                            updated_at = NOW()
                    ]],
                        user_id,
                        user_uuid,
                        namespace_id or 0,
                        question.id,
                        question.version or 1,
                        ans.answer_text or db.NULL,
                        ans.answer_number or db.NULL,
                        ans.answer_boolean == nil and db.NULL or ans.answer_boolean,
                        ans.answer_date or db.NULL,
                        ans.answer_json or db.NULL,
                        ans.answer_file_url or db.NULL,
                        ans.is_draft == nil and false or ans.is_draft
                    )

                    if not ok_upsert then
                        ngx.log(ngx.ERR, "[ProfileBuilder] upsert answer failed: ", tostring(upsert_err))
                        table.insert(errors, { index = i, error = "Failed to save answer for " .. ans.question_uuid })
                    else
                        saved = saved + 1

                        -- ─── First-write auto-lock for NINO / UTR answers ─────
                        -- Stamp the lock on this user's tax_user_profiles row
                        -- once the answer is committed. Idempotent — repeat
                        -- upserts of the same question_key just no-op the
                        -- COALESCE(...) that preserves the original stamp.
                        -- Also emits an audit row for the "first time this
                        -- user wrote a locking answer" event.
                        if lock_field then
                            IdentityLock.stampLock(user_uuid, namespace_id or 0, lock_field)
                            IdentityLock.emitAuditRow({
                                user_id      = user_id,
                                namespace_id = namespace_id or 0,
                                action       = (lock_field == "nino")
                                    and "NINO_SAVED_AND_LOCKED"
                                    or  "UTR_SAVED_AND_LOCKED",
                                new_values   = {
                                    question_key = question.question_key,
                                    path         = "/api/v2/profile-builder/answers",
                                },
                            })
                        end

                        -- Insert history record
                        if old_answer then
                            pcall(db.query, [[
                                INSERT INTO user_profile_answer_history (uuid, answer_id, user_id, question_id, question_version, old_answer_text, old_answer_number, old_answer_boolean, old_answer_date, old_answer_json, new_answer_text, new_answer_number, new_answer_boolean, new_answer_date, new_answer_json, changed_by, change_source, change_reason, created_at)
                                VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
                            ]],
                                old_answer.id,
                                user_id,
                                question.id,
                                question.version or 1,
                                old_answer.answer_text or db.NULL,
                                old_answer.answer_number or db.NULL,
                                old_answer.answer_boolean == nil and db.NULL or old_answer.answer_boolean,
                                old_answer.answer_date or db.NULL,
                                old_answer.answer_json or db.NULL,
                                ans.answer_text or db.NULL,
                                ans.answer_number or db.NULL,
                                ans.answer_boolean == nil and db.NULL or ans.answer_boolean,
                                ans.answer_date or db.NULL,
                                ans.answer_json or db.NULL,
                                user_id,
                                "user",
                                ans.change_reason or db.NULL
                            )
                        end
                    end
                end
            end
        end

        -- Recalculate completion for affected categories
        for category_id, _ in pairs(affected_category_ids) do
            recalculateCompletion(user_id, user_uuid, category_id)
        end

        -- Evaluate auto-tag rules based on updated answers
        evaluateTagRules(user_id, user_uuid)

        -- Get updated tags to return to frontend
        local updated_tags = getUserTags(user_id)

        local response = {
            message = "Answers saved",
            saved = saved,
            total = #answers,
            user_tags = updated_tags,
        }
        if #errors > 0 then
            response.errors = errors
        end

        return { status = 200, json = response }
    end)

    -- POST /answers/validate — validate without saving
    app:post(PREFIX .. "/answers/validate", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        local answers = params.answers
        if not answers or type(answers) ~= "table" or #answers == 0 then
            return { status = 400, json = { error = "answers array is required" } }
        end

        local results = {}
        for i, ans in ipairs(answers) do
            local result = { index = i, question_uuid = ans.question_uuid, valid = true, errors = {} }

            if not ans.question_uuid or ans.question_uuid == "" then
                result.valid = false
                table.insert(result.errors, "question_uuid is required")
            else
                local ok_q, q_rows = pcall(db.query, [[
                    SELECT * FROM profile_questions WHERE uuid = ? AND is_active = true LIMIT 1
                ]], ans.question_uuid)
                if not ok_q or not q_rows or #q_rows == 0 then
                    result.valid = false
                    table.insert(result.errors, "Question not found")
                else
                    local q = q_rows[1]

                    -- Check required
                    if q.is_required then
                        local has_value = (ans.answer_text and ans.answer_text ~= "") or
                            ans.answer_number ~= nil or
                            ans.answer_boolean ~= nil or
                            (ans.answer_date and ans.answer_date ~= "") or
                            (ans.answer_json and ans.answer_json ~= "")
                        if not has_value then
                            result.valid = false
                            table.insert(result.errors, "This field is required")
                        end
                    end

                    -- Check validation_json rules if present
                    if q.validation_json and q.validation_json ~= "" then
                        local ok_parse, validation = pcall(cjson.decode, q.validation_json)
                        if ok_parse and validation then
                            if validation.min_length and ans.answer_text then
                                if #ans.answer_text < validation.min_length then
                                    result.valid = false
                                    table.insert(result.errors, "Minimum length is " .. validation.min_length)
                                end
                            end
                            if validation.max_length and ans.answer_text then
                                if #ans.answer_text > validation.max_length then
                                    result.valid = false
                                    table.insert(result.errors, "Maximum length is " .. validation.max_length)
                                end
                            end
                            if validation.min and ans.answer_number then
                                if tonumber(ans.answer_number) < validation.min then
                                    result.valid = false
                                    table.insert(result.errors, "Minimum value is " .. validation.min)
                                end
                            end
                            if validation.max and ans.answer_number then
                                if tonumber(ans.answer_number) > validation.max then
                                    result.valid = false
                                    table.insert(result.errors, "Maximum value is " .. validation.max)
                                end
                            end
                            if validation.pattern and ans.answer_text then
                                if not ans.answer_text:match(validation.pattern) then
                                    result.valid = false
                                    table.insert(result.errors, validation.pattern_message or "Invalid format")
                                end
                            end
                        end
                    end
                end
            end

            table.insert(results, result)
        end

        local all_valid = true
        for _, r in ipairs(results) do
            if not r.valid then
                all_valid = false
                break
            end
        end

        return { status = 200, json = { valid = all_valid, results = results } }
    end)

    -- GET /answers/history — user's answer change history
    app:get(PREFIX .. "/answers/history", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 200, json = { history = {}, total = 0 } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 50
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local ok_cnt, cnt_rows = pcall(db.query, [[
            SELECT COUNT(*) AS cnt FROM user_profile_answer_history WHERE user_id = ?
        ]], user_id)
        local total = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        local ok, rows = pcall(db.query, [[
            SELECT upah.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid
            FROM user_profile_answer_history upah
            JOIN profile_questions pq ON pq.id = upah.question_id
            WHERE upah.user_id = ?
            ORDER BY upah.created_at DESC
            LIMIT ? OFFSET ?
        ]], user_id, per_page, offset)
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] answer history failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load answer history" } }
        end

        return { status = 200, json = { history = rows or {}, total = total, page = page, per_page = per_page } }
    end)

    -- =====================================================================
    -- 8. TAGS
    -- =====================================================================

    -- GET /tags
    app:get(PREFIX .. "/tags", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local namespace_id = getNamespaceId(self)
        local where_clause = "is_active = true"
        local vals = {}
        if namespace_id and namespace_id > 0 then
            where_clause = where_clause .. " AND (namespace_id = ? OR namespace_id = 0)"
            table.insert(vals, namespace_id)
        end

        local ok, rows = pcall(db.query, "SELECT * FROM profile_tags WHERE " .. where_clause .. " ORDER BY name ASC", unpack(vals))
        if not ok then
            return { status = 500, json = { error = "Failed to load tags" } }
        end

        return { status = 200, json = { tags = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /tags (admin)
    app:post(PREFIX .. "/tags", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        if not params.name or params.name == "" then
            return { status = 400, json = { error = "name is required" } }
        end
        if not params.slug or params.slug == "" then
            return { status = 400, json = { error = "slug is required" } }
        end

        local namespace_id = getNamespaceId(self)
        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)

        local ok, result = pcall(db.query, [[
            INSERT INTO profile_tags (uuid, namespace_id, name, slug, description, color, tag_type, is_active, created_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, true, ?, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id or 0,
            params.name,
            params.slug,
            params.description or db.NULL,
            params.color or db.NULL,
            params.tag_type or "manual",
            admin_int_id
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] create tag failed: ", tostring(result))
            return { status = 500, json = { error = "Failed to create tag" } }
        end

        return { status = 201, json = { tag = result and result[1] or nil } }
    end)

    -- PUT /tags/:uuid (admin)
    app:put(PREFIX .. "/tags/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tag_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_tags WHERE uuid = ? LIMIT 1", tag_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"name", "slug", "description", "color", "tag_type", "is_active"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, tag_uuid)

        local sql = "UPDATE profile_tags SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update tag failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update tag" } }
        end

        return { status = 200, json = { tag = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /tags/:uuid (admin)
    app:delete(PREFIX .. "/tags/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tag_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_tags WHERE uuid = ? LIMIT 1", tag_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end

        local ok_del, del_err = pcall(db.query, "UPDATE profile_tags SET is_active = false, updated_at = NOW() WHERE uuid = ?", tag_uuid)
        if not ok_del then
            return { status = 500, json = { error = "Failed to delete tag" } }
        end

        return { status = 200, json = { message = "Tag deactivated", uuid = tag_uuid } }
    end)

    -- POST /tags/:uuid/assign — assign tag to user (admin)
    app:post(PREFIX .. "/tags/:uuid/assign", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tag_uuid = self.params.uuid
        local params = parseJsonBody(self)

        if not params.user_uuid or params.user_uuid == "" then
            return { status = 400, json = { error = "user_uuid is required" } }
        end

        local ok_tag, tag_rows = pcall(db.query, "SELECT id FROM profile_tags WHERE uuid = ? AND is_active = true LIMIT 1", tag_uuid)
        if not ok_tag or not tag_rows or #tag_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end
        local tag_id = tag_rows[1].id

        local target_user_id = getUserIdByUuid(params.user_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local admin_uuid = admin.uuid or admin.id

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO user_profile_tags (uuid, user_id, user_uuid, tag_id, assigned_by, assignment_source, assignment_reason, is_active, created_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, true, NOW())
            ON CONFLICT (user_id, tag_id) DO UPDATE SET
                is_active = true,
                assigned_by = EXCLUDED.assigned_by,
                assignment_source = EXCLUDED.assignment_source,
                assignment_reason = EXCLUDED.assignment_reason,
                created_at = NOW()
            RETURNING *
        ]],
            target_user_id,
            params.user_uuid,
            tag_id,
            admin_uuid,
            params.assignment_source or "admin",
            params.assignment_reason or db.NULL
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] assign tag failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to assign tag" } }
        end

        return { status = 201, json = { assignment = ins_result and ins_result[1] or nil } }
    end)

    -- DELETE /tags/:uuid/users/:userUuid — remove tag from user (admin)
    app:delete(PREFIX .. "/tags/:uuid/users/:userUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tag_uuid = self.params.uuid
        local target_user_uuid = self.params.userUuid

        local ok_tag, tag_rows = pcall(db.query, "SELECT id FROM profile_tags WHERE uuid = ? LIMIT 1", tag_uuid)
        if not ok_tag or not tag_rows or #tag_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end

        local target_user_id = getUserIdByUuid(target_user_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local ok_del, del_err = pcall(db.query, [[
            UPDATE user_profile_tags SET is_active = false
            WHERE user_id = ? AND tag_id = ?
        ]], target_user_id, tag_rows[1].id)
        if not ok_del then
            return { status = 500, json = { error = "Failed to remove tag" } }
        end

        return { status = 200, json = { message = "Tag removed from user" } }
    end)

    -- =====================================================================
    -- 9. TAG RULES
    -- =====================================================================

    -- GET /tag-rules
    app:get(PREFIX .. "/tag-rules", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT ptr.*, pt.name AS tag_name, pt.slug AS tag_slug
            FROM profile_tag_rules ptr
            JOIN profile_tags pt ON pt.id = ptr.tag_id
            WHERE ptr.is_active = true
            ORDER BY ptr.priority ASC
        ]])
        if not ok then
            return { status = 500, json = { error = "Failed to load tag rules" } }
        end

        return { status = 200, json = { tag_rules = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /tag-rules (admin)
    app:post(PREFIX .. "/tag-rules", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)

        if not params.tag_uuid or params.tag_uuid == "" then
            return { status = 400, json = { error = "tag_uuid is required" } }
        end
        if not params.rule_name or params.rule_name == "" then
            return { status = 400, json = { error = "rule_name is required" } }
        end

        local ok_tag, tag_rows = pcall(db.query, "SELECT id FROM profile_tags WHERE uuid = ? LIMIT 1", params.tag_uuid)
        if not ok_tag or not tag_rows or #tag_rows == 0 then
            return { status = 404, json = { error = "Tag not found" } }
        end

        local source_question_id = nil
        if params.source_question_uuid and params.source_question_uuid ~= "" then
            local ok_sq, sq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.source_question_uuid)
            if ok_sq and sq_rows and #sq_rows > 0 then
                source_question_id = sq_rows[1].id
            end
        end

        local admin_uuid = admin.uuid or admin.id
        local admin_int_id = resolveUserId(admin_uuid)

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_tag_rules (uuid, tag_id, rule_name, description, source_question_id, source_field, operator, expected_value, expected_values_json, logic_group, priority, is_active, created_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, ?, NOW(), NOW())
            RETURNING *
        ]],
            tag_rows[1].id,
            params.rule_name or db.NULL,
            params.description or db.NULL,
            source_question_id or db.NULL,
            params.source_field or db.NULL,
            params.operator or db.NULL,
            params.expected_value or db.NULL,
            params.expected_values_json or db.NULL,
            params.logic_group or db.NULL,
            params.priority or 0,
            admin_int_id
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create tag rule failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create tag rule" } }
        end

        return { status = 201, json = { tag_rule = ins_result and ins_result[1] or nil } }
    end)

    -- PUT /tag-rules/:uuid (admin)
    app:put(PREFIX .. "/tag-rules/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local rule_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_tag_rules WHERE uuid = ? LIMIT 1", rule_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Tag rule not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"rule_name", "description", "source_field", "operator", "expected_value", "expected_values_json", "logic_group", "priority", "is_active"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.source_question_uuid ~= nil then
            if params.source_question_uuid == "" or params.source_question_uuid == cjson.null then
                table.insert(set_parts, "source_question_id = NULL")
            else
                local ok_sq, sq_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", params.source_question_uuid)
                if ok_sq and sq_rows and #sq_rows > 0 then
                    table.insert(set_parts, "source_question_id = ?")
                    table.insert(set_vals, sq_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, rule_uuid)

        local sql = "UPDATE profile_tag_rules SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update tag rule failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update tag rule" } }
        end

        return { status = 200, json = { tag_rule = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /tag-rules/:uuid (admin)
    app:delete(PREFIX .. "/tag-rules/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local rule_uuid = self.params.uuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_tag_rules WHERE uuid = ? LIMIT 1", rule_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Tag rule not found" } }
        end

        local ok_del, del_err = pcall(db.query, "UPDATE profile_tag_rules SET is_active = false, updated_at = NOW() WHERE uuid = ?", rule_uuid)
        if not ok_del then
            return { status = 500, json = { error = "Failed to delete tag rule" } }
        end

        return { status = 200, json = { message = "Tag rule deactivated", uuid = rule_uuid } }
    end)

    -- =====================================================================
    -- 10. LOOKUP TABLES
    -- =====================================================================

    -- GET /lookup-tables
    app:get(PREFIX .. "/lookup-tables", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local namespace_id = getNamespaceId(self)
        local where_clause = "is_active = true"
        local vals = {}
        if namespace_id and namespace_id > 0 then
            where_clause = where_clause .. " AND (namespace_id = ? OR namespace_id = 0)"
            table.insert(vals, namespace_id)
        end

        local ok, rows = pcall(db.query, "SELECT * FROM profile_lookup_tables WHERE " .. where_clause .. " ORDER BY name ASC", unpack(vals))
        if not ok then
            return { status = 500, json = { error = "Failed to load lookup tables" } }
        end

        return { status = 200, json = { lookup_tables = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /lookup-tables (admin)
    app:post(PREFIX .. "/lookup-tables", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        if not params.name or params.name == "" then
            return { status = 400, json = { error = "name is required" } }
        end
        if not params.slug or params.slug == "" then
            return { status = 400, json = { error = "slug is required" } }
        end

        local namespace_id = getNamespaceId(self)

        local ok, result = pcall(db.query, [[
            INSERT INTO profile_lookup_tables (uuid, namespace_id, name, slug, description, is_active, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, true, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id,
            params.name,
            params.slug,
            params.description
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] create lookup table failed: ", tostring(result))
            return { status = 500, json = { error = "Failed to create lookup table" } }
        end

        return { status = 201, json = { lookup_table = result and result[1] or nil } }
    end)

    -- GET /lookup-tables/:uuid/values
    app:get(PREFIX .. "/lookup-tables/:uuid/values", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local lt_uuid = self.params.uuid
        local ok_lt, lt_rows = pcall(db.query, "SELECT id FROM profile_lookup_tables WHERE uuid = ? LIMIT 1", lt_uuid)
        if not ok_lt or not lt_rows or #lt_rows == 0 then
            return { status = 404, json = { error = "Lookup table not found" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT * FROM profile_lookup_values WHERE lookup_table_id = ? AND is_active = true
            ORDER BY display_order ASC, label ASC
        ]], lt_rows[1].id)
        if not ok then
            return { status = 500, json = { error = "Failed to load lookup values" } }
        end

        return { status = 200, json = { values = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /lookup-tables/:uuid/values (admin)
    app:post(PREFIX .. "/lookup-tables/:uuid/values", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local lt_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_lt, lt_rows = pcall(db.query, "SELECT id FROM profile_lookup_tables WHERE uuid = ? LIMIT 1", lt_uuid)
        if not ok_lt or not lt_rows or #lt_rows == 0 then
            return { status = 404, json = { error = "Lookup table not found" } }
        end

        if not params.label or params.label == "" then
            return { status = 400, json = { error = "label is required" } }
        end
        if not params.value or params.value == "" then
            return { status = 400, json = { error = "value is required" } }
        end

        local parent_value_id = nil
        if params.parent_value_uuid and params.parent_value_uuid ~= "" then
            local ok_pv, pv_rows = pcall(db.query, "SELECT id FROM profile_lookup_values WHERE uuid = ? LIMIT 1", params.parent_value_uuid)
            if ok_pv and pv_rows and #pv_rows > 0 then
                parent_value_id = pv_rows[1].id
            end
        end

        local ok_ins, ins_result = pcall(db.query, [[
            INSERT INTO profile_lookup_values (uuid, lookup_table_id, label, value, display_order, parent_value_id, is_active, metadata_json, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, true, ?, NOW(), NOW())
            RETURNING *
        ]],
            lt_rows[1].id,
            params.label,
            params.value,
            params.display_order or 0,
            parent_value_id,
            params.metadata_json
        )
        if not ok_ins then
            ngx.log(ngx.ERR, "[ProfileBuilder] create lookup value failed: ", tostring(ins_result))
            return { status = 500, json = { error = "Failed to create lookup value" } }
        end

        return { status = 201, json = { value = ins_result and ins_result[1] or nil } }
    end)

    -- PUT /lookup-tables/:uuid/values/:valueUuid (admin)
    app:put(PREFIX .. "/lookup-tables/:uuid/values/:valueUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local value_uuid = self.params.valueUuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_lookup_values WHERE uuid = ? LIMIT 1", value_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Lookup value not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"label", "value", "display_order", "is_active", "metadata_json"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if params.parent_value_uuid ~= nil then
            if params.parent_value_uuid == "" or params.parent_value_uuid == cjson.null then
                table.insert(set_parts, "parent_value_id = NULL")
            else
                local ok_pv, pv_rows = pcall(db.query, "SELECT id FROM profile_lookup_values WHERE uuid = ? LIMIT 1", params.parent_value_uuid)
                if ok_pv and pv_rows and #pv_rows > 0 then
                    table.insert(set_parts, "parent_value_id = ?")
                    table.insert(set_vals, pv_rows[1].id)
                end
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, value_uuid)

        local sql = "UPDATE profile_lookup_values SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update lookup value failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update lookup value" } }
        end

        return { status = 200, json = { value = upd_result and upd_result[1] or nil } }
    end)

    -- DELETE /lookup-tables/:uuid/values/:valueUuid (admin)
    app:delete(PREFIX .. "/lookup-tables/:uuid/values/:valueUuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local value_uuid = self.params.valueUuid
        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_lookup_values WHERE uuid = ? LIMIT 1", value_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Lookup value not found" } }
        end

        local ok_del, del_err = pcall(db.query, "UPDATE profile_lookup_values SET is_active = false, updated_at = NOW() WHERE uuid = ?", value_uuid)
        if not ok_del then
            return { status = 500, json = { error = "Failed to delete lookup value" } }
        end

        return { status = 200, json = { message = "Lookup value deactivated", uuid = value_uuid } }
    end)

    -- =====================================================================
    -- 11. TOUCHPOINTS
    -- =====================================================================

    -- GET /touchpoints
    app:get(PREFIX .. "/touchpoints", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local namespace_id = getNamespaceId(self)
        local where_clause = "is_active = true"
        local vals = {}
        if namespace_id and namespace_id > 0 then
            where_clause = where_clause .. " AND (namespace_id = ? OR namespace_id = 0)"
            table.insert(vals, namespace_id)
        end

        local ok, rows = pcall(db.query, "SELECT * FROM profile_touchpoints WHERE " .. where_clause .. " ORDER BY name ASC", unpack(vals))
        if not ok then
            return { status = 500, json = { error = "Failed to load touchpoints" } }
        end

        return { status = 200, json = { touchpoints = rows or {}, total = #(rows or {}) } }
    end)

    -- POST /touchpoints (admin)
    app:post(PREFIX .. "/touchpoints", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parseJsonBody(self)
        if not params.name or params.name == "" then
            return { status = 400, json = { error = "name is required" } }
        end
        if not params.slug or params.slug == "" then
            return { status = 400, json = { error = "slug is required" } }
        end

        local namespace_id = getNamespaceId(self)
        local admin_uuid = admin.uuid or admin.id

        local ok, result = pcall(db.query, [[
            INSERT INTO profile_touchpoints (uuid, namespace_id, name, slug, description, touchpoint_type, is_active, config_json, created_by, created_at, updated_at)
            VALUES (gen_random_uuid()::text, ?, ?, ?, ?, ?, true, ?, ?, NOW(), NOW())
            RETURNING *
        ]],
            namespace_id,
            params.name,
            params.slug,
            params.description,
            params.touchpoint_type,
            params.config_json,
            admin_uuid
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] create touchpoint failed: ", tostring(result))
            return { status = 500, json = { error = "Failed to create touchpoint" } }
        end

        return { status = 201, json = { touchpoint = result and result[1] or nil } }
    end)

    -- PUT /touchpoints/:uuid (admin)
    app:put(PREFIX .. "/touchpoints/:uuid", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tp_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_find, find_rows = pcall(db.query, "SELECT * FROM profile_touchpoints WHERE uuid = ? LIMIT 1", tp_uuid)
        if not ok_find or not find_rows or #find_rows == 0 then
            return { status = 404, json = { error = "Touchpoint not found" } }
        end

        local set_parts = {}
        local set_vals = {}
        local allowed = {"name", "slug", "description", "touchpoint_type", "is_active", "config_json"}
        for _, field in ipairs(allowed) do
            if params[field] ~= nil then
                table.insert(set_parts, db.escape_identifier(field) .. " = ?")
                table.insert(set_vals, params[field])
            end
        end

        if #set_parts == 0 then
            return { status = 400, json = { error = "No fields to update" } }
        end

        table.insert(set_parts, "updated_at = NOW()")
        table.insert(set_vals, tp_uuid)

        local sql = "UPDATE profile_touchpoints SET " .. table.concat(set_parts, ", ") .. " WHERE uuid = ? RETURNING *"
        local ok_upd, upd_result = pcall(db.query, sql, unpack(set_vals))
        if not ok_upd then
            ngx.log(ngx.ERR, "[ProfileBuilder] update touchpoint failed: ", tostring(upd_result))
            return { status = 500, json = { error = "Failed to update touchpoint" } }
        end

        return { status = 200, json = { touchpoint = upd_result and upd_result[1] or nil } }
    end)

    -- POST /touchpoints/:uuid/questions — link questions (admin)
    app:post(PREFIX .. "/touchpoints/:uuid/questions", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local tp_uuid = self.params.uuid
        local params = parseJsonBody(self)

        local ok_tp, tp_rows = pcall(db.query, "SELECT id FROM profile_touchpoints WHERE uuid = ? LIMIT 1", tp_uuid)
        if not ok_tp or not tp_rows or #tp_rows == 0 then
            return { status = 404, json = { error = "Touchpoint not found" } }
        end
        local touchpoint_id = tp_rows[1].id

        local questions = params.questions
        if not questions or type(questions) ~= "table" or #questions == 0 then
            return { status = 400, json = { error = "questions array is required with question_uuid and display_order" } }
        end

        local linked = 0
        for _, item in ipairs(questions) do
            if item.question_uuid and item.question_uuid ~= "" then
                local ok_q, q_rows = pcall(db.query, "SELECT id FROM profile_questions WHERE uuid = ? LIMIT 1", item.question_uuid)
                if ok_q and q_rows and #q_rows > 0 then
                    local ok_ins, ins_err = pcall(db.query, [[
                        INSERT INTO profile_question_touchpoints (question_id, touchpoint_id, display_order, is_required_in_touchpoint, created_at)
                        VALUES (?, ?, ?, ?, NOW())
                        ON CONFLICT (question_id, touchpoint_id) DO UPDATE SET
                            display_order = EXCLUDED.display_order,
                            is_required_in_touchpoint = EXCLUDED.is_required_in_touchpoint,
                            created_at = NOW()
                    ]],
                        q_rows[1].id,
                        touchpoint_id,
                        item.display_order or 0,
                        item.is_required_in_touchpoint or false
                    )
                    if ok_ins then
                        linked = linked + 1
                    else
                        ngx.log(ngx.ERR, "[ProfileBuilder] link question to touchpoint failed: ", tostring(ins_err))
                    end
                end
            end
        end

        return { status = 200, json = { message = "Questions linked to touchpoint", linked = linked, total = #questions } }
    end)

    -- =====================================================================
    -- 12. COMPLETION
    -- =====================================================================

    -- GET /completion — current user's completion
    app:get(PREFIX .. "/completion", function(self)
        local user = requireAuth(self)
        if not user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = user.uuid or user.id
        local user_id = getUserIdByUuid(user_uuid)
        if not user_id then
            return { status = 200, json = { completion = {}, overall = { total = 0, answered = 0, percent = 0, status = "not_started" } } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT pcs.*, pc.name AS category_name, pc.slug AS category_slug, pc.uuid AS category_uuid
            FROM profile_completion_status pcs
            JOIN profile_categories pc ON pc.id = pcs.category_id
            WHERE pcs.user_id = ?
            ORDER BY pc.display_order ASC
        ]], user_id)
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] completion query failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load completion" } }
        end

        -- Calculate overall
        local total_q = 0
        local total_a = 0
        local total_req = 0
        local total_req_a = 0
        for _, r in ipairs(rows or {}) do
            total_q = total_q + (tonumber(r.total_questions) or 0)
            total_a = total_a + (tonumber(r.answered_questions) or 0)
            total_req = total_req + (tonumber(r.required_questions) or 0)
            total_req_a = total_req_a + (tonumber(r.required_answered) or 0)
        end

        local overall_pct = 0
        if total_q > 0 then
            overall_pct = math.floor((total_a / total_q) * 100)
        end
        local overall_status = "not_started"
        if overall_pct >= 100 then
            overall_status = "complete"
        elseif overall_pct > 0 then
            overall_status = "in_progress"
        end

        return {
            status = 200,
            json = {
                completion = rows or {},
                overall = {
                    total_questions = total_q,
                    answered_questions = total_a,
                    required_questions = total_req,
                    required_answered = total_req_a,
                    completion_percent = overall_pct,
                    status = overall_status
                }
            }
        }
    end)

    -- GET /completion/users — admin: all users completion
    app:get(PREFIX .. "/completion/users", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 25
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local where_parts = {"1=1"}
        local where_vals = {}

        if self.params.search and self.params.search ~= "" then
            local search_term = "%" .. self.params.search .. "%"
            table.insert(where_parts, "(u.email ILIKE ? OR u.first_name ILIKE ? OR u.last_name ILIKE ?)")
            table.insert(where_vals, search_term)
            table.insert(where_vals, search_term)
            table.insert(where_vals, search_term)
        end

        if self.params.status and self.params.status ~= "" then
            table.insert(where_parts, "agg.overall_status = ?")
            table.insert(where_vals, self.params.status)
        end

        if self.params.tag and self.params.tag ~= "" then
            table.insert(where_parts, [[
                u.id IN (
                    SELECT upt.user_id FROM user_profile_tags upt
                    JOIN profile_tags pt ON pt.id = upt.tag_id
                    WHERE pt.slug = ? AND upt.is_active = true
                )
            ]])
            table.insert(where_vals, self.params.tag)
        end

        -- Count total
        local count_sql = [[
            SELECT COUNT(DISTINCT u.id) AS cnt
            FROM users u
            LEFT JOIN (
                SELECT user_id,
                    SUM(total_questions) AS total_q,
                    SUM(answered_questions) AS total_a,
                    CASE
                        WHEN SUM(total_questions) = 0 THEN 'not_started'
                        WHEN SUM(answered_questions) >= SUM(total_questions) THEN 'complete'
                        WHEN SUM(answered_questions) > 0 THEN 'in_progress'
                        ELSE 'not_started'
                    END AS overall_status
                FROM profile_completion_status
                GROUP BY user_id
            ) agg ON agg.user_id = u.id
            WHERE ]] .. table.concat(where_parts, " AND ")

        local ok_cnt, cnt_rows = pcall(db.query, count_sql, unpack(where_vals))
        local total = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        -- Get paginated results
        local vals_with_pagination = {}
        for _, v in ipairs(where_vals) do table.insert(vals_with_pagination, v) end
        table.insert(vals_with_pagination, per_page)
        table.insert(vals_with_pagination, offset)

        local data_sql = [[
            SELECT u.uuid, u.email, u.first_name, u.last_name,
                COALESCE(agg.total_q, 0) AS total_questions,
                COALESCE(agg.total_a, 0) AS answered_questions,
                COALESCE(agg.total_req, 0) AS required_questions,
                COALESCE(agg.total_req_a, 0) AS required_answered,
                CASE
                    WHEN COALESCE(agg.total_q, 0) = 0 THEN 0
                    ELSE FLOOR((COALESCE(agg.total_a, 0)::numeric / agg.total_q) * 100)
                END AS completion_percent,
                CASE
                    WHEN COALESCE(agg.total_q, 0) = 0 THEN 'not_started'
                    WHEN COALESCE(agg.total_a, 0) >= COALESCE(agg.total_q, 0) THEN 'complete'
                    WHEN COALESCE(agg.total_a, 0) > 0 THEN 'in_progress'
                    ELSE 'not_started'
                END AS overall_status
            FROM users u
            LEFT JOIN (
                SELECT user_id,
                    SUM(total_questions) AS total_q,
                    SUM(answered_questions) AS total_a,
                    SUM(required_questions) AS total_req,
                    SUM(required_answered) AS total_req_a,
                    CASE
                        WHEN SUM(total_questions) = 0 THEN 'not_started'
                        WHEN SUM(answered_questions) >= SUM(total_questions) THEN 'complete'
                        WHEN SUM(answered_questions) > 0 THEN 'in_progress'
                        ELSE 'not_started'
                    END AS overall_status
                FROM profile_completion_status
                GROUP BY user_id
            ) agg ON agg.user_id = u.id
            WHERE ]] .. table.concat(where_parts, " AND ") .. [[
            ORDER BY u.email ASC
            LIMIT ? OFFSET ?
        ]]

        local ok_data, data_rows = pcall(db.query, data_sql, unpack(vals_with_pagination))
        if not ok_data then
            ngx.log(ngx.ERR, "[ProfileBuilder] completion users query failed: ", tostring(data_rows))
            return { status = 500, json = { error = "Failed to load user completion data" } }
        end

        return {
            status = 200,
            json = {
                users = data_rows or {},
                total = total,
                page = page,
                per_page = per_page
            }
        }
    end)

    -- =====================================================================
    -- 13. ADMIN user endpoints
    -- =====================================================================

    -- GET /admin/users — List all users who have submitted profile answers
    app:get(PREFIX .. "/admin/users", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 20
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local namespace_id = getNamespaceId(self)

        -- Build WHERE clause
        local where_parts = { "1=1" }
        local where_vals = {}

        if namespace_id and namespace_id > 0 then
            table.insert(where_parts, "(upa.namespace_id = ? OR upa.namespace_id = 0)")
            table.insert(where_vals, namespace_id)
        end

        -- Search filter (email, name)
        if self.params.search and self.params.search ~= "" then
            table.insert(where_parts, "(u.email ILIKE ? OR u.first_name ILIKE ? OR u.last_name ILIKE ?)")
            local pattern = "%" .. self.params.search .. "%"
            table.insert(where_vals, pattern)
            table.insert(where_vals, pattern)
            table.insert(where_vals, pattern)
        end

        -- Tag filter
        if self.params.tag_slug and self.params.tag_slug ~= "" then
            table.insert(where_parts, [[
                u.id IN (
                    SELECT upt.user_id FROM user_profile_tags upt
                    JOIN profile_tags pt ON pt.id = upt.tag_id
                    WHERE pt.slug = ? AND upt.is_active = true
                )
            ]])
            table.insert(where_vals, self.params.tag_slug)
        end

        local where_clause = table.concat(where_parts, " AND ")

        -- Count total distinct users with answers
        local count_sql = "SELECT COUNT(DISTINCT u.id) as total FROM users u JOIN user_profile_answers upa ON upa.user_id = u.id WHERE " .. where_clause
        local ok_count, count_rows = pcall(db.query, count_sql, unpack(where_vals))
        local total = (ok_count and count_rows and #count_rows > 0) and tonumber(count_rows[1].total) or 0

        -- Get users with their answer stats
        local data_sql = [[
            SELECT
                u.uuid,
                u.email,
                u.first_name,
                u.last_name,
                u.created_at as user_created_at,
                COUNT(DISTINCT upa.question_id) as answers_count,
                MAX(upa.answered_at) as last_answered_at,
                (SELECT string_agg(pt.name, ', ' ORDER BY pt.name)
                 FROM user_profile_tags upt
                 JOIN profile_tags pt ON pt.id = upt.tag_id
                 WHERE upt.user_id = u.id AND upt.is_active = true
                ) as tags
            FROM users u
            JOIN user_profile_answers upa ON upa.user_id = u.id
            WHERE ]] .. where_clause .. [[
            GROUP BY u.id, u.uuid, u.email, u.first_name, u.last_name, u.created_at
            ORDER BY MAX(upa.answered_at) DESC
            LIMIT ? OFFSET ?
        ]]
        table.insert(where_vals, per_page)
        table.insert(where_vals, offset)

        local ok_data, data_rows = pcall(db.query, data_sql, unpack(where_vals))
        if not ok_data then
            ngx.log(ngx.ERR, "[ProfileBuilder] admin users list failed: ", tostring(data_rows))
            return { status = 500, json = { error = "Failed to load users" } }
        end

        return {
            status = 200,
            json = {
                users = data_rows or {},
                total = total,
                page = page,
                per_page = per_page
            }
        }
    end)

    -- GET /admin/users/:userUuid/profile
    app:get(PREFIX .. "/admin/users/:userUuid/profile", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local target_uuid = self.params.userUuid
        local target_user_id = getUserIdByUuid(target_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        -- Get user info
        local ok_user, user_rows = pcall(db.query, [[
            SELECT uuid, email, first_name, last_name, created_at FROM users WHERE uuid = ? LIMIT 1
        ]], target_uuid)
        local user_info = (ok_user and user_rows and #user_rows > 0) and user_rows[1] or nil

        -- Get answers grouped by category, then question order
        local ok_ans, answers = pcall(db.query, [[
            SELECT upa.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid,
                   pq.question_type,
                   pc.name AS category_name, pc.slug AS category_slug, pc.display_order AS category_order
            FROM user_profile_answers upa
            JOIN profile_questions pq ON pq.id = upa.question_id
            JOIN profile_categories pc ON pc.id = pq.category_id
            WHERE upa.user_id = ?
            ORDER BY pc.display_order ASC, pc.name ASC, pq.display_order ASC
        ]], target_user_id)
        if not ok_ans then answers = {} end

        -- Get tags
        local ok_tags, tags = pcall(db.query, [[
            SELECT upt.*, pt.name AS tag_name, pt.slug AS tag_slug, pt.color AS tag_color
            FROM user_profile_tags upt
            JOIN profile_tags pt ON pt.id = upt.tag_id
            WHERE upt.user_id = ? AND upt.is_active = true
            ORDER BY pt.name ASC
        ]], target_user_id)
        if not ok_tags then tags = {} end

        -- Get completion
        local ok_comp, completion = pcall(db.query, [[
            SELECT pcs.*, pc.name AS category_name, pc.slug AS category_slug
            FROM profile_completion_status pcs
            JOIN profile_categories pc ON pc.id = pcs.category_id
            WHERE pcs.user_id = ?
            ORDER BY pc.display_order ASC
        ]], target_user_id)
        if not ok_comp then completion = {} end

        return {
            status = 200,
            json = {
                user = user_info,
                answers = answers or {},
                tags = tags or {},
                completion = completion or {}
            }
        }
    end)

    -- GET /admin/users/:userUuid/tags
    app:get(PREFIX .. "/admin/users/:userUuid/tags", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local target_uuid = self.params.userUuid
        local target_user_id = getUserIdByUuid(target_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local ok, rows = pcall(db.query, [[
            SELECT upt.*, pt.name AS tag_name, pt.slug AS tag_slug, pt.color AS tag_color, pt.tag_type
            FROM user_profile_tags upt
            JOIN profile_tags pt ON pt.id = upt.tag_id
            WHERE upt.user_id = ? AND upt.is_active = true
            ORDER BY pt.name ASC
        ]], target_user_id)
        if not ok then
            return { status = 500, json = { error = "Failed to load user tags" } }
        end

        return { status = 200, json = { tags = rows or {}, total = #(rows or {}) } }
    end)

    -- GET /admin/users/:userUuid/answers/history
    app:get(PREFIX .. "/admin/users/:userUuid/answers/history", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local target_uuid = self.params.userUuid
        local target_user_id = getUserIdByUuid(target_uuid)
        if not target_user_id then
            return { status = 404, json = { error = "User not found" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 50
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local ok_cnt, cnt_rows = pcall(db.query, "SELECT COUNT(*) AS cnt FROM user_profile_answer_history WHERE user_id = ?", target_user_id)
        local total = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        local ok, rows = pcall(db.query, [[
            SELECT upah.*, pq.question_key, pq.label AS question_label, pq.uuid AS question_uuid
            FROM user_profile_answer_history upah
            JOIN profile_questions pq ON pq.id = upah.question_id
            WHERE upah.user_id = ?
            ORDER BY upah.created_at DESC
            LIMIT ? OFFSET ?
        ]], target_user_id, per_page, offset)
        if not ok then
            return { status = 500, json = { error = "Failed to load answer history" } }
        end

        return { status = 200, json = { history = rows or {}, total = total, page = page, per_page = per_page } }
    end)

    -- =====================================================================
    -- 14. AUDIT LOGS
    -- =====================================================================

    -- GET /audit-logs (admin)
    app:get(PREFIX .. "/audit-logs", function(self)
        local admin, admin_err = requireAdmin(self)
        if not admin then
            if admin_err == "forbidden" then
                return { status = 403, json = { error = "Admin access required" } }
            end
            return { status = 401, json = { error = "Authentication required" } }
        end

        local page = tonumber(self.params.page) or 1
        local per_page = tonumber(self.params.per_page) or 50
        if per_page > 100 then per_page = 100 end
        local offset = (page - 1) * per_page

        local where_parts = {"1=1"}
        local where_vals = {}

        if self.params.entity_type and self.params.entity_type ~= "" then
            table.insert(where_parts, "pal.entity_type = ?")
            table.insert(where_vals, self.params.entity_type)
        end

        if self.params.action and self.params.action ~= "" then
            table.insert(where_parts, "pal.action = ?")
            table.insert(where_vals, self.params.action)
        end

        if self.params.user_id and self.params.user_id ~= "" then
            table.insert(where_parts, "pal.user_id = ?")
            table.insert(where_vals, self.params.user_id)
        end

        if self.params.from_date and self.params.from_date ~= "" then
            table.insert(where_parts, "pal.created_at >= ?")
            table.insert(where_vals, self.params.from_date)
        end

        if self.params.to_date and self.params.to_date ~= "" then
            table.insert(where_parts, "pal.created_at <= ?")
            table.insert(where_vals, self.params.to_date)
        end

        local namespace_id = getNamespaceId(self)
        if namespace_id and namespace_id > 0 then
            table.insert(where_parts, "(pal.namespace_id = ? OR pal.namespace_id = 0)")
            table.insert(where_vals, namespace_id)
        end

        local where_clause = table.concat(where_parts, " AND ")

        -- Count
        local count_vals = {}
        for _, v in ipairs(where_vals) do table.insert(count_vals, v) end
        local ok_cnt, cnt_rows = pcall(db.query,
            "SELECT COUNT(*) AS cnt FROM profile_audit_logs pal WHERE " .. where_clause,
            unpack(count_vals)
        )
        local total = (ok_cnt and cnt_rows and cnt_rows[1]) and tonumber(cnt_rows[1].cnt) or 0

        -- Data
        local data_vals = {}
        for _, v in ipairs(where_vals) do table.insert(data_vals, v) end
        table.insert(data_vals, per_page)
        table.insert(data_vals, offset)

        local ok, rows = pcall(db.query,
            "SELECT pal.* FROM profile_audit_logs pal WHERE " .. where_clause .. " ORDER BY pal.created_at DESC LIMIT ? OFFSET ?",
            unpack(data_vals)
        )
        if not ok then
            ngx.log(ngx.ERR, "[ProfileBuilder] audit logs query failed: ", tostring(rows))
            return { status = 500, json = { error = "Failed to load audit logs" } }
        end

        return {
            status = 200,
            json = {
                audit_logs = rows or {},
                total = total,
                page = page,
                per_page = per_page
            }
        }
    end)

end
