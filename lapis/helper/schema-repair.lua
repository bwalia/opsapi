--[[
    Schema repair — runs on every `lapis migrate` (zzx_run_project_migrations)

    Missing columns. Columns the code expects that an older migration never
    created (EXPECTED_COLUMNS) are added wherever their table exists.

    Quoted column defaults. Older migrations passed "'pending'" to lapis
    column types that quote the default themselves, so the column default
    became the string 'pending' WITH the quote marks ('''pending'''::varchar).
    Every insert that relied on it stored "'pending'": a status no code
    matches, a currency that isn't ISO, JSON ('{}', '[]') that doesn't parse.

    For each such column this sets the default it was meant to have and
    repairs the rows that still hold the exact quoted value (nothing else is
    touched). Idempotent: once fixed, the column no longer matches. A column
    it can't alter (table owned by another role) is skipped and reported,
    never failing the deploy.
]]

local db = require("lapis.db")

local SchemaRepair = {}

--- Fix quoted string defaults and the rows that inherited them.
-- @return number columns fixed, number rows repaired
function SchemaRepair.fixQuotedDefaults()
    local columns = db.query([[
        SELECT table_name, column_name, column_default
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND column_default ~ '^''''''.*''''''::[a-z ]+$'
        ORDER BY table_name, column_name
    ]])
    local fixed, repaired = 0, 0
    for _, c in ipairs(columns) do
        local ok, err = pcall(function()
            -- Postgres evaluates the default: "'pending'" (quotes included).
            local bad = db.query("SELECT (" .. c.column_default .. ")::text AS v")[1].v
            if type(bad) ~= "string" or #bad < 2 or bad:sub(1, 1) ~= "'" or bad:sub(-1) ~= "'" then return end
            local good = bad:sub(2, -2):gsub("''", "'")
            local T, C = db.escape_identifier(c.table_name), db.escape_identifier(c.column_name)
            db.query("ALTER TABLE " .. T .. " ALTER COLUMN " .. C .. " SET DEFAULT " .. db.escape_literal(good))
            local res = db.query("UPDATE " .. T .. " SET " .. C .. " = " .. db.escape_literal(good)
                .. " WHERE " .. C .. "::text = " .. db.escape_literal(bad))
            fixed = fixed + 1
            repaired = repaired + (res.affected_rows or 0)
            if (res.affected_rows or 0) > 0 then
                print(("[SchemaRepair] %s.%s: default fixed, %d row(s) repaired"):format(
                    c.table_name, c.column_name, res.affected_rows))
            end
        end)
        if not ok then
            print(("[SchemaRepair] skipped %s.%s: %s"):format(c.table_name, c.column_name,
                tostring(err):match("ERROR:%s*([^\n]+)") or tostring(err)))
        end
    end
    if fixed > 0 then
        print(("[SchemaRepair] quoted defaults: %d column(s) fixed, %d row(s) repaired"):format(fixed, repaired))
    end
    return fixed, repaired
end

-- Columns the code reads/writes that an older migration never created. Each
-- is added (when its table exists in this deployment) on every migrate, so a
-- feature enabled later still gets it.
local EXPECTED_COLUMNS = {
    -- delivery-management.lua writes it when a partner accepts; orders.lua and
    -- delivery-management.lua read it (GET /api/v2/orders/:id failed without it).
    { "order_delivery_assignments", "accepted_at", "TIMESTAMP" },
    -- migrations/geolocation-delivery-system [5] adds these in ONE statement with
    -- PostGIS GEOGRAPHY columns; without PostGIS the whole ALTER failed (inside
    -- a pcall) and the plain coordinates never existed, so seller orders and
    -- delivery dashboards that read them failed. (The GEOGRAPHY columns still
    -- need PostGIS and nothing reads them.)
    { "orders", "delivery_latitude", "NUMERIC(10, 8)" },
    { "orders", "delivery_longitude", "NUMERIC(11, 8)" },
    { "orders", "pickup_latitude", "NUMERIC(10, 8)" },
    { "orders", "pickup_longitude", "NUMERIC(11, 8)" },
}

function SchemaRepair.ensureColumns()
    for _, c in ipairs(EXPECTED_COLUMNS) do
        local ok, err = pcall(function()
            if db.query("SELECT to_regclass(?) IS NOT NULL AS ok", c[1])[1].ok then
                db.query("ALTER TABLE " .. db.escape_identifier(c[1]) .. " ADD COLUMN IF NOT EXISTS "
                    .. db.escape_identifier(c[2]) .. " " .. c[3])
            end
        end)
        if not ok then print(("[SchemaRepair] could not add %s.%s: %s"):format(c[1], c[2], tostring(err))) end
    end
end

--- Everything above (called from migrations.lua on every migrate).
function SchemaRepair.run()
    SchemaRepair.ensureColumns()
    SchemaRepair.fixQuotedDefaults()
end

return SchemaRepair
