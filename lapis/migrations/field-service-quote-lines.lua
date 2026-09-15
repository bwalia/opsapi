--[[
    Field Service — quote-sheet line fields on fs_job_items

    The engineer's paper quote sheet records more than a description + price:
    labour is split by category (Engineer/Mate × normal/overtime) with hours
    (quantity) AND days; materials carry a supplier + free part number; and
    specialist tool / access hire is priced per day. These map onto job items:
      - labour  -> item_type 'labour'   + labour_category + quantity(hours) + days
      - material-> item_type 'part'/'material' + supplier + part_number
      - hire    -> item_type 'hire'     + supplier + part_number + days

    Feature-gated under FEATURES.FIELD_SERVICE.
]]

local db = require("lapis.db")

return {
    -- [1] quote-line columns   (889)
    [1] = function()
        db.query([[
            ALTER TABLE fs_job_items
                ADD COLUMN IF NOT EXISTS labour_category TEXT,   -- engineer_nt | engineer_ot | mate_nt | mate_ot
                ADD COLUMN IF NOT EXISTS days NUMERIC(10,2),
                ADD COLUMN IF NOT EXISTS supplier TEXT,
                ADD COLUMN IF NOT EXISTS part_number TEXT
        ]])
        -- Allow the new 'hire' item type (tool / access equipment hire).
        db.query([[ALTER TABLE fs_job_items DROP CONSTRAINT IF EXISTS fs_job_items_item_type_check]])
        db.query([[
            ALTER TABLE fs_job_items ADD CONSTRAINT fs_job_items_item_type_check
                CHECK (item_type = ANY (ARRAY['part','material','labour','hire','expense','other']))
        ]])
    end,
}
