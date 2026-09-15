local Model = require("lapis.db.model").Model

-- Field-service job photo (file lives in MinIO; we keep url + object_key).
-- Immutable: no updated_at, created_at defaults in the DB — so no timestamp opt.
local FsJobPhotoModel = Model:extend("fs_job_photos")

return FsJobPhotoModel
