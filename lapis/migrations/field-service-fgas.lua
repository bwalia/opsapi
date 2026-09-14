--[[
    Field Service — F-Gas (fluorinated refrigerant) logging

    UK F-Gas rules require a record of refrigerant handled on each service
    visit (gas type, kg charged / recovered, a leak check) and that the
    engineer holds an F-Gas certificate. This adds:
      - per-visit refrigerant fields on fs_visits (one record per visit is
        enough for a service call; multi-gas jobs note it free-text),
      - the engineer's F-Gas certificate number on employees.

    Feature-gated under FEATURES.FIELD_SERVICE.
]]

local db = require("lapis.db")

return {
    -- [1] refrigerant handling on visits + engineer cert   (886)
    [1] = function()
        db.query([[
            ALTER TABLE fs_visits
                ADD COLUMN IF NOT EXISTS refrigerant_type TEXT,
                ADD COLUMN IF NOT EXISTS refrigerant_added_kg NUMERIC(10,3),
                ADD COLUMN IF NOT EXISTS refrigerant_recovered_kg NUMERIC(10,3),
                ADD COLUMN IF NOT EXISTS leak_check_result TEXT,   -- pass | fail | na
                ADD COLUMN IF NOT EXISTS leak_check_notes TEXT,
                ADD COLUMN IF NOT EXISTS fgas_cylinder_ref TEXT
        ]])
        db.query([[ALTER TABLE employees ADD COLUMN IF NOT EXISTS fgas_certificate_no TEXT]])
    end,
}
