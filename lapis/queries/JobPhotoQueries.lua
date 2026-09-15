--[[
    Field Service — job photo records. The file bytes live in MinIO; here we
    only track the URL + object key, namespace-scoped and linked to a job.
]]

local db = require("lapis.db")
local FsJobPhotoModel = require("models.FsJobPhotoModel")
local Common = require("queries.FieldServiceCommon")

local nilify, arr = Common.nilify, Common.arr

local JobPhotoQueries = {}

local function shape(p)
    return {
        uuid = p.uuid,
        url = p.url,
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

    local photo = FsJobPhotoModel:create({
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        job_id = job_id,
        visit_id = visit_id,
        url = tostring(data.url),
        object_key = nilify(data.object_key),
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
