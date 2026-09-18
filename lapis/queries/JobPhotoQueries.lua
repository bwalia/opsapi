--[[
    Field Service — job photo records. The file bytes live in MinIO; here we
    only track the URL + object key, namespace-scoped and linked to a job.
]]

local db = require("lapis.db")
local FsJobPhotoModel = require("models.FsJobPhotoModel")
local Common = require("queries.FieldServiceCommon")
local MinioClient = require("helper.minio")

local nilify, arr = Common.nilify, Common.arr

local JobPhotoQueries = {}

-- The object key inside the bucket: stored, or derived from the URL
-- (scheme://host/bucket/<key>).
local function object_key_of(p)
    if p.object_key and p.object_key ~= "" then return p.object_key end
    local rest = (p.url or ""):gsub("^https?://[^/]+/", "") -- bucket/key
    return (rest:gsub("^[^/]+/", ""))                       -- key
end

-- A browser-reachable, time-limited URL. Presign against the public host so the
-- photo loads in an <img>; fall back to the stored URL if presigning is off.
local function browser_url(p)
    local key = object_key_of(p)
    if not key or key == "" then return p.url end
    local ok, minio = pcall(MinioClient.getDefault)
    if not ok or not minio then return p.url end
    local signed = minio:getPresignedUrl(key, 3600, nil, true)
    return signed or p.url
end

local function shape(p)
    return {
        uuid = p.uuid,
        url = browser_url(p),
        filename = p.filename,
        content_type = p.content_type,
        caption = p.caption,
        visit_uuid = p.visit_uuid,
        uploaded_by_uuid = p.uploaded_by_uuid,
        created_at = p.created_at,
    }
end

--- Photos for a job (by numeric job_id), newest first.
function JobPhotoQueries.listByJobId(job_id)
    local rows = db.query([[
        SELECT ph.*, v.uuid AS visit_uuid
        FROM fs_job_photos ph
        LEFT JOIN fs_visits v ON v.id = ph.visit_id
        WHERE ph.job_id = ? AND ph.deleted_at IS NULL
        ORDER BY ph.created_at DESC, ph.id DESC
    ]], job_id)
    local out = {}
    for _, p in ipairs(rows or {}) do table.insert(out, shape(p)) end
    return arr(out)
end

--- Evidence photos attached to a specific job item (by numeric id), newest first.
function JobPhotoQueries.listByItemId(item_id)
    local rows = db.query([[
        SELECT ph.*, v.uuid AS visit_uuid
        FROM fs_job_photos ph
        LEFT JOIN fs_visits v ON v.id = ph.visit_id
        WHERE ph.job_item_id = ? AND ph.deleted_at IS NULL
        ORDER BY ph.created_at DESC, ph.id DESC
    ]], item_id)
    local out = {}
    for _, p in ipairs(rows or {}) do table.insert(out, shape(p)) end
    return arr(out)
end

function JobPhotoQueries.listByJob(namespace_id, job_uuid)
    local job_id = Common.resolve_id("fs_jobs", namespace_id, job_uuid)
    if not job_id then return nil, "Job not found" end
    return JobPhotoQueries.listByJobId(job_id)
end

--- Store an uploaded photo. `data.url` is required (the MinIO URL).
function JobPhotoQueries.addPhoto(namespace_id, job_uuid, data, actor_uuid)
    local job_id = Common.resolve_id("fs_jobs", namespace_id, job_uuid)
    if not job_id then return nil, "Job not found" end
    if not nilify(data.url) then return nil, "url is required" end

    local visit_id
    if nilify(data.visit_uuid) then
        visit_id = Common.resolve_id("fs_visits", namespace_id, data.visit_uuid)
    end

    -- Optional link to a specific proposed item (fault-evidence photos).
    local job_item_id
    if nilify(data.item_uuid) then
        job_item_id = Common.resolve_id("fs_job_items", namespace_id, data.item_uuid)
        if not job_item_id then return nil, "Item not found" end
    elseif data.job_item_id then
        job_item_id = tonumber(data.job_item_id)
    end

    local photo = FsJobPhotoModel:create({
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        job_id = job_id,
        visit_id = visit_id,
        job_item_id = job_item_id,
        url = tostring(data.url),
        object_key = nilify(data.object_key) or object_key_of({ url = tostring(data.url) }),
        filename = nilify(data.filename),
        content_type = nilify(data.content_type),
        caption = nilify(data.caption),
        uploaded_by_uuid = nilify(actor_uuid),
    })
    return shape(photo)
end

--- The job a photo belongs to (for authorising engineer deletes).
function JobPhotoQueries.jobIdForPhoto(namespace_id, uuid)
    local rows = db.query([[
        SELECT job_id FROM fs_job_photos WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1
    ]], tostring(uuid), namespace_id)
    return rows and rows[1] and rows[1].job_id or nil
end

function JobPhotoQueries.deletePhoto(namespace_id, uuid)
    local id = Common.resolve_id("fs_job_photos", namespace_id, uuid)
    if not id then return nil, "Photo not found" end
    db.query("UPDATE fs_job_photos SET deleted_at = NOW() WHERE id = ?", id)
    return true
end

return JobPhotoQueries
