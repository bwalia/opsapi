-- Data hardening (review fixes), idempotent:
--   * inbound messages remember whether the mail server verified the sender (DMARC pass): an emailed
--     "unsubscribe" only opts a lead out when it did
--   * a saved search's polygon must be 3-200 [lat, lng] number pairs in range (NOT VALID: old rows are left
--     alone, the deal scout skips a broken one)
--   * the new property_deals_leads module (leads, their replies and news, the inbox) goes to every role and
--     API key that could read deals or tasks before, except the builder role, so nobody else loses access
--   * paid-feed stub connectors can't be enabled (they never ran); existing ones are switched off
--   * "call now" tasks no longer carry the reply's text (it stays on the lead, where retention clears it)
local cjson = require("cjson")

local function grant(perms)
    if type(perms) ~= "table" or perms.property_deals_leads ~= nil then return false end
    local deals, tasks = perms.property_deals_deals, perms.property_deals_tasks
    if type(deals) == "table" and #deals > 0 then
        perms.property_deals_leads = deals
        return true
    end
    for _, a in ipairs(type(tasks) == "table" and tasks or {}) do
        if a == "read" or a == "manage" then
            perms.property_deals_leads = { "read" }
            return true
        end
    end
    return false
end

local function grant_column(db, tbl, col, extra)
    if not db.query("SELECT to_regclass(?) IS NOT NULL AS ok", tbl)[1].ok then return end
    for _, r in ipairs(db.query("SELECT id, " .. col .. " AS v FROM " .. tbl .. " WHERE (" .. col
        .. " LIKE '%property_deals_deals%' OR " .. col .. " LIKE '%property_deals_tasks%')" .. (extra or ""))) do
        local ok, perms = pcall(cjson.decode, r.v)
        if ok and grant(perms) then
            db.query("UPDATE " .. tbl .. " SET " .. col .. " = ? WHERE id = ?", cjson.encode(perms), r.id)
        end
    end
end

return function(schema, db)
    db.query("ALTER TABLE property_deals_inbound_messages ADD COLUMN IF NOT EXISTS sender_verified BOOLEAN")

    db.query([[
        CREATE OR REPLACE FUNCTION property_deals_valid_polygon(p jsonb) RETURNS boolean
        LANGUAGE sql IMMUTABLE AS $fn$
            SELECT CASE
                WHEN jsonb_typeof(p) <> 'array' THEN false
                WHEN jsonb_array_length(p) NOT BETWEEN 3 AND 200 THEN false
                ELSE NOT EXISTS (
                    SELECT 1 FROM jsonb_array_elements(p) pt
                    WHERE CASE
                        WHEN jsonb_typeof(pt) <> 'array' THEN true
                        WHEN jsonb_array_length(pt) <> 2 THEN true
                        WHEN jsonb_typeof(pt -> 0) <> 'number' OR jsonb_typeof(pt -> 1) <> 'number' THEN true
                        ELSE (pt ->> 0)::float8 NOT BETWEEN -90 AND 90 OR (pt ->> 1)::float8 NOT BETWEEN -180 AND 180
                    END)
            END
        $fn$
    ]])
    db.query([[
        DO $$ BEGIN
            ALTER TABLE property_deals_saved_searches ADD CONSTRAINT property_deals_saved_searches_polygon
                CHECK (polygon IS NULL OR property_deals_valid_polygon(polygon)) NOT VALID;
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $$
    ]])

    grant_column(db, "namespace_roles", "permissions", " AND role_name <> 'pd_builder'")
    grant_column(db, "api_keys", "scopes")

    db.query([[
        UPDATE property_deals_connectors SET enabled = false, updated_at = NOW()
        WHERE enabled AND kind IN ('propertydata', 'searchland', 'streetdata', 'homedata')
    ]])

    db.query([[
        UPDATE kanban_tasks t
        SET description = regexp_replace(t.description, '\nReply \([a-z]+\): .*\n\nWhy hot:',
            E'\nThey replied: read it on the lead (Replies).\n\nWhy hot:')
        FROM property_deals_task_details d
        WHERE d.task_uuid = t.uuid AND d.metadata ->> 'kind' = 'hot_lead_call' AND t.description LIKE '%' || E'\n' || 'Reply (%'
    ]])
end
