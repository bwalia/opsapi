--[[
    Field Service — job photos

    The engineer's quote sheet carries site/fault photos (9 in the sample). This
    stores a photo record per job (optionally tied to the visit it was taken
    on); the file itself lives in MinIO and we keep its URL + object key.

    Feature-gated under FEATURES.FIELD_SERVICE.
]]

local db = require("lapis.db")

local function index(sql)
    pcall(function() db.query(sql) end)
end

return {
    -- [1] fs_job_photos   (890)
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS fs_job_photos (
                id BIGSERIAL PRIMARY KEY,
                uuid UUID NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL,
                job_id BIGINT REFERENCES fs_jobs(id) ON DELETE CASCADE,
                visit_id BIGINT REFERENCES fs_visits(id) ON DELETE SET NULL,
                url TEXT NOT NULL,
                object_key TEXT,
                filename TEXT,
                content_type TEXT,
                caption TEXT,
                uploaded_by_uuid UUID,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                deleted_at TIMESTAMPTZ
            )
        ]])
        index([[CREATE INDEX IF NOT EXISTS fs_job_photos_job_idx ON fs_job_photos (job_id) WHERE deleted_at IS NULL]])
    end,
}
