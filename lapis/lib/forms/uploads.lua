--[[
    Files attached to form responses
    ================================

    1. The page uploads each file as it's picked
       (POST /api/v2/public/forms/:public_id/uploads?field=<key>, with the
       render token): the field must be a file field of the live version; the
       type comes from the extension against Fields.FILE_TYPES (the browser's
       type is ignored) and the field's size limit. Stored in MinIO under
       forms/<namespace>/<form>/<upload uuid>/<name>.
    2. The response sends the upload ids; Uploads.resolve checks they are this
       form's, this field's and not yet used, and Uploads.claim attaches them
       to the response in its transaction. The stored answer is the files'
       { id, name, size, type }, never a storage URL.
    3. Staff open a file through a short-lived signed URL (Uploads.link).
    4. The hourly purge (lib/forms/jobs.lua) deletes files never claimed within
       a day and files whose response was deleted.
]]

local db = require("lapis.db")
local cjson = require("lib.forms.json")
local Global = require("helper.global")
local Fields = require("lib.forms.fields")

local Uploads = {}

Uploads.UNCLAIMED_HOURS = 24
Uploads.LINK_SECONDS = 600

local function minio()
    local ok, M = pcall(require, "helper.minio")
    if not ok then return nil end
    local client = M.getDefault()
    if not client or not client:validate() then return nil end
    return client
end

function Uploads.available()
    return minio() ~= nil
end

local function safe_name(name)
    name = tostring(name or "file"):gsub("[/\\]", "_"):gsub("[%z\1-\31\127]", "")
    name = name:match("([^/]+)$") or "file"
    if #name > 120 then
        local ext = name:match("%.(%w+)$")
        name = name:sub(1, 100) .. (ext and ("." .. ext) or "")
    end
    return name
end

local function field_of(schema, key)
    for _, f in ipairs(schema.fields or {}) do
        if f.key == key and f.type == "file_upload" then return f end
    end
end

--- Store one uploaded file for a field of the live version.
-- @param form    { id, namespace_id }
-- @param schema  the published version's schema
-- @param file    lapis multipart file { filename, content }
-- @return { id, name, size, type } | nil, message, status
function Uploads.accept(form, schema, field_key, file, ip_hash)
    local field = field_of(schema, field_key)
    if not field then return nil, "That question doesn't take files.", 400 end
    if type(file) ~= "table" or type(file.content) ~= "string" or file.content == "" then
        return nil, "Choose a file to upload.", 400
    end
    local name = safe_name(file.filename)
    local ext = (name:match("%.([%w]+)$") or ""):lower()
    local kind = Fields.FILE_TYPES[ext]
    if not kind or (field.accept ~= "any" and kind[2] ~= field.accept) then
        return nil, field.accept == "images" and "Only images (JPG, PNG, GIF, WebP, HEIC) can be uploaded here."
            or field.accept == "documents"
                and "Only documents (PDF, Word, Excel, PowerPoint, text, CSV) can be uploaded here."
            or "That type of file can't be uploaded.", 415
    end
    if #file.content > field.max_size_mb * 1024 * 1024 then
        return nil, "Files can be at most " .. field.max_size_mb .. " MB.", 413
    end
    local client = minio()
    if not client then return nil, "File uploads aren't available right now.", 503 end
    local uuid = Global.generateUUID()
    local key = ("forms/%d/%d/%s/%s"):format(tonumber(form.namespace_id), tonumber(form.id), uuid,
        name:gsub("[^%w%-_.]", "_"))
    local _, err = client:upload({ content = file.content, filename = name, content_type = kind[1] },
        { object_key = key, max_size = field.max_size_mb * 1024 * 1024 })
    if err then
        ngx.log(ngx.WARN, "[forms] upload failed: ", tostring(err))
        return nil, "The file couldn't be stored. Please try again.", 502
    end
    db.query([[
        INSERT INTO form_uploads (uuid, namespace_id, form_id, field_key, object_key, filename, content_type,
            size_bytes, ip_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], uuid, form.namespace_id, form.id, field_key, key, name, kind[1], #file.content, ip_hash or db.NULL)
    return { id = uuid, name = name, size = #file.content, type = kind[1] }
end

--- Check the upload ids in the answers: this form's, the right field's,
-- unused and recent. Replaces each id by the file's details.
-- @return answers | nil, { [field_key] = message }
function Uploads.resolve(form_id, schema, answers)
    local errors
    for _, f in ipairs(schema.fields or {}) do
        local ids = f.type == "file_upload" and answers[f.key]
        if type(ids) == "table" and #ids > 0 then
            local rows = db.query(([[
                SELECT uuid, filename, size_bytes, content_type FROM form_uploads
                WHERE form_id = ? AND field_key = ? AND submission_id IS NULL
                  AND created_at > NOW() - interval '%d hours' AND uuid IN ?
            ]]):format(Uploads.UNCLAIMED_HOURS), form_id, f.key, db.list(ids))
            local by = {}
            for _, r in ipairs(rows) do by[r.uuid] = r end
            local files = {}
            for _, id in ipairs(ids) do
                local r = by[id]
                if not r then
                    errors = errors or {}
                    errors[f.key] = "a file expired or was already sent — please attach it again"
                    break
                end
                files[#files + 1] = { id = id, name = r.filename, size = tonumber(r.size_bytes), type = r.content_type }
            end
            answers[f.key] = setmetatable(files, cjson.array_mt)
        end
    end
    if errors then return nil, errors end
    return answers
end

--- Attach the answers' files to a response (inside its transaction).
-- @return true | nil when one was taken meanwhile
function Uploads.claim(submission_id, schema, answers)
    local ids = {}
    for _, f in ipairs(schema.fields or {}) do
        if f.type == "file_upload" and type(answers[f.key]) == "table" then
            for _, file in ipairs(answers[f.key]) do ids[#ids + 1] = file.id end
        end
    end
    if #ids == 0 then return true end
    local res = db.query([[UPDATE form_uploads SET submission_id = ?
        WHERE (submission_id IS NULL OR submission_id = ?) AND uuid IN ?]], submission_id, submission_id, db.list(ids))
    return (res.affected_rows or 0) == #ids
end

--- A short-lived download link to one of a response's files.
-- @return url | nil, err
function Uploads.link(submission_id, upload_uuid)
    local row = db.query("SELECT object_key FROM form_uploads WHERE uuid = ? AND submission_id = ?",
        upload_uuid, submission_id)[1]
    if not row then return nil, "File not found" end
    local client = minio()
    if not client then return nil, "File storage isn't available" end
    local url, err = client:getPresignedUrl(row.object_key, Uploads.LINK_SECONDS, nil, true)
    if not url then return nil, tostring(err) end
    return url
end

--- Delete files never claimed within UNCLAIMED_HOURS and files whose response
-- is gone (deleted, purged by retention, form deleted). One pass.
-- @return number of files removed
function Uploads.purge(limit)
    local rows = db.query(([[
        SELECT u.id, u.object_key FROM form_uploads u
        LEFT JOIN form_submissions s ON s.id = u.submission_id
        WHERE (u.submission_id IS NULL AND u.created_at < NOW() - interval '%d hours')
           OR (u.submission_id IS NOT NULL AND s.id IS NULL)
        ORDER BY u.id LIMIT %d
    ]]):format(Uploads.UNCLAIMED_HOURS, tonumber(limit) or 500))
    if #rows == 0 then return 0 end
    local client = minio()
    local gone = {}
    for _, r in ipairs(rows) do
        local ok = not client or pcall(client.delete, client, r.object_key)
        if ok then gone[#gone + 1] = tonumber(r.id) end
    end
    if #gone > 0 then db.query("DELETE FROM form_uploads WHERE id IN (" .. table.concat(gone, ",") .. ")") end
    return #gone
end

return Uploads
