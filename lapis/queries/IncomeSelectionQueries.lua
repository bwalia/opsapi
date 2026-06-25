--[[
    Income Selection Queries

    Per-user income-source questionnaire answer + multi-select of income types.
    Backed by:
      - tax_user_profiles.has_income_sources (the yes/no answer)
      - tax_user_income_types               (one row per selected catalogue key)

    save() uses replace-the-whole-set semantics inside a transaction: it upserts
    the flag, deletes the user's existing selection rows, and re-inserts the
    validated set. Keys are validated against the active income_types catalogue
    (IncomeTypeQueries.active_keys) so a stale/unknown key can't be stored.

    Mirrors MyIncomeQueries conventions (user/namespace resolution, audit log,
    uuid-as-id masking). See queries/MyIncomeQueries.lua.
]]

local Global = require "helper.global"
local IncomeTypeQueries = require "queries.IncomeTypeQueries"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local IncomeSelectionQueries = {}

-- Force a Lua list to encode as a JSON array. cjson serialises an empty table
-- as {} (object), which breaks consumers expecting [] (e.g. new Set(...) on the
-- web). cjson.empty_array is the lua-cjson sentinel that always encodes as [].
local function json_array(t)
    if type(t) == "table" and #t > 0 then return t end
    return cjson.empty_array
end

-- Resolve internal user.id + uuid from the LapisUser (which carries uuid).
-- Returns id, uuid or nil, nil, error_message.
local function resolveUser(user)
    if not user then return nil, nil, "User not authenticated" end
    local rows
    if user.uuid then
        rows = db.query("SELECT id, uuid FROM users WHERE uuid = ? LIMIT 1", user.uuid)
    elseif user.id then
        rows = db.query("SELECT id, uuid FROM users WHERE id = ? LIMIT 1", user.id)
    end
    if not rows or #rows == 0 then return nil, nil, "User not found" end
    return rows[1].id, rows[1].uuid
end

-- Resolve user's default namespace (nil if not configured — column allows NULL).
local function resolveNamespaceId(internal_user_id)
    local rows = db.query([[
        SELECT default_namespace_id FROM user_namespace_settings
        WHERE user_id = ? LIMIT 1
    ]], internal_user_id)
    if rows and #rows > 0 and rows[1].default_namespace_id then
        return tonumber(rows[1].default_namespace_id)
    end
    return nil
end

-- Active catalogue as [{ key, label }] for the questionnaire picker.
local function available_types()
    local rows = IncomeTypeQueries.list_active()
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { key = r.income_type_key, label = r.display_name }
    end
    return json_array(out)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Get the user's current answer + selection + the available catalogue.
-- ────────────────────────────────────────────────────────────────────────────
function IncomeSelectionQueries.get(user)
    local uid, _, err = resolveUser(user)
    if not uid then return nil, err end

    -- has_income_sources: true / false / nil(unanswered). Preserve false.
    local has = nil
    local prof = db.query(
        "SELECT has_income_sources FROM tax_user_profiles WHERE user_id = ? LIMIT 1", uid)
    if prof and prof[1] then has = prof[1].has_income_sources end

    local rows = db.query(
        "SELECT income_type_key FROM tax_user_income_types WHERE user_id = ? ORDER BY income_type_key", uid)
    local selected = {}
    for _, r in ipairs(rows or {}) do selected[#selected + 1] = r.income_type_key end

    return {
        has_income_sources = has,
        selected = json_array(selected),
        available = available_types(),
    }
end

-- ────────────────────────────────────────────────────────────────────────────
-- Save the answer + selection (replace-the-whole-set).
-- has_income_sources: truthy/falsy. income_type_keys: array of catalogue keys.
-- ────────────────────────────────────────────────────────────────────────────
function IncomeSelectionQueries.save(user, has_income_sources, income_type_keys)
    local uid, user_uuid, err = resolveUser(user)
    if not uid then return nil, err end

    local has = has_income_sources and true or false
    local ns = resolveNamespaceId(uid)

    -- Validate against the active catalogue; dedupe; drop unknowns. A "no"
    -- answer forces an empty selection regardless of what was sent.
    local active = IncomeTypeQueries.active_keys()
    local valid, seen = {}, {}
    if has and type(income_type_keys) == "table" then
        for _, k in ipairs(income_type_keys) do
            if type(k) == "string" and active[k] and not seen[k] then
                seen[k] = true
                valid[#valid + 1] = k
            end
        end
    end

    db.query("BEGIN")
    local ok = pcall(function()
        -- Upsert the flag (tax_user_profiles.user_id is UNIQUE). The row may
        -- not exist yet for brand-new users, hence INSERT ... ON CONFLICT.
        db.query([[
            INSERT INTO tax_user_profiles (uuid, user_id, user_uuid, has_income_sources, created_at, updated_at)
            VALUES (?, ?, ?, ?, NOW(), NOW())
            ON CONFLICT (user_id) DO UPDATE
                SET has_income_sources = EXCLUDED.has_income_sources, updated_at = NOW()
        ]], Global.generateUUID(), uid, user_uuid, has)

        db.query("DELETE FROM tax_user_income_types WHERE user_id = ?", uid)
        for _, k in ipairs(valid) do
            db.query([[
                INSERT INTO tax_user_income_types
                    (uuid, user_id, namespace_id, income_type_key, created_at, updated_at)
                VALUES (?, ?, ?, ?, NOW(), NOW())
            ]], Global.generateUUID(), uid, ns or db.NULL, k)
        end
    end)
    if not ok then
        db.query("ROLLBACK")
        return nil, "Failed to save income sources"
    end
    db.query("COMMIT")

    TaxAuditLogQueries.log({
        user_id = uid,
        user_email = user.email,
        entity_type = "INCOME_SOURCES",
        entity_id = tostring(uid),
        action = "UPDATE",
        new_values = cjson.encode({ has_income_sources = has, income_type_keys = valid }),
    })

    return { has_income_sources = has, selected = json_array(valid), available = available_types() }
end

return IncomeSelectionQueries
